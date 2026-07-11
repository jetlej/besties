import Foundation
import SQLite3

/// Reads the WhatsApp desktop app's local message store — a plain Core Data
/// SQLite file in its group container (covered by the Full Disk Access we
/// already require for chat.db). Every fetch returns empty data when WhatsApp
/// isn't installed, so callers never need to special-case its absence.
///
/// Format notes: 1:1 chats have JIDs like "13237459802@s.whatsapp.net" (the
/// number, no "+"), groups are "@g.us". ZMESSAGEDATE is *seconds* since 2001
/// (vs chat.db's nanoseconds). ZMESSAGETYPE 10 is system notices (security
/// code changes etc.) with no text; everything else counts as a message.
final class WhatsAppStore {
    private let dbPath: String = {
        NSHomeDirectory() + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
    }()

    /// Restricts joins to 1:1 chats and real messages, and drops the odd row
    /// with a zeroed date. Matches the app-wide rule of excluding group chats.
    private static let oneToOneFilter = """
        cs.ZCONTACTJID LIKE '%@s.whatsapp.net'
          AND m.ZMESSAGETYPE != 10
          AND m.ZMESSAGEDATE > 0
        """

    /// ZMESSAGEDATE in nanoseconds since 2001, matching chat.db cursors.
    /// CAST truncates toward zero exactly like Swift's Int64(Double), so
    /// cursor equality comparisons round-trip.
    private static let nanoExpr = "CAST(m.ZMESSAGEDATE * 1000000000.0 AS INTEGER)"

    /// Whether the WhatsApp desktop app has a message store on this Mac.
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: dbPath)
    }

    private func open() throws -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw MessageStoreError.openFailed(msg)
        }
        return db
    }

    /// "13237459802@s.whatsapp.net" → "+13237459802", the same E.164 shape
    /// iMessage handles use, so contact resolution and cross-source merging
    /// work on identical strings.
    private static func normalizedHandle(jid: String) -> String {
        guard let at = jid.firstIndex(of: "@") else { return jid }
        return "+" + jid[..<at]
    }

    func fetchConversations() throws -> [Conversation] {
        guard let db = try open() else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT
                cs.Z_PK,
                cs.ZCONTACTJID,
                cs.ZPARTNERNAME,
                COUNT(*),
                SUM(m.ZISFROMME),
                MIN(\(Self.nanoExpr)),
                MAX(\(Self.nanoExpr)),
                (SELECT m2.ZISFROMME FROM ZWAMESSAGE m2
                 WHERE m2.ZCHATSESSION = cs.Z_PK
                   AND m2.ZMESSAGETYPE != 10 AND m2.ZMESSAGEDATE > 0
                 ORDER BY m2.ZMESSAGEDATE DESC, m2.Z_PK DESC LIMIT 1)
            FROM ZWACHATSESSION cs
            INNER JOIN ZWAMESSAGE m ON m.ZCHATSESSION = cs.Z_PK
            WHERE \(Self.oneToOneFilter)
            GROUP BY cs.Z_PK
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var conversations: [Conversation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sessionID = sqlite3_column_int64(stmt, 0)
            let jid = String(cString: sqlite3_column_text(stmt, 1))
            let partnerName = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let total = Int(sqlite3_column_int(stmt, 3))
            let sent = Int(sqlite3_column_int(stmt, 4))
            let firstNano = sqlite3_column_int64(stmt, 5)
            let lastNano = sqlite3_column_int64(stmt, 6)
            let lastFromMe = sqlite3_column_int(stmt, 7) == 1

            var convo = Conversation(
                rowID: sessionID,
                source: .whatsApp,
                handle: Self.normalizedHandle(jid: jid),
                totalMessages: total,
                sentMessages: sent,
                receivedMessages: total - sent,
                firstMessageDate: Self.dateFromNano(firstNano),
                lastMessageDate: Self.dateFromNano(lastNano),
                lastMessageIsFromMe: lastFromMe
            )
            // WhatsApp's own display name (synced from the phone's contacts)
            // is a fallback; AppState overrides it with the Mac contact card
            // name when the number resolves, keeping merge keys consistent.
            if let partnerName, !partnerName.isEmpty {
                convo.displayName = partnerName
            }
            conversations.append(convo)
        }
        return conversations
    }

    /// Per-conversation message stats grouped by calendar month, keyed "yyyy-MM".
    func fetchConversationsByMonth() throws -> [String: [Conversation]] {
        guard let db = try open() else { return [:] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT
                cs.Z_PK,
                cs.ZCONTACTJID,
                strftime('%Y-%m', datetime(m.ZMESSAGEDATE + 978307200, 'unixepoch', 'localtime')) AS month,
                COUNT(*),
                SUM(m.ZISFROMME),
                MIN(\(Self.nanoExpr)),
                MAX(\(Self.nanoExpr))
            FROM ZWACHATSESSION cs
            INNER JOIN ZWAMESSAGE m ON m.ZCHATSESSION = cs.Z_PK
            WHERE \(Self.oneToOneFilter)
            GROUP BY cs.Z_PK, month
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var byMonth: [String: [Conversation]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sessionID = sqlite3_column_int64(stmt, 0)
            let jid = String(cString: sqlite3_column_text(stmt, 1))
            let month = String(cString: sqlite3_column_text(stmt, 2))
            let total = Int(sqlite3_column_int(stmt, 3))
            let sent = Int(sqlite3_column_int(stmt, 4))
            let firstNano = sqlite3_column_int64(stmt, 5)
            let lastNano = sqlite3_column_int64(stmt, 6)

            byMonth[month, default: []].append(Conversation(
                rowID: sessionID,
                source: .whatsApp,
                handle: Self.normalizedHandle(jid: jid),
                totalMessages: total,
                sentMessages: sent,
                receivedMessages: total - sent,
                firstMessageDate: Self.dateFromNano(firstNano),
                lastMessageDate: Self.dateFromNano(lastNano),
                lastMessageIsFromMe: false
            ))
        }
        return byMonth
    }

    /// Sent-message hour distribution across all chats (groups included),
    /// mirroring MessageStore.fetchGlobalStats.
    func fetchSentHourCounts() throws -> [Int] {
        var counts = Array(repeating: 0, count: 24)
        guard let db = try open() else { return counts }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT CAST(strftime('%H', datetime(m.ZMESSAGEDATE + 978307200, 'unixepoch', 'localtime')) AS INTEGER) AS hr,
                   COUNT(*)
            FROM ZWAMESSAGE m
            WHERE m.ZISFROMME = 1 AND m.ZMESSAGETYPE != 10 AND m.ZMESSAGEDATE > 0
            GROUP BY hr
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let hr = Int(sqlite3_column_int(stmt, 0))
            if (0..<24).contains(hr) {
                counts[hr] = Int(sqlite3_column_int(stmt, 1))
            }
        }
        return counts
    }

    /// One keyset page of messages in a set of chat sessions, in one direction.
    /// Same cursor semantics as MessageStore.fetchMessages; cursor dates are
    /// nanoseconds since 2001.
    func fetchMessages(
        chatIDs: [Int64],
        after: (date: Int64, id: Int64)? = nil,
        before: (date: Int64, id: Int64)? = nil,
        limit: Int
    ) throws -> [ChatMessage] {
        guard !chatIDs.isEmpty, let db = try open() else { return [] }
        defer { sqlite3_close(db) }

        let placeholders = chatIDs.map { _ in "?" }.joined(separator: ", ")
        let descending = before != nil
        let cursor = after ?? before
        let comparison = descending ? "<" : ">"
        let order = descending ? "DESC" : "ASC"

        var sql = """
            SELECT m.Z_PK, \(Self.nanoExpr), m.ZISFROMME, m.ZTEXT, m.ZMEDIAITEM IS NOT NULL
            FROM ZWAMESSAGE m
            WHERE m.ZCHATSESSION IN (\(placeholders))
              AND m.ZMESSAGETYPE != 10
              AND m.ZMESSAGEDATE > 0
            """
        if cursor != nil {
            sql += """

              AND (\(Self.nanoExpr) \(comparison) ? OR (\(Self.nanoExpr) = ? AND m.Z_PK \(comparison) ?))
            """
        }
        sql += "\nORDER BY m.ZMESSAGEDATE \(order), m.Z_PK \(order)\nLIMIT ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
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
            let rowID = sqlite3_column_int64(stmt, 0)
            let dateNano = sqlite3_column_int64(stmt, 1)
            let fromMe = sqlite3_column_int(stmt, 2) == 1
            let text = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let hasMedia = sqlite3_column_int(stmt, 4) == 1

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(ChatMessage(
                rowID: rowID,
                source: .whatsApp,
                dateNano: dateNano,
                date: Self.dateFromNano(dateNano),
                isFromMe: fromMe,
                text: trimmed.isEmpty ? (hasMedia ? "[attachment]" : "[unsupported]") : trimmed
            ))
        }
        return descending ? messages.reversed() : messages
    }

    /// Per-day message counts ("yyyy-MM-dd") for a set of chat sessions, for
    /// merging with chat.db day counts before computing relationship peaks.
    func fetchDayCounts(chatIDs: [Int64]) throws -> [String: Int] {
        guard !chatIDs.isEmpty, let db = try open() else { return [:] }
        defer { sqlite3_close(db) }

        let placeholders = chatIDs.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT strftime('%Y-%m-%d', datetime(m.ZMESSAGEDATE + 978307200, 'unixepoch', 'localtime')) AS day,
                   COUNT(*)
            FROM ZWAMESSAGE m
            WHERE m.ZCHATSESSION IN (\(placeholders))
              AND m.ZMESSAGETYPE != 10
              AND m.ZMESSAGEDATE > 0
            GROUP BY day
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, id) in chatIDs.enumerated() {
            sqlite3_bind_int64(stmt, Int32(i + 1), id)
        }

        var dayCounts: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let dayC = sqlite3_column_text(stmt, 0) else { continue }
            dayCounts[String(cString: dayC)] = Int(sqlite3_column_int(stmt, 1))
        }
        return dayCounts
    }

    private static func dateFromNano(_ nanoseconds: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(nanoseconds) / 1_000_000_000)
    }
}
