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

    private static func dateFromCoreData(nanoseconds: Int64) -> Date {
        let seconds = Double(nanoseconds) / 1_000_000_000
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
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
