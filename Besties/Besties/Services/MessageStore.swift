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
                COALESCE(lm.is_from_me, 0)
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

            let firstDate = Self.dateFromCoreData(nanoseconds: firstNano)
            let lastDate = Self.dateFromCoreData(nanoseconds: lastNano)

            conversations.append(Conversation(
                id: handleId,
                handle: handle,
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

    private static func dateFromCoreData(nanoseconds: Int64) -> Date {
        let seconds = Double(nanoseconds) / 1_000_000_000
        return Date(timeIntervalSinceReferenceDate: seconds)
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
