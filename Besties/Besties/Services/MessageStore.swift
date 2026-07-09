import Foundation
import SQLite3

final class MessageStore {
    private let dbPath: String = {
        NSHomeDirectory() + "/Library/Messages/chat.db"
    }()

    func fetchConversations() throws -> [Conversation] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw MessageStoreError.openFailed(msg)
        }
        defer { sqlite3_close(db) }

        let sql = """
            WITH chat_stats AS (
                SELECT
                    cmj.chat_id,
                    COUNT(*) AS total_messages,
                    SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
                    SUM(CASE WHEN m.is_from_me = 0 THEN 1 ELSE 0 END) AS received,
                    MIN(m.date) AS first_date,
                    MAX(m.date) AS last_date
                FROM chat_message_join cmj
                INNER JOIN message m ON m.rowid = cmj.message_id
                GROUP BY cmj.chat_id
            ),
            last_msg AS (
                SELECT
                    cmj.chat_id,
                    m.is_from_me
                FROM chat_message_join cmj
                INNER JOIN message m ON m.rowid = cmj.message_id
                INNER JOIN chat_stats cs ON cs.chat_id = cmj.chat_id AND m.date = cs.last_date
                GROUP BY cmj.chat_id
            )
            SELECT
                h.rowid,
                h.id,
                cs.total_messages,
                cs.sent,
                cs.received,
                cs.first_date,
                cs.last_date,
                COALESCE(lm.is_from_me, 0),
                h.person_centric_id
            FROM chat c
            INNER JOIN chat_handle_join chj ON chj.chat_id = c.rowid
            INNER JOIN handle h ON h.rowid = chj.handle_id
            INNER JOIN chat_stats cs ON cs.chat_id = c.rowid
            LEFT JOIN last_msg lm ON lm.chat_id = c.rowid
            WHERE c.chat_identifier NOT LIKE 'chat%'
            GROUP BY c.rowid
            HAVING COUNT(DISTINCT chj.handle_id) = 1
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db!))
            throw MessageStoreError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        var conversations: [Conversation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let handleId = sqlite3_column_int64(stmt, 0)
            let handle = String(cString: sqlite3_column_text(stmt, 1))
            let total = Int(sqlite3_column_int(stmt, 2))
            let sent = Int(sqlite3_column_int(stmt, 3))
            let received = Int(sqlite3_column_int(stmt, 4))
            let firstNano = sqlite3_column_int64(stmt, 5)
            let lastNano = sqlite3_column_int64(stmt, 6)
            let lastFromMe = sqlite3_column_int(stmt, 7) == 1
            let personID = Self.personID(stmt, 8)

            let firstDate = Self.dateFromCoreData(nanoseconds: firstNano)
            let lastDate = Self.dateFromCoreData(nanoseconds: lastNano)

            conversations.append(Conversation(
                id: handleId,
                handle: handle,
                personID: personID,
                totalMessages: total,
                sentMessages: sent,
                receivedMessages: received,
                firstMessageDate: firstDate,
                lastMessageDate: lastDate,
                lastMessageIsFromMe: lastFromMe
            ))
        }
        return conversations
    }

    /// Per-conversation message stats grouped by calendar month, keyed "yyyy-MM".
    func fetchConversationsByMonth() throws -> [String: [Conversation]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw MessageStoreError.openFailed(msg)
        }
        defer { sqlite3_close(db) }

        let sql = """
            WITH chat_stats AS (
                SELECT
                    cmj.chat_id,
                    strftime('%Y-%m', datetime(m.date / 1000000000 + 978307200, 'unixepoch', 'localtime')) AS month,
                    COUNT(*) AS total_messages,
                    SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
                    SUM(CASE WHEN m.is_from_me = 0 THEN 1 ELSE 0 END) AS received,
                    MIN(m.date) AS first_date,
                    MAX(m.date) AS last_date
                FROM chat_message_join cmj
                INNER JOIN message m ON m.rowid = cmj.message_id
                GROUP BY cmj.chat_id, month
            )
            SELECT
                h.rowid,
                h.id,
                cs.month,
                cs.total_messages,
                cs.sent,
                cs.received,
                cs.first_date,
                cs.last_date
            FROM chat c
            INNER JOIN chat_handle_join chj ON chj.chat_id = c.rowid
            INNER JOIN handle h ON h.rowid = chj.handle_id
            INNER JOIN chat_stats cs ON cs.chat_id = c.rowid
            WHERE c.chat_identifier NOT LIKE 'chat%'
            GROUP BY c.rowid, cs.month
            HAVING COUNT(DISTINCT chj.handle_id) = 1
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db!))
            throw MessageStoreError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        var byMonth: [String: [Conversation]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let handleId = sqlite3_column_int64(stmt, 0)
            let handle = String(cString: sqlite3_column_text(stmt, 1))
            let month = String(cString: sqlite3_column_text(stmt, 2))
            let total = Int(sqlite3_column_int(stmt, 3))
            let sent = Int(sqlite3_column_int(stmt, 4))
            let received = Int(sqlite3_column_int(stmt, 5))
            let firstNano = sqlite3_column_int64(stmt, 6)
            let lastNano = sqlite3_column_int64(stmt, 7)

            byMonth[month, default: []].append(Conversation(
                id: handleId,
                handle: handle,
                totalMessages: total,
                sentMessages: sent,
                receivedMessages: received,
                firstMessageDate: Self.dateFromCoreData(nanoseconds: firstNano),
                lastMessageDate: Self.dateFromCoreData(nanoseconds: lastNano),
                lastMessageIsFromMe: false
            ))
        }
        return byMonth
    }

    /// Whole-history aggregates (all messages, including group chats) for the
    /// day/time KPIs. Computed in SQL so we never load individual messages.
    func fetchGlobalStats() throws -> GlobalStats {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw MessageStoreError.openFailed(msg)
        }
        defer { sqlite3_close(db) }

        var stats = GlobalStats()
        let localTime = "datetime(m.date / 1000000000 + 978307200, 'unixepoch', 'localtime')"

        // Sent-message hour distribution → night-owl share.
        let hourSQL = "SELECT CAST(strftime('%H', \(localTime)) AS INTEGER) AS hr, COUNT(*) FROM message m WHERE m.is_from_me = 1 GROUP BY hr"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, hourSQL, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let hr = Int(sqlite3_column_int(stmt, 0))
                if (0..<24).contains(hr) {
                    stats.sentHourCounts[hr] = Int(sqlite3_column_int(stmt, 1))
                }
            }
        }
        sqlite3_finalize(stmt)

        return stats
    }

    /// The 1:1 chat rowids belonging to a person's handles. Group chats excluded,
    /// consistent with every other count in the app.
    func fetchChatIDs(handleIDs: [Int64]) throws -> [Int64] {
        guard !handleIDs.isEmpty else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw MessageStoreError.openFailed(msg)
        }
        defer { sqlite3_close(db) }

        let placeholders = handleIDs.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT DISTINCT c.rowid
            FROM chat c
            INNER JOIN chat_handle_join chj ON chj.chat_id = c.rowid
            WHERE c.chat_identifier NOT LIKE 'chat%'
              AND chj.handle_id IN (\(placeholders))
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(db!)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, id) in handleIDs.enumerated() {
            sqlite3_bind_int64(stmt, Int32(i + 1), id)
        }

        var chatIDs: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            chatIDs.append(sqlite3_column_int64(stmt, 0))
        }
        return chatIDs
    }

    /// One keyset page of messages in a set of chats, in one direction.
    /// Pass `after` to page forward (ascending), `before` to page backward
    /// (returned ascending). To jump to a date, page forward from
    /// `(nanoseconds(date) - 1, Int64.max)`.
    func fetchMessages(
        chatIDs: [Int64],
        after: (date: Int64, id: Int64)? = nil,
        before: (date: Int64, id: Int64)? = nil,
        limit: Int
    ) throws -> [ChatMessage] {
        guard !chatIDs.isEmpty else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw MessageStoreError.openFailed(msg)
        }
        defer { sqlite3_close(db) }

        let placeholders = chatIDs.map { _ in "?" }.joined(separator: ", ")
        let descending = before != nil
        let cursor = after ?? before
        let comparison = descending ? "<" : ">"
        let order = descending ? "DESC" : "ASC"

        var sql = """
            SELECT m.rowid, cmj.message_date, m.is_from_me, m.text, m.attributedBody, m.cache_has_attachments
            FROM chat_message_join cmj
            INNER JOIN message m ON m.rowid = cmj.message_id
            WHERE cmj.chat_id IN (\(placeholders))
              AND m.item_type = 0
              AND m.associated_message_type = 0
            """
        if cursor != nil {
            sql += """

              AND (cmj.message_date \(comparison) ? OR (cmj.message_date = ? AND cmj.message_id \(comparison) ?))
            """
        }
        sql += "\nORDER BY cmj.message_date \(order), cmj.message_id \(order)\nLIMIT ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(db!)))
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        for id in chatIDs { sqlite3_bind_int64(stmt, idx, id); idx += 1 }
        if let cursor {
            sqlite3_bind_int64(stmt, idx, cursor.date); idx += 1
            sqlite3_bind_int64(stmt, idx, cursor.date); idx += 1
            sqlite3_bind_int64(stmt, idx, cursor.id); idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(limit))

        var messages: [ChatMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            let dateNano = sqlite3_column_int64(stmt, 1)
            let fromMe = sqlite3_column_int(stmt, 2) == 1
            let text = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            var blob: Data?
            if let bytes = sqlite3_column_blob(stmt, 4) {
                blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 4)))
            }
            let hasAttachment = sqlite3_column_int(stmt, 5) == 1

            messages.append(ChatMessage(
                id: rowid,
                dateNano: dateNano,
                date: Self.dateFromCoreData(nanoseconds: dateNano),
                isFromMe: fromMe,
                text: Self.decodeBody(text: text, blob: blob, hasAttachment: hasAttachment)
            ))
        }
        return descending ? messages.reversed() : messages
    }

    /// Message bodies live in the `text` column on old messages and in the
    /// `attributedBody` typedstream blob on newer ones (~99.9% of this DB).
    /// `NSUnarchiver` is deprecated but is the only thing that decodes the classic
    /// typedstream format; isolated here so it can be swapped for a hand parser.
    private static func decodeBody(text: String?, blob: Data?, hasAttachment: Bool) -> String {
        var s = text ?? ""
        if s.isEmpty, let blob,
           let attr = try? NSUnarchiver.unarchiveObject(with: blob) as? NSAttributedString {
            s = attr.string
        }
        s = s.replacingOccurrences(of: "\u{FFFC}", with: "")   // attachment placeholder glyphs
             .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return hasAttachment ? "[attachment]" : "[unsupported]" }
        return s
    }

    /// Busiest day / month / year for a set of chats. Counts every row (matching
    /// the totals shown elsewhere); rolled up from per-day counts in Swift, which
    /// is cheap since a decade of messages is at most a few thousand days.
    func fetchRelationshipPeaks(chatIDs: [Int64]) throws -> RelationshipPeaks {
        guard !chatIDs.isEmpty else { return RelationshipPeaks() }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw MessageStoreError.openFailed(msg)
        }
        defer { sqlite3_close(db) }

        let placeholders = chatIDs.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT strftime('%Y-%m-%d', datetime(cmj.message_date / 1000000000 + 978307200, 'unixepoch', 'localtime')) AS day,
                   COUNT(*)
            FROM chat_message_join cmj
            WHERE cmj.chat_id IN (\(placeholders))
            GROUP BY day
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(db!)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, id) in chatIDs.enumerated() {
            sqlite3_bind_int64(stmt, Int32(i + 1), id)
        }

        var dayCounts: [(day: String, count: Int)] = []
        var byMonth: [String: Int] = [:]
        var byYear: [Int: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let dayC = sqlite3_column_text(stmt, 0) else { continue }
            let day = String(cString: dayC)
            let count = Int(sqlite3_column_int(stmt, 1))
            dayCounts.append((day, count))
            byMonth[String(day.prefix(7)), default: 0] += count
            if let year = Int(day.prefix(4)) { byYear[year, default: 0] += count }
        }

        var peaks = RelationshipPeaks()
        if let top = dayCounts.max(by: { $0.count < $1.count }),
           let date = Self.dayFormatter.date(from: top.day) {
            peaks.busiestDay = (date, top.count)
        }
        if let top = byMonth.max(by: { $0.value < $1.value }),
           let date = Self.monthFormatter.date(from: top.key) {
            peaks.busiestMonth = (date, top.value)
        }
        if let top = byYear.max(by: { $0.value < $1.value }) {
            peaks.busiestYear = (top.key, top.value)
        }
        return peaks
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f
    }()

    /// Nanoseconds since 2001-01-01 for a Date — the inverse of `dateFromCoreData`.
    static func nanoseconds(from date: Date) -> Int64 {
        Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    private static func dateFromCoreData(nanoseconds: Int64) -> Date {
        let seconds = Double(nanoseconds) / 1_000_000_000
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Reads a nullable TEXT column, mapping NULL or empty string to nil.
    private static func personID(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        let value = String(cString: cString)
        return value.isEmpty ? nil : value
    }
}

struct GlobalStats {
    var sentHourCounts = Array(repeating: 0, count: 24)
}

enum MessageStoreError: LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): "Failed to open chat.db: \(msg)"
        case .queryFailed(let msg): "Query failed: \(msg)"
        }
    }
}
