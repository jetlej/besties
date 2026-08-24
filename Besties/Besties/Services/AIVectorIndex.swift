import Accelerate
import Foundation
import NaturalLanguage
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Sidecar semantic index: one on-device sentence embedding per chunk of up to
/// five consecutive messages, stored as unit-normalized Float32 in `vec.sqlite`
/// next to `search.sqlite`. Nothing leaves the Mac — `NLEmbedding` is built
/// into macOS — and neither source database is ever written; chunks are read
/// from the FTS index's `msgs` table, which already holds decoded text.
///
/// Search is a brute-force cosine scan (one `vDSP_mmul`) over the whole matrix
/// held in memory: ~300k chunks × 512 dims × 4 bytes ≈ 610 MB resident once
/// loaded, ~14 ms per query. That is the price of having no vector-index
/// dependency, and the matrix is only loaded on the first search.
///
/// Sync mirrors `SearchIndex`: per-source cursors in `meta`, one transaction
/// per batch with the cursor persisted inside it (so an interrupted build
/// resumes), drop-and-rebuild when the schema or the embedding model changes,
/// and a per-source reset when that source's ids go backwards upstream.
final class AIVectorIndex {
    /// One chunk that matched a query. Message ids are in each source's own
    /// numbering (the WhatsApp offset is stripped), matching
    /// `SearchIndex.Result.rowID`; `date` is the chunk's *earliest* message,
    /// which is not always its first by id — `msgs.id` is arrival order, and
    /// 12.7% of messages arrive out of date order (edited/relinked rows).
    struct Hit {
        let source: String
        let chatID: Int64
        let firstMessageID: Int64
        let lastMessageID: Int64
        let date: Date
        let score: Double
    }

    private static let schemaVersion = 1
    /// Bumped whenever the vectors would come out different — a different
    /// model, a different pooling, a different chunking rule. Any change drops
    /// the table and rebuilds.
    private static let modelID = "nl-sentence-english-512-c5g3sym"
    private static let dimensions = 512

    /// Same shift `SearchIndex` applies, so `msgs.id` is unique across sources.
    private static let whatsAppIDOffset: Int64 = 1 << 40

    /// Chunking: up to five consecutive messages of one conversation, broken
    /// whenever two of them are more than three hours apart *in either
    /// direction* — `msgs.id` is arrival order, not date order, so a chunk that
    /// only checked forward silently swallowed messages years older.
    ///
    /// Five rather than ten because `NLEmbedding.sentenceEmbedding` pools word
    /// vectors: the longer the text, the more a single topic in it is averaged
    /// away. Measured over four real conversations (query = a known message's
    /// own text, scored against every chunk of that conversation), the chunk
    /// holding it lands in the top ten 56% of the time at ten messages, 79% at
    /// five and 90% at three. Three costs 429k chunks / ~78 min to build /
    /// 878 MB resident, which is past what can be kicked off unprompted; five
    /// costs 299k / ~54 min / 613 MB against ten's 206k / ~38 min / 423 MB.
    private static let chunkMessageLimit = 5
    private static let chunkGapNanoseconds: Int64 = 3 * 3600 * 1_000_000_000

    /// Rows reloaded before the in-memory matrix is considered stale.
    private static let reloadThreshold = 5_000

    /// One `NLEmbedding` per worker (they are not shared across threads).
    /// Measured on an M3 Pro: 91.5 embeddings/s sustained at 8 workers, so a
    /// first build of the real archive is about an hour of background work.
    private static let workerCount = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))

    let indexPath: String
    private let searchIndexPath: String
    private let batchSize: Int

    /// Serial: a second `sync()` waits rather than racing the first.
    private let syncQueue = DispatchQueue(label: "gg.besties.vector-index", qos: .utility)
    /// Held while the matrix is loaded or scanned. Kept separate from
    /// `stateLock` so `isReady`/`indexedChunks` never wait behind a load.
    private let searchLock = NSLock()
    private var matrix: [Float] = []
    private var rows: [Row] = []
    private var loadedChunks = 0
    private let stateLock = NSLock()
    private var cachedReady: Bool?
    private var cachedCount: Int?

    /// The metadata of one loaded chunk; the vector itself lives at
    /// `matrix[i * dimensions ..< (i + 1) * dimensions]`.
    private struct Row {
        let source: String
        let chatID: Int64
        let firstMessageID: Int64
        let lastMessageID: Int64
        let dateNano: Int64
        /// Chat ids collide between sources, so scoping compares this instead —
        /// an integer, to keep the per-row filter allocation-free.
        let chatKey: Int64
    }

    private static func chatKey(_ source: MessageSource, _ chatID: Int64) -> Int64 {
        chatID &* 2 &+ (source == .whatsApp ? 1 : 0)
    }

    init(indexPath: String? = nil, searchIndexPath: String? = nil, batchSize: Int = 10_000) {
        let dir = NSHomeDirectory() + "/Library/Application Support/Besties"
        self.indexPath = indexPath ?? dir + "/vec.sqlite"
        self.searchIndexPath = searchIndexPath ?? dir + "/search.sqlite"
        self.batchSize = batchSize
    }

    // MARK: - State

    /// True once a full sync has finished at least once. Reading it never
    /// creates the sidecar, so a machine that never syncs stays untouched.
    var isReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let cachedReady { return cachedReady }
        let ready = withExistingIndex { metaInt($0, "ready") == 1 } ?? false
        cachedReady = ready
        return ready
    }

    var indexedChunks: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return chunkCount()
    }

    // MARK: - Sync

    /// Embeds everything indexed since the last run. Safe to call on every
    /// launch: after the first build only new messages are chunked, which is a
    /// few seconds. `progress(done, total)` counts messages scanned across both
    /// sources and is called once per batch.
    func sync(progress: ((Int, Int) -> Void)? = nil) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            syncQueue.async {
                self.runSync(progress: progress)
                continuation.resume()
            }
        }
    }

    private func runSync(progress: ((Int, Int) -> Void)?) {
        // No FTS index yet → nothing to chunk, and no sidecar is created.
        guard FileManager.default.fileExists(atPath: searchIndexPath) else { return }
        guard let index = try? openIndex(), let msgs = openSearchIndex() else { return }
        defer { sqlite3_close(index); sqlite3_close(msgs) }

        resetIfSearchIndexRebuilt(index, msgs)

        var cursors: [Int64] = []
        var total = 0
        for source in Self.sources {
            let cursor = resetIfRewound(index, msgs, source)
            cursors.append(cursor)
            total += Int(scalarInt(msgs, """
                SELECT COUNT(*) FROM msgs WHERE id > \(cursor) AND id < \(Self.upperBound(source))
                """))
        }

        // Nothing new: the usual case on launch, and no reason to spin up the
        // embedding models. One instance per worker — they are not shared
        // across threads — kept for the whole run rather than per batch.
        if total > 0 {
            let embedders = (0 ..< Self.workerCount).compactMap { _ in NLEmbedding.sentenceEmbedding(for: .english) }
            guard embedders.count == Self.workerCount, embedders[0].dimension == Self.dimensions else { return }
            var scanned = 0
            for (source, cursor) in zip(Self.sources, cursors) {
                ingest(index: index, msgs: msgs, source: source, cursor: cursor, embedders: embedders) { rows in
                    scanned += rows
                    progress?(scanned, total)
                }
            }
        }

        setMetaInt(index, "ready", 1)
        stateLock.lock()
        cachedReady = true
        cachedCount = nil
        stateLock.unlock()
    }

    /// One source's pass. Messages are read in id order — which is arrival
    /// order, *not* date order — and accumulated into one open chunk per
    /// conversation; a chunk is emitted when it reaches five messages, when the
    /// next message in that conversation is more than three hours away in
    /// either direction, or when the batch ends. Closing at the batch boundary
    /// is what makes the cursor honest: every message up to it is already in a
    /// written chunk, so an interrupted run resumes at exactly the same
    /// boundary and produces exactly the same chunks.
    ///
    /// The symmetric gap is what keeps a chunk a moment rather than a grab bag.
    /// 12.7% of this archive's messages arrive older than the one before them
    /// in the same chat, 39,046 of them by more than three hours; checking only
    /// forward let those through, and 6.7% of chunks ended up dated more than a
    /// day away from their own contents (worst case: three messages spanning
    /// 2020 to 2024). Comparing the absolute gap costs 20% more chunks and puts
    /// the longest chunk at ten hours instead of 1,307 days.
    private func ingest(
        index: OpaquePointer,
        msgs: OpaquePointer,
        source: MessageSource,
        cursor startCursor: Int64,
        embedders: [NLEmbedding],
        onBatch: (Int) -> Void
    ) {
        var fetch: OpaquePointer?
        guard sqlite3_prepare_v2(msgs, """
            SELECT id, chat_id, date, text FROM msgs
            WHERE id > ? AND id < ?
            ORDER BY id
            LIMIT ?
            """, -1, &fetch, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(fetch) }

        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(index, """
            INSERT OR REPLACE INTO chunks(id, source, chat_id, last_msg_id, date, vec)
            VALUES (?, ?, ?, ?, ?, ?)
            """, -1, &insert, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(insert) }

        let cursorKey = Self.cursorKey(source)
        var cursor = startCursor

        while true {
            sqlite3_reset(fetch)
            sqlite3_bind_int64(fetch, 1, cursor)
            sqlite3_bind_int64(fetch, 2, Self.upperBound(source))
            sqlite3_bind_int(fetch, 3, Int32(batchSize))

            var open: [Int64: OpenChunk] = [:]
            var chunks: [OpenChunk] = []
            var rowsInBatch = 0
            var lastID = cursor
            while sqlite3_step(fetch) == SQLITE_ROW {
                rowsInBatch += 1
                lastID = sqlite3_column_int64(fetch, 0)
                let chatID = sqlite3_column_int64(fetch, 1)
                let date = sqlite3_column_int64(fetch, 2)
                let text = sqlite3_column_text(fetch, 3).map { String(cString: $0) } ?? ""

                if var chunk = open[chatID], abs(date - chunk.lastDateNano) <= Self.chunkGapNanoseconds {
                    chunk.append(id: lastID, date: date, text: text)
                    if chunk.count >= Self.chunkMessageLimit {
                        chunks.append(chunk)
                        open[chatID] = nil
                    } else {
                        open[chatID] = chunk
                    }
                } else {
                    if let previous = open[chatID] { chunks.append(previous) }
                    open[chatID] = OpenChunk(chatID: chatID, id: lastID, date: date, text: text)
                }
            }
            chunks.append(contentsOf: open.values)
            chunks.sort { $0.firstID < $1.firstID }
            let finished = rowsInBatch < batchSize
            let vectors = embed(chunks.map(\.text), embedders: embedders)

            exec(index, "BEGIN")
            for (i, chunk) in chunks.enumerated() where vectors.embedded[i] {
                sqlite3_reset(insert)
                sqlite3_bind_int64(insert, 1, chunk.firstID)
                sqlite3_bind_text(insert, 2, source.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(insert, 3, chunk.chatID)
                sqlite3_bind_int64(insert, 4, chunk.lastID)
                sqlite3_bind_int64(insert, 5, chunk.dateNano)
                vectors.matrix.withUnsafeBufferPointer { buffer in
                    sqlite3_bind_blob(insert, 6, buffer.baseAddress! + i * Self.dimensions,
                                      Int32(Self.dimensions * MemoryLayout<Float>.size), SQLITE_TRANSIENT)
                    sqlite3_step(insert)
                }
            }
            setMetaInt(index, cursorKey, lastID)
            exec(index, "COMMIT")
            cursor = lastID

            stateLock.lock()
            cachedCount = nil
            stateLock.unlock()
            onBatch(rowsInBatch)
            if finished { return }
        }
    }

    /// A conversation's messages so far, prefix-free: the model is fed the
    /// words that were typed, joined by spaces. ("Me:"/"Them:" labels measured
    /// 21% slower to embed with no recall gain — they belong in what a tool
    /// hands back, not in the vector.)
    ///
    /// `dateNano` is the earliest message's date rather than the first one's:
    /// ids are arrival order, so even inside a three-hour window the opening
    /// message is not reliably the oldest, and this date is what a search hit
    /// reports and what the tool's date filter compares.
    private struct OpenChunk {
        let chatID: Int64
        let firstID: Int64
        private(set) var dateNano: Int64
        private(set) var lastID: Int64
        private(set) var lastDateNano: Int64
        private(set) var count = 1
        private(set) var text: String

        init(chatID: Int64, id: Int64, date: Int64, text: String) {
            self.chatID = chatID
            firstID = id
            dateNano = date
            lastID = id
            lastDateNano = date
            self.text = text
        }

        mutating func append(id: Int64, date: Int64, text: String) {
            lastID = id
            lastDateNano = date
            dateNano = min(dateNano, date)
            count += 1
            self.text += " " + text
        }
    }

    /// Embeds one batch across `embedders.count` threads, one instance each.
    /// Returns the flat `texts.count × dimensions` matrix, unit-normalized,
    /// plus which rows the model actually produced a vector for.
    private func embed(_ texts: [String], embedders: [NLEmbedding]) -> (matrix: [Float], embedded: [Bool]) {
        let dimensions = Self.dimensions
        var matrix = [Float](repeating: 0, count: texts.count * dimensions)
        var embedded = [Bool](repeating: false, count: texts.count)
        guard !texts.isEmpty else { return (matrix, embedded) }
        let workers = embedders.count

        matrix.withUnsafeMutableBufferPointer { matrixBuffer in
            embedded.withUnsafeMutableBufferPointer { embeddedBuffer in
                let base = matrixBuffer.baseAddress!
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    let embedder = embedders[worker]
                    var i = worker
                    while i < texts.count {
                        if let vector = embedder.vector(for: texts[i]), vector.count == dimensions {
                            let row = base + i * dimensions
                            for j in 0 ..< dimensions { row[j] = Float(vector[j]) }
                            Self.normalize(row, dimensions)
                            embeddedBuffer[i] = true
                        }
                        i += workers
                    }
                }
            }
        }
        return (matrix, embedded)
    }

    /// Mirrors `SearchIndex`'s relink handling one level down: our upstream is
    /// `search.sqlite`, so when a source's ids go backwards there (chat.db
    /// restored, WhatsApp relinked and Z_PK restarted) only that source's
    /// chunks are dropped. Returns the cursor to start from.
    private func resetIfRewound(_ index: OpaquePointer, _ msgs: OpaquePointer, _ source: MessageSource) -> Int64 {
        let base = Self.baseID(source)
        let key = Self.cursorKey(source)
        let cursor = metaInt(index, key) ?? base
        guard cursor > base else { return base }
        let upstream = scalarInt(msgs, """
            SELECT COALESCE(MAX(id), 0) FROM msgs WHERE id > \(base) AND id < \(Self.upperBound(source))
            """)
        guard upstream < cursor else { return cursor }
        exec(index, "DELETE FROM chunks WHERE source = '\(source.rawValue)'")
        setMetaInt(index, key, base)
        stateLock.lock()
        cachedCount = nil
        stateLock.unlock()
        clearResidentMatrix()
        return base
    }

    /// `search.sqlite` can also change out from under us without any id going
    /// backwards — a schema bump rebuilds it in place, and `Settings ▸ rebuild`
    /// deletes the file and re-indexes — so `resetIfRewound` never fires and the
    /// chunks are left describing runs of messages the index no longer holds.
    /// Its schema version is recorded here and a change rebuilds every chunk.
    /// (A rebuild at the *same* schema version keeps the same ids, so the only
    /// chunks it invalidates are ones whose messages are gone; `semantic_search`
    /// drops those when they hydrate to nothing.)
    private func resetIfSearchIndexRebuilt(_ index: OpaquePointer, _ msgs: OpaquePointer) {
        let upstream = metaInt(msgs, "schema_version") ?? 0
        let stored = metaInt(index, "search_schema_version")
        guard stored != upstream else { return }
        // An index from before this key existed is adopted rather than thrown
        // away: it was built against the schema that is there now, and a rebuild
        // is an hour of work to fix nothing.
        if stored != nil {
            exec(index, "DELETE FROM chunks")
            for source in Self.sources { setMetaInt(index, Self.cursorKey(source), Self.baseID(source)) }
            stateLock.lock()
            cachedCount = nil
            stateLock.unlock()
            clearResidentMatrix()
        }
        setMetaInt(index, "search_schema_version", upstream)
    }

    /// Drops whatever a search is holding in memory, after chunks have been
    /// deleted underneath it. Called from the sync queue only — never while
    /// `searchLock` is already held.
    private func clearResidentMatrix() {
        searchLock.lock()
        matrix = []
        rows = []
        loadedChunks = 0
        searchLock.unlock()
    }

    // MARK: - Search

    /// Nearest chunks by cosine similarity, best first. Empty until the first
    /// sync has finished.
    ///
    /// `chats` restricts the scan to one person's conversations and is how this
    /// should normally be called: measured over the real archive, unscoped
    /// semantic search ranks the right chunk around 5,000th, while the same
    /// query scoped to the right person lands it in the top ten two thirds of
    /// the time.
    ///
    /// `after`/`before` bound the chunk's date the same way — as a filter
    /// applied *before* the top-k, so a caller asking for fifteen hits inside
    /// one year gets the best fifteen of that year rather than whatever
    /// survives a global top-k. Both compare the chunk's earliest message.
    func search(
        _ query: String, limit: Int,
        chats: [SearchIndex.ChatRef]? = nil,
        after: Date? = nil, before: Date? = nil
    ) async -> [Hit] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Hit], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.runSearch(query, limit: limit, chats: chats,
                                                              after: after, before: before))
            }
        }
    }

    private func runSearch(
        _ query: String, limit: Int, chats: [SearchIndex.ChatRef]?, after: Date?, before: Date?
    ) -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0, isReady else { return [] }
        guard let embedder = NLEmbedding.sentenceEmbedding(for: .english),
              let raw = embedder.vector(for: trimmed), raw.count == Self.dimensions else { return [] }
        var vector = raw.map { Float($0) }
        vector.withUnsafeMutableBufferPointer { Self.normalize($0.baseAddress!, Self.dimensions) }

        searchLock.lock()
        defer { searchLock.unlock() }
        loadIfNeeded()
        let count = rows.count
        guard count > 0 else { return [] }

        // Both sides are unit vectors, so the matrix–vector product *is* the
        // cosine of every chunk at once: ~14 ms over a 300k × 512 matrix.
        var scores = [Float](repeating: 0, count: count)
        matrix.withUnsafeBufferPointer { m in
            vDSP_mmul(m.baseAddress!, 1, vector, 1, &scores, 1,
                      vDSP_Length(count), 1, vDSP_Length(Self.dimensions))
        }

        let allowed = chats.map { Set($0.map { Self.chatKey($0.source, $0.id) }) }
        let start = after.map { MessageStore.nanoseconds(from: $0) }
        let end = before.map { MessageStore.nanoseconds(from: $0) }
        var best: [(index: Int, score: Float)] = []
        best.reserveCapacity(limit + 1)
        var threshold = -Float.greatestFiniteMagnitude
        for i in 0 ..< count {
            let score = scores[i]
            if best.count == limit, score <= threshold { continue }
            if let allowed, !allowed.contains(rows[i].chatKey) { continue }
            if let start, rows[i].dateNano < start { continue }
            if let end, rows[i].dateNano >= end { continue }
            best.insert((i, score), at: best.firstIndex { $0.score < score } ?? best.count)
            if best.count > limit { best.removeLast() }
            if best.count == limit { threshold = best[limit - 1].score }
        }

        return best.map { candidate in
            let row = rows[candidate.index]
            let offset = row.source == MessageSource.whatsApp.rawValue ? Self.whatsAppIDOffset : 0
            return Hit(
                source: row.source,
                chatID: row.chatID,
                firstMessageID: row.firstMessageID - offset,
                lastMessageID: row.lastMessageID - offset,
                date: Date(timeIntervalSinceReferenceDate: Double(row.dateNano) / 1_000_000_000),
                score: Double(candidate.score)
            )
        }
    }

    /// Loads the whole matrix into memory the first time a search runs, and
    /// again once the index has grown by `reloadThreshold` chunks since — or
    /// whenever it has *shrunk*, which is what a per-source reset or a
    /// drop-and-rebuild looks like from here. Those rows are gone (and after a
    /// model change the remaining ones mean something else), so a resident copy
    /// of them would answer with hits that no longer exist. At ~300k chunks the
    /// matrix is 512 × 4 bytes × 300k ≈ 613 MB resident, plus ~14 MB of row
    /// metadata; the old one is released before the new one is allocated, since
    /// holding both would double that for the length of the load.
    private func loadIfNeeded() {
        let count = indexedChunks
        guard rows.isEmpty || count < loadedChunks || count - loadedChunks >= Self.reloadThreshold else { return }
        matrix = []
        rows = []
        loadedChunks = 0
        guard count > 0 else { return }

        let dimensions = Self.dimensions
        var newRows: [Row] = []
        newRows.reserveCapacity(count)
        var newMatrix = [Float](repeating: 0, count: count * dimensions)
        var filled = 0

        withExistingIndex { index in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(index, """
                SELECT id, source, chat_id, last_msg_id, date, vec FROM chunks ORDER BY id
                """, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let bytes = Int(sqlite3_column_bytes(stmt, 5))
                guard bytes == dimensions * MemoryLayout<Float>.size,
                      let blob = sqlite3_column_blob(stmt, 5) else { continue }
                if (filled + 1) * dimensions > newMatrix.count {
                    newMatrix.append(contentsOf: repeatElement(0, count: dimensions * 1024))
                }
                // The blob has no alignment guarantee, so it is copied rather
                // than rebound.
                newMatrix.withUnsafeMutableBufferPointer { buffer in
                    _ = memcpy(buffer.baseAddress! + filled * dimensions, blob, bytes)
                }
                filled += 1
                let source = String(cString: sqlite3_column_text(stmt, 1))
                let chatID = sqlite3_column_int64(stmt, 2)
                newRows.append(Row(
                    source: source,
                    chatID: chatID,
                    firstMessageID: sqlite3_column_int64(stmt, 0),
                    lastMessageID: sqlite3_column_int64(stmt, 3),
                    dateNano: sqlite3_column_int64(stmt, 4),
                    chatKey: Self.chatKey(MessageSource(rawValue: source) ?? .iMessage, chatID)
                ))
            }
        }

        newMatrix.removeLast(newMatrix.count - filled * dimensions)
        matrix = newMatrix
        rows = newRows
        loadedChunks = newRows.count
    }

    private static func normalize(_ vector: UnsafeMutablePointer<Float>, _ count: Int) {
        var sum: Float = 0
        vDSP_svesq(vector, 1, &sum, vDSP_Length(count))
        var norm = sqrt(sum)
        guard norm > 0 else { return }
        vDSP_vsdiv(vector, 1, &norm, vector, 1, vDSP_Length(count))
    }

    // MARK: - Plumbing

    private static let sources: [MessageSource] = [.iMessage, .whatsApp]

    private static func baseID(_ source: MessageSource) -> Int64 {
        source == .whatsApp ? whatsAppIDOffset : 0
    }

    private static func upperBound(_ source: MessageSource) -> Int64 {
        source == .whatsApp ? Int64.max : whatsAppIDOffset
    }

    private static func cursorKey(_ source: MessageSource) -> String {
        source == .whatsApp ? "wa_last_msg_id" : "last_msg_id"
    }

    private func openIndex() throws -> OpaquePointer {
        let directory = (indexPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        var db: OpaquePointer?
        guard sqlite3_open_v2(indexPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw MessageStoreError.openFailed(message)
        }
        // A 2 KB vector row does not fit a default 4 KB page once the header is
        // there, so each one spills into an overflow page and the file comes out
        // nearly twice the size of its data (measured at 172k chunks: 677 MB vs
        // 388 MB, so ~2.3 GB vs ~1.2 GB at the ~300k chunks this now builds).
        // The pragma only takes effect while the file is empty, so it has to
        // come before WAL and before any table.
        //
        // `value` is typeless on purpose: cursors and flags are integers, the
        // model id is text, and SQLite stores each as it is bound.
        exec(db, """
            PRAGMA page_size = 16384;
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value);
            """)
        // Different schema or different model ⇒ the stored vectors mean
        // something else; they are dropped rather than mixed with new ones.
        let stale = metaInt(db, "schema_version") != Int64(Self.schemaVersion)
            || metaText(db, "model") != Self.modelID
            || metaInt(db, "dimensions") != Int64(Self.dimensions)
        if stale {
            exec(db, "DROP TABLE IF EXISTS chunks; DELETE FROM meta;")
        }
        // `id` is the chunk's first message id (unique across sources thanks to
        // the WhatsApp offset), which makes re-running an interrupted batch a
        // rewrite rather than a duplicate. The date index keeps COUNT(*) off
        // the vector pages.
        exec(db, """
            CREATE TABLE IF NOT EXISTS chunks(
                id INTEGER PRIMARY KEY,
                source TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                last_msg_id INTEGER NOT NULL,
                date INTEGER NOT NULL,
                vec BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS chunks_date ON chunks(date);
            """)
        if stale {
            setMetaInt(db, "schema_version", Int64(Self.schemaVersion))
            setMetaText(db, "model", Self.modelID)
            setMetaInt(db, "dimensions", Int64(Self.dimensions))
        }
        return db
    }

    /// nil when the FTS index hasn't been built yet — there is nothing to chunk.
    private func openSearchIndex() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(searchIndexPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    /// Opens the sidecar only if it is already there, so reading state never
    /// brings the file into existence.
    private func withExistingIndex<T>(_ body: (OpaquePointer) -> T) -> T? {
        guard FileManager.default.fileExists(atPath: indexPath), let index = try? openIndex() else { return nil }
        defer { sqlite3_close(index) }
        return body(index)
    }

    private func chunkCount() -> Int {
        if let cachedCount { return cachedCount }
        let count = withExistingIndex { Int(scalarInt($0, "SELECT COUNT(*) FROM chunks")) } ?? 0
        cachedCount = count
        return count
    }

    private func exec(_ db: OpaquePointer, _ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func scalarInt(_ db: OpaquePointer, _ sql: String) -> Int64 {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    private func metaValue(_ db: OpaquePointer, _ key: String, _ read: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return }
        read(stmt)
    }

    private func metaInt(_ db: OpaquePointer, _ key: String) -> Int64? {
        var value: Int64?
        metaValue(db, key) { value = sqlite3_column_int64($0, 0) }
        return value
    }

    private func metaText(_ db: OpaquePointer, _ key: String) -> String? {
        var value: String?
        metaValue(db, key) { stmt in
            value = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
        }
        return value
    }

    private func setMetaInt(_ db: OpaquePointer, _ key: String, _ value: Int64) {
        setMeta(db, key) { sqlite3_bind_int64($0, 2, value) }
    }

    private func setMetaText(_ db: OpaquePointer, _ key: String, _ value: String) {
        setMeta(db, key) { sqlite3_bind_text($0, 2, value, -1, SQLITE_TRANSIENT) }
    }

    private func setMeta(_ db: OpaquePointer, _ key: String, _ bindValue: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        bindValue(stmt)
        sqlite3_step(stmt)
    }
}
