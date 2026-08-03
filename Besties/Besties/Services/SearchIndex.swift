import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Sidecar FTS5 full-text index over the iMessage and WhatsApp histories,
/// stored in Application Support. Neither source DB is ever written; we mirror
/// decoded message text into our own SQLite file and search that. Sync is
/// incremental per source, keyed on message rowid; if a source's rowids ever
/// go backwards (restored/relinked DB) its rows are dropped and reindexed.
final class SearchIndex {
    struct Result: Identifiable {
        let rowID: Int64
        let source: MessageSource
        let chatID: Int64
        let dateNano: Int64
        let date: Date
        let isFromMe: Bool
        let snippet: String

        /// chat.db rowids and WhatsApp Z_PKs overlap, so identity is per source.
        var id: String { "\(source.rawValue)-\(rowID)" }
    }

    /// A chat to restrict results to. The two sources number their chats
    /// independently, so a chat id is only meaningful alongside its source.
    struct ChatRef: Hashable {
        let source: MessageSource
        let id: Int64
    }

    private static let schemaVersion = 3

    /// WhatsApp ids are stored shifted past any plausible chat.db rowid, so
    /// `msgs.id` (and the FTS rowid it mirrors) stays unique across sources.
    private static let whatsAppIDOffset: Int64 = 1 << 40

    /// 1:1, dated, non-system WhatsApp messages that carry text — the same
    /// app-wide "no group chats" rule WhatsAppStore applies, so every hit maps
    /// back to a person.
    private static let whatsAppFilter = """
        cs.ZCONTACTJID LIKE '%@s.whatsapp.net'
          AND m.ZMESSAGETYPE != 10
          AND m.ZMESSAGEDATE > 0
          AND m.ZTEXT IS NOT NULL
          AND m.ZTEXT != ''
        """

    let indexPath: String
    private let chatDBPath: String
    private let whatsAppDBPath: String

    init(indexPath: String? = nil,
         chatDBPath: String = NSHomeDirectory() + "/Library/Messages/chat.db",
         whatsAppDBPath: String = WhatsAppStore.dbPath) {
        if let indexPath {
            self.indexPath = indexPath
        } else {
            let dir = NSHomeDirectory() + "/Library/Application Support/Besties"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            self.indexPath = dir + "/search.sqlite"
        }
        self.chatDBPath = chatDBPath
        self.whatsAppDBPath = whatsAppDBPath
    }

    // MARK: - Sync

    /// Indexes messages newer than the last sync, from both sources. Returns
    /// the number of newly indexed messages. `progress(done, total)` is called
    /// once per batch, counting both sources together.
    @discardableResult
    func sync(progress: ((Int, Int) -> Void)? = nil) throws -> Int {
        let index = try openIndex()
        defer { sqlite3_close(index) }
        let chat = try openChatDB()
        defer { sqlite3_close(chat) }
        let whatsApp = openWhatsAppDB()
        defer { if let whatsApp { sqlite3_close(whatsApp) } }

        var lastRowID = metaInt(index, "last_rowid") ?? 0

        // Rowids went backwards → chat.db was replaced; rebuild from zero.
        // The FTS index has to be emptied before its content table (a plain
        // DELETE would read the old text back from `msgs`), and only the
        // cursors are cleared — dropping schema_version would make the next
        // open call the freshly built index stale and throw it away.
        if lastRowID > 0, scalarInt(chat, "SELECT COALESCE(MAX(rowid), 0) FROM message") < lastRowID {
            exec(index, """
                INSERT INTO msgs_fts(msgs_fts) VALUES('delete-all');
                DELETE FROM msgs;
                DELETE FROM meta WHERE key IN ('last_rowid', 'wa_last_rowid');
                """)
            lastRowID = 0
        }

        // Same check for WhatsApp (a relinked device starts over at Z_PK 1),
        // but only its own rows are dropped — the FTS index is external-content,
        // so the old text has to be handed back before the row disappears.
        var waLastRowID = metaInt(index, "wa_last_rowid") ?? 0
        if let whatsApp, waLastRowID > 0,
           scalarInt(whatsApp, "SELECT COALESCE(MAX(Z_PK), 0) FROM ZWAMESSAGE") < waLastRowID {
            exec(index, """
                INSERT INTO msgs_fts(msgs_fts, rowid, text)
                    SELECT 'delete', id, text FROM msgs WHERE source = 'w';
                DELETE FROM msgs WHERE source = 'w';
                """)
            waLastRowID = 0
        }

        let chatTotal = Int(scalarInt(chat, """
            SELECT COUNT(*) FROM message
            WHERE rowid > \(lastRowID) AND item_type = 0 AND associated_message_type = 0
            """))
        let waTotal = whatsApp.map {
            Int(scalarInt($0, """
                SELECT COUNT(*) FROM ZWAMESSAGE m
                JOIN ZWACHATSESSION cs ON cs.Z_PK = m.ZCHATSESSION
                WHERE m.Z_PK > \(waLastRowID) AND \(Self.whatsAppFilter)
                """))
        } ?? 0
        let total = chatTotal + waTotal
        if total == 0 { return 0 }

        var scanned = 0
        let onBatch = { (rows: Int) in
            scanned += rows
            progress?(scanned, total)
        }

        var indexed = try ingest(
            into: index, from: chat, source: .iMessage, cursor: lastRowID, onBatch: onBatch,
            sql: """
                SELECT m.rowid,
                       COALESCE((SELECT cmj.chat_id FROM chat_message_join cmj WHERE cmj.message_id = m.rowid LIMIT 1), 0),
                       m.date, m.is_from_me, m.text, m.attributedBody, m.cache_has_attachments
                FROM message m
                WHERE m.rowid > ? AND m.item_type = 0 AND m.associated_message_type = 0
                ORDER BY m.rowid
                LIMIT ?
                """
        ) { stmt in
            let text = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            var blob: Data?
            if let bytes = sqlite3_column_blob(stmt, 5) {
                blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 5)))
            }
            // hasAttachment: false so attachment-only messages come back
            // "[unsupported]" and stay out of the index — nothing to search.
            let body = MessageStore.decodeBody(text: text, blob: blob, hasAttachment: false)
            if body == "[unsupported]" { return nil }
            return (body, sqlite3_column_int(stmt, 6) == 1)
        }

        if let whatsApp {
            indexed += try ingest(
                into: index, from: whatsApp, source: .whatsApp, cursor: waLastRowID, onBatch: onBatch,
                sql: """
                    SELECT m.Z_PK, m.ZCHATSESSION,
                           CAST(m.ZMESSAGEDATE * 1000000000.0 AS INTEGER),
                           m.ZISFROMME, m.ZTEXT, m.ZMEDIAITEM IS NOT NULL
                    FROM ZWAMESSAGE m
                    JOIN ZWACHATSESSION cs ON cs.Z_PK = m.ZCHATSESSION
                    WHERE m.Z_PK > ? AND \(Self.whatsAppFilter)
                    ORDER BY m.Z_PK
                    LIMIT ?
                    """
            ) { stmt in
                let text = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // A WhatsApp media message with a caption keeps its caption in ZTEXT.
                return trimmed.isEmpty ? nil : (trimmed, sqlite3_column_int(stmt, 5) == 1)
            }
        }
        return indexed
    }

    /// One source's batched pass. `sql` selects (rowid, chat_id, date,
    /// is_from_me, …) for rows past the cursor, binding the cursor and the
    /// batch limit in that order; `body` reads the remaining columns and
    /// returns the text plus its attachment flag, or nil for rows with nothing
    /// to index. The cursor is persisted after every batch, so an interrupted
    /// sync resumes where it stopped.
    private func ingest(
        into index: OpaquePointer,
        from db: OpaquePointer,
        source: MessageSource,
        cursor: Int64,
        onBatch: (Int) -> Void,
        sql: String,
        body: (OpaquePointer?) -> (text: String, hasAttachment: Bool)?
    ) throws -> Int {
        var fetch: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &fetch, nil) == SQLITE_OK else {
            throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(fetch) }

        var insertMsg: OpaquePointer?
        var insertFTS: OpaquePointer?
        sqlite3_prepare_v2(index, "INSERT OR REPLACE INTO msgs(id, source, chat_id, date, is_from_me, has_attachment, has_link, text) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", -1, &insertMsg, nil)
        sqlite3_prepare_v2(index, "INSERT INTO msgs_fts(rowid, text) VALUES (?, ?)", -1, &insertFTS, nil)
        defer { sqlite3_finalize(insertMsg); sqlite3_finalize(insertFTS) }

        let idOffset = source == .whatsApp ? Self.whatsAppIDOffset : 0
        let cursorKey = source == .whatsApp ? "wa_last_rowid" : "last_rowid"
        let batchSize = 10_000
        var lastRowID = cursor
        var indexed = 0

        while true {
            sqlite3_reset(fetch)
            sqlite3_bind_int64(fetch, 1, lastRowID)
            sqlite3_bind_int(fetch, 2, Int32(batchSize))

            var rowsInBatch = 0
            exec(index, "BEGIN")
            while sqlite3_step(fetch) == SQLITE_ROW {
                rowsInBatch += 1
                lastRowID = sqlite3_column_int64(fetch, 0)
                guard let row = body(fetch) else { continue }
                let id = lastRowID + idOffset

                sqlite3_reset(insertMsg)
                sqlite3_bind_int64(insertMsg, 1, id)
                sqlite3_bind_text(insertMsg, 2, source.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(insertMsg, 3, sqlite3_column_int64(fetch, 1))
                sqlite3_bind_int64(insertMsg, 4, sqlite3_column_int64(fetch, 2))
                sqlite3_bind_int(insertMsg, 5, sqlite3_column_int(fetch, 3))
                sqlite3_bind_int(insertMsg, 6, row.hasAttachment ? 1 : 0)
                sqlite3_bind_int(insertMsg, 7, Self.containsLink(row.text) ? 1 : 0)
                sqlite3_bind_text(insertMsg, 8, row.text, -1, SQLITE_TRANSIENT)
                sqlite3_step(insertMsg)

                sqlite3_reset(insertFTS)
                sqlite3_bind_int64(insertFTS, 1, id)
                sqlite3_bind_text(insertFTS, 2, row.text, -1, SQLITE_TRANSIENT)
                sqlite3_step(insertFTS)
                indexed += 1
            }
            setMetaInt(index, cursorKey, lastRowID)
            exec(index, "COMMIT")

            onBatch(rowsInBatch)
            if rowsInBatch < batchSize { break }
        }
        return indexed
    }

    // MARK: - Search

    enum Sort: String, CaseIterable, Identifiable {
        case relevance = "Best match"
        case newest = "Newest"
        case oldest = "Oldest"
        var id: String { rawValue }
    }

    struct Options {
        /// nil = no person filter; empty = a person with no indexed chats (zero results).
        var chats: [ChatRef]? = nil
        var source: MessageSource? = nil
        var startDate: Date? = nil
        var endDate: Date? = nil
        var fromMe: Bool? = nil
        /// Toggles, not tri-states: on = only messages that have one.
        var hasAttachment = false
        var hasLink = false
        var sort: Sort = .relevance
        var limit: Int = 200
        /// Rows to skip — the page being fetched. Every sort order breaks ties
        /// on `m.id`, so paging by offset can't repeat or drop a result.
        var offset: Int = 0
    }

    /// Snippets wrap matched terms in these private-use markers so the UI can
    /// highlight them without HTML-style escaping issues.
    static let markStart = "\u{E000}"
    static let markEnd = "\u{E001}"

    /// Ranked full-text search. `query` is raw user input; it is converted to
    /// an FTS5 match expression with prefix matching on the last term, so
    /// results update sensibly as the user types. `total` is the full match
    /// count before `options.limit`/`offset` are applied.
    func search(_ query: String, options: Options = Options()) throws -> (results: [Result], total: Int) {
        let match = Self.matchExpression(query)
        guard !match.isEmpty else { return ([], 0) }

        let index = try openIndex()
        defer { sqlite3_close(index) }

        var conditions = ["msgs_fts MATCH ?"]
        if let chats = options.chats {
            // Chat ids collide between sources, so each source brings its own list.
            let perSource = Dictionary(grouping: chats, by: \.source).map { source, refs in
                "(m.source = '\(source.rawValue)' AND m.chat_id IN (\(refs.map { String($0.id) }.joined(separator: ", "))))"
            }
            conditions.append(perSource.isEmpty ? "0" : "(\(perSource.joined(separator: " OR ")))")
        }
        if let source = options.source {
            conditions.append("m.source = '\(source.rawValue)'")
        }
        if let start = options.startDate {
            conditions.append("m.date >= \(MessageStore.nanoseconds(from: start))")
        }
        if let end = options.endDate {
            conditions.append("m.date < \(MessageStore.nanoseconds(from: end))")
        }
        if let fromMe = options.fromMe {
            conditions.append("m.is_from_me = \(fromMe ? 1 : 0)")
        }
        if options.hasAttachment {
            conditions.append("m.has_attachment = 1")
        }
        if options.hasLink {
            conditions.append("m.has_link = 1")
        }
        let whereSQL = conditions.joined(separator: " AND ")
        let orderSQL = switch options.sort {
        case .relevance: "bm25(msgs_fts), m.id"
        case .newest: "m.date DESC, m.id DESC"
        case .oldest: "m.date ASC, m.id ASC"
        }

        let sql = """
            SELECT m.id, m.source, m.chat_id, m.date, m.is_from_me,
                   snippet(msgs_fts, 0, '\(Self.markStart)', '\(Self.markEnd)', '…', 12)
            FROM msgs_fts
            JOIN msgs m ON m.id = msgs_fts.rowid
            WHERE \(whereSQL)
            ORDER BY \(orderSQL)
            LIMIT \(options.limit) OFFSET \(options.offset)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(index, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(index)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)

        var results: [Result] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let source = MessageSource(rawValue: String(cString: sqlite3_column_text(stmt, 1))) ?? .iMessage
            let dateNano = sqlite3_column_int64(stmt, 3)
            results.append(Result(
                rowID: sqlite3_column_int64(stmt, 0) - (source == .whatsApp ? Self.whatsAppIDOffset : 0),
                source: source,
                chatID: sqlite3_column_int64(stmt, 2),
                dateNano: dateNano,
                date: Date(timeIntervalSinceReferenceDate: Double(dateNano) / 1_000_000_000),
                isFromMe: sqlite3_column_int(stmt, 4) == 1,
                snippet: String(cString: sqlite3_column_text(stmt, 5))
            ))
        }

        var total = options.offset + results.count
        if results.count == options.limit {
            let countSQL = "SELECT COUNT(*) FROM msgs_fts JOIN msgs m ON m.id = msgs_fts.rowid WHERE \(whereSQL)"
            var countStmt: OpaquePointer?
            if sqlite3_prepare_v2(index, countSQL, -1, &countStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(countStmt, 1, match, -1, SQLITE_TRANSIENT)
                if sqlite3_step(countStmt) == SQLITE_ROW {
                    total = Int(sqlite3_column_int64(countStmt, 0))
                }
            }
            sqlite3_finalize(countStmt)
        }
        return (results, total)
    }

    /// How many messages are currently in the index.
    func indexedCount() -> Int {
        guard let index = try? openIndex() else { return 0 }
        defer { sqlite3_close(index) }
        return Int(scalarInt(index, "SELECT COUNT(*) FROM msgs"))
    }

    /// Escapes raw user input into an FTS5 match expression: each word becomes
    /// a quoted token (so apostrophes, hyphens etc. never break the query) and
    /// the final word matches as a prefix.
    static func matchExpression(_ input: String) -> String {
        let words = input.split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return "" }
        var tokens = words.map { "\"\($0)\"" }
        tokens[tokens.count - 1] += "*"
        return tokens.joined(separator: " ")
    }

    /// Index-time link detection: does the body contain "http://", "https://"
    /// or "www."? NSDataDetector is far too slow over a million messages (and
    /// would call every "see you at 8pm." a domain), and so, it turns out, is
    /// `String.range(of:options:)` — 13 s of a full rebuild. This slides an
    /// 8-byte window over the UTF-8 instead: one pass, no allocation, ~0.1 s.
    static func containsLink(_ text: String) -> Bool {
        var window: UInt64 = 0
        for byte in text.utf8 {
            window = (window << 8) | UInt64(byte | 0x20)   // ASCII-lowercased
            if window & 0xFFFF_FFFF == 0x7777_772E {                                    // "www."
                // …but only starting a word, so "awww. no" isn't a link.
                let prev = (window >> 32) & 0xFF
                if !(prev >= 0x61 && prev <= 0x7A) && !(prev >= 0x30 && prev <= 0x39) { return true }
            }
            if window & 0x00FF_FFFF_FFFF_FFFF == 0x0068_7474_703A_2F2F { return true }  // "http://"
            if window == 0x6874_7470_733A_2F2F { return true }                          // "https://"
        }
        return false
    }

    // MARK: - Plumbing

    private func openIndex() throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(indexPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw MessageStoreError.openFailed(msg)
        }
        exec(db, """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value INTEGER);
            """)
        // An older index has the wrong columns, so it's dropped rather than
        // emptied; the next sync rebuilds it from scratch.
        let stale = metaInt(db, "schema_version") != Int64(Self.schemaVersion)
        if stale {
            exec(db, "DROP TABLE IF EXISTS msgs_fts; DROP TABLE IF EXISTS msgs; DELETE FROM meta;")
        }
        exec(db, """
            CREATE TABLE IF NOT EXISTS msgs(
                id INTEGER PRIMARY KEY,
                source TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                date INTEGER NOT NULL,
                is_from_me INTEGER NOT NULL,
                has_attachment INTEGER NOT NULL,
                has_link INTEGER NOT NULL,
                text TEXT NOT NULL
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS msgs_fts USING fts5(
                text, content='msgs', content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            );
            """)
        if stale {
            setMetaInt(db, "schema_version", Int64(Self.schemaVersion))
        }
        return db
    }

    /// nil when WhatsApp isn't installed — its messages are simply skipped.
    private func openWhatsAppDB() -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: whatsAppDBPath) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(whatsAppDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    private func openChatDB() throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(chatDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw MessageStoreError.openFailed(msg)
        }
        return db
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

    private func metaInt(_ db: OpaquePointer, _ key: String) -> Int64? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private func setMetaInt(_ db: OpaquePointer, _ key: String, _ value: Int64) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, value)
        sqlite3_step(stmt)
    }
}
