import Foundation
import SQLite3

/// The local tools the model is allowed to call. Every tool wraps a query path
/// the app already uses, hands back a compact JSON string, and never throws —
/// failures come back as `{"error": …}` so the model can react to them instead
/// of the turn dying. Nothing here sends message content anywhere; the client
/// decides what to put in a request.
@MainActor
final class AIToolbox {
    /// Message bodies and SQL text values are cut at this many characters.
    private static let textLimit = 500
    /// read_transcript never returns more than this, whatever the model asks for.
    private static let transcriptCap = 120

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Definitions

    var toolDefinitions: [[String: Any]] {
        [
            [
                "name": "list_people",
                "description": "The people in the message history, merged across iMessage, SMS and WhatsApp. Use this to find who someone is before calling another tool — the merge_key it returns is the unambiguous way to name a person.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "filter": ["type": "string", "description": "Case-insensitive substring of a name or handle."],
                        "sort": ["type": "string", "enum": ["messages", "recent"], "description": "messages = most messages first (default), recent = most recently messaged first."],
                        "limit": ["type": "integer", "description": "Default 25, max 200."],
                    ],
                ],
            ],
            [
                "name": "person_summary",
                "description": "Totals, first/last contact, busiest day/month/year and a per-month message count for one person's whole relationship.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "person": ["type": "string", "description": "A name, phone number, handle, or a merge_key from list_people."],
                    ],
                    "required": ["person"],
                ],
            ],
            [
                "name": "search_messages",
                "description": "Full-text search over every indexed message. Exact word matching (the last word matches as a prefix), so search for words that were actually typed.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Words to match."],
                        "person": ["type": "string", "description": "Restrict to one person's chats."],
                        "sender": ["type": "string", "enum": ["any", "me", "them"], "description": "Who sent it. Default any."],
                        "after": ["type": "string", "description": "Only messages on or after this date (YYYY-MM-DD, YYYY-MM or YYYY)."],
                        "before": ["type": "string", "description": "Only messages before this date."],
                        "limit": ["type": "integer", "description": "Default 20, max 100."],
                    ],
                    "required": ["query"],
                ],
            ],
            [
                "name": "read_transcript",
                "description": "A window of consecutive messages with one person, oldest first — what was actually said around a moment. Use it after search_messages to read the context around a hit.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "person": ["type": "string", "description": "A name, phone number, handle, or a merge_key from list_people."],
                        "center_date": ["type": "string", "description": "Centre the window on this date (YYYY-MM-DD or an ISO-8601 timestamp)."],
                        "after": ["type": "string", "description": "Start of the window; messages read forward from here."],
                        "before": ["type": "string", "description": "End of the window; messages read backward from here. Omit all three for the most recent messages."],
                        "limit": ["type": "integer", "description": "Default 40, max 120."],
                    ],
                    "required": ["person"],
                ],
            ],
            [
                "name": "run_sql",
                "description": "Read-only SQL against the raw databases, for counts and aggregates the other tools don't cover. Never guess a number — compute it here. One statement, must start with SELECT or WITH, times out after 5 seconds.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "db": ["type": "string", "enum": ["chatdb", "searchdb"], "description": "chatdb = the iMessage database, searchdb = the app's message-text index."],
                        "query": ["type": "string", "description": "A single SELECT or WITH statement."],
                        "row_limit": ["type": "integer", "description": "Default 200, max 500."],
                    ],
                    "required": ["db", "query"],
                ],
            ],
        ]
    }

    // MARK: - Dispatch

    func execute(name: String, input: [String: Any]) async -> String {
        switch name {
        case "list_people": return listPeople(input)
        case "person_summary": return await personSummary(input)
        case "search_messages": return await searchMessages(input)
        case "read_transcript": return await readTranscript(input)
        case "run_sql": return await runSQL(input)
        default: return ToolJSON.error("unknown tool \"\(name)\"")
        }
    }

    // MARK: - list_people

    private func listPeople(_ input: [String: Any]) -> String {
        var matches = people()
        if let filter = ToolJSON.string(input["filter"])?.lowercased(), !filter.isEmpty {
            matches = matches.filter { person in
                person.name.lowercased().contains(filter)
                    || person.conversations.contains { $0.handle.lowercased().contains(filter) }
            }
        }
        if ToolJSON.string(input["sort"])?.lowercased() == "recent" {
            matches.sort { $0.lastDate > $1.lastDate }
        } else {
            matches.sort { $0.totalMessages > $1.totalMessages }
        }
        let limit = min(max(ToolJSON.int(input["limit"]) ?? 25, 1), 200)
        return ToolJSON.encode([
            "total_people": matches.count,
            "people": matches.prefix(limit).map(Self.row(for:)),
        ])
    }

    // MARK: - person_summary

    private func personSummary(_ input: [String: Any]) async -> String {
        let person: Person
        switch lookupPerson(input) {
        case .reply(let json): return json
        case .person(let match): person = match
        }

        let imChats = await oneToOneChatIDs(for: person)
        let waIDs = person.whatsAppChatIDs
        let dayCounts = await Task.detached { () -> [String: Int] in
            var counts = (try? MessageStore().fetchDayCounts(chatIDs: imChats)) ?? [:]
            for (day, count) in (try? WhatsAppStore().fetchDayCounts(chatIDs: waIDs)) ?? [:] {
                counts[day, default: 0] += count
            }
            return counts
        }.value

        var monthly: [String: Int] = [:]
        for (day, count) in dayCounts { monthly[String(day.prefix(7)), default: 0] += count }
        let peaks = RelationshipPeaks(dayCounts: dayCounts)

        var result = Self.row(for: person)
        result["handles"] = Set(person.conversations.map { Self.displayHandle($0.handle) }).sorted()
        result["monthly_counts"] = monthly
        if let day = peaks.busiestDay {
            result["busiest_day"] = ["date": ToolJSON.day(day.date), "messages": day.count]
        }
        if let month = peaks.busiestMonth {
            result["busiest_month"] = ["month": String(ToolJSON.day(month.date).prefix(7)), "messages": month.count]
        }
        if let year = peaks.busiestYear {
            result["busiest_year"] = ["year": year.year, "messages": year.count]
        }
        return ToolJSON.encode(result)
    }

    // MARK: - search_messages

    private func searchMessages(_ input: [String: Any]) async -> String {
        guard let query = ToolJSON.string(input["query"]), !query.isEmpty else {
            return ToolJSON.error("query is required")
        }

        var options = SearchIndex.Options()
        if ToolJSON.string(input["person"]) != nil {
            let person: Person
            switch lookupPerson(input) {
            case .reply(let json): return json
            case .person(let match): person = match
            }
            let imChats = await oneToOneChatIDs(for: person)
            options.chats = imChats.map { SearchIndex.ChatRef(source: .iMessage, id: $0) }
                + person.whatsAppChatIDs.map { SearchIndex.ChatRef(source: .whatsApp, id: $0) }
        }
        switch ToolJSON.string(input["sender"])?.lowercased() {
        case "me": options.fromMe = true
        case "them": options.fromMe = false
        default: break
        }
        var dateError: String?
        options.startDate = ToolJSON.date(input, "after", error: &dateError)
        options.endDate = ToolJSON.date(input, "before", error: &dateError)
        if let dateError { return ToolJSON.error(dateError) }
        // Same rule as the Search tab: with WhatsApp off, its messages are out.
        if !appState.whatsAppEnabled { options.source = .iMessage }
        options.limit = min(max(ToolJSON.int(input["limit"]) ?? 20, 1), 100)

        let index = appState.searchIndex
        let search = await Task.detached { try? index.search(query, options: options) }.value
        guard let response = search else {
            return ToolJSON.error("search failed — the message index may still be building")
        }

        let chatInfo = appState.chatInfoByID
        let imConvos = appState.iMessageConvoByHandleID
        let waConvos = appState.whatsAppConvoBySessionID
        let results = response.results.map { hit -> [String: Any] in
            var row: [String: Any] = [
                "id": hit.id,
                "date": ToolJSON.timestamp(hit.date),
                "sender": hit.isFromMe ? "me" : "them",
                "source": hit.source == .whatsApp ? "whatsapp" : "imessage",
                "snippet": ToolJSON.truncate(Self.plainSnippet(hit.snippet), Self.textLimit),
            ]
            if hit.source == .whatsApp {
                if let convo = waConvos[hit.chatID] { row["person"] = convo.resolvedName }
            } else if let info = chatInfo[hit.chatID] {
                if info.isGroup {
                    row["person"] = info.displayName ?? "Group chat"
                    row["group"] = true
                } else if let handleID = info.handleID, let convo = imConvos[handleID] {
                    row["person"] = convo.resolvedName
                }
            }
            return row
        }
        return ToolJSON.encode([
            "query": query,
            "total_matches": response.total,
            "returned": results.count,
            "results": results,
        ])
    }

    // MARK: - read_transcript

    private func readTranscript(_ input: [String: Any]) async -> String {
        let person: Person
        switch lookupPerson(input) {
        case .reply(let json): return json
        case .person(let match): person = match
        }

        let limit = min(max(ToolJSON.int(input["limit"]) ?? 40, 1), Self.transcriptCap)
        let imChats = await oneToOneChatIDs(for: person)
        let waIDs = person.whatsAppChatIDs
        var dateError: String?
        let center = ToolJSON.date(input, "center_date", error: &dateError)
        let after = ToolJSON.date(input, "after", error: &dateError)
        let before = ToolJSON.date(input, "before", error: &dateError)
        if let dateError { return ToolJSON.error(dateError) }

        let messages = await Task.detached { () -> [ChatMessage] in
            // (date, Int64.min) splits the timeline cleanly: backward is strictly
            // older than the date, forward starts at it.
            if let center {
                let anchor = (date: MessageStore.nanoseconds(from: center), id: Int64.min)
                let older = fetchMerged(im: imChats, wa: waIDs, cursor: anchor, older: true, limit: max(limit / 2, 1))
                let newer = fetchMerged(im: imChats, wa: waIDs, cursor: anchor, older: false, limit: limit - older.count)
                return older + newer
            }
            if let after {
                let cursor = (date: MessageStore.nanoseconds(from: after), id: Int64.min)
                return fetchMerged(im: imChats, wa: waIDs, cursor: cursor, older: false, limit: limit)
            }
            let end = before.map { MessageStore.nanoseconds(from: $0) } ?? Int64.max
            return fetchMerged(im: imChats, wa: waIDs, cursor: (date: end, id: Int64.min), older: true, limit: limit)
        }.value

        return ToolJSON.encode([
            "person": person.name,
            "merge_key": person.key,
            "count": messages.count,
            "messages": messages.map { [
                "date": ToolJSON.timestamp($0.date),
                "from_me": $0.isFromMe,
                "text": ToolJSON.truncate($0.text, Self.textLimit),
            ] },
        ])
    }

    // MARK: - run_sql

    private func runSQL(_ input: [String: Any]) async -> String {
        guard let query = ToolJSON.string(input["query"]), !query.isEmpty else {
            return ToolJSON.error("query is required")
        }
        let path: String
        switch ToolJSON.string(input["db"])?.lowercased() {
        case "chatdb": path = NSHomeDirectory() + "/Library/Messages/chat.db"
        case "searchdb": path = appState.searchIndex.indexPath
        case let other: return ToolJSON.error("db must be \"chatdb\" or \"searchdb\", got \"\(other ?? "")\"")
        }
        let rowLimit = min(max(ToolJSON.int(input["row_limit"]) ?? 200, 1), 500)
        let textLimit = Self.textLimit
        return await Task.detached {
            ToolJSON.encode(SQLRunner.run(path: path, query: query, rowLimit: rowLimit, textLimit: textLimit))
        }.value
    }

    // MARK: - People

    /// One person: the conversations that share a `mergeKey`, totalled the way
    /// the app's merged rows are.
    private struct Person {
        let key: String
        let name: String
        let conversations: [Conversation]

        var totalMessages: Int { conversations.reduce(0) { $0 + $1.totalMessages } }
        var sentMessages: Int { conversations.reduce(0) { $0 + $1.sentMessages } }
        var receivedMessages: Int { conversations.reduce(0) { $0 + $1.receivedMessages } }
        var firstDate: Date { conversations.map(\.firstMessageDate).min() ?? .distantPast }
        var lastDate: Date { conversations.map(\.lastMessageDate).max() ?? .distantPast }
        var daysSinceLastMessage: Int {
            Calendar.current.dateComponents([.day], from: lastDate, to: .now).day ?? 0
        }
        var imessageHandleIDs: [Int64] { conversations.filter { $0.source == .iMessage }.map(\.rowID) }
        var whatsAppChatIDs: [Int64] { conversations.filter { $0.source == .whatsApp }.map(\.rowID) }
        var sources: [String] {
            var out: [String] = []
            if conversations.contains(where: { $0.source == .iMessage }) { out.append("imessage") }
            if conversations.contains(where: { $0.source == .whatsApp }) { out.append("whatsapp") }
            return out
        }
    }

    /// Everyone in the loaded history, one entry per person.
    private func people() -> [Person] {
        var groups: [String: [Conversation]] = [:]
        for convo in appState.resolvedConversations { groups[convo.mergeKey, default: []].append(convo) }
        return groups.compactMap { key, group in
            guard let busiest = group.max(by: { $0.totalMessages < $1.totalMessages }) else { return nil }
            return Person(key: key, name: busiest.resolvedName, conversations: group)
        }
    }

    /// A person's 1:1 iMessage chat rowids. Group chats are excluded app-wide,
    /// so nothing a person said in a group counts as a message with them —
    /// which also keeps these results matching the totals shown in the app.
    private func oneToOneChatIDs(for person: Person) async -> [Int64] {
        let handleIDs = person.imessageHandleIDs
        let chatIDs = await Task.detached {
            (try? MessageStore().fetchChatIDs(handleIDs: handleIDs)) ?? []
        }.value
        let infos = appState.chatInfoByID
        guard !infos.isEmpty else { return chatIDs }   // not loaded yet; better broad than empty
        return chatIDs.filter { infos[$0]?.isGroup != true }
    }

    private static func row(for person: Person) -> [String: Any] {
        [
            "name": person.name,
            "merge_key": person.key,
            "sources": person.sources,
            "messages": person.totalMessages,
            "sent": person.sentMessages,
            "received": person.receivedMessages,
            "first_message": ToolJSON.timestamp(person.firstDate),
            "last_message": ToolJSON.timestamp(person.lastDate),
            "days_since_last_message": person.daysSinceLastMessage,
        ]
    }

    /// Screenshot mode never lets a raw phone number or email reach a result,
    /// matching `Conversation.resolvedName`.
    private static func displayHandle(_ handle: String) -> String {
        ContactResolver.isScreenshotMode
            ? ContactResolver.screenshotPlaceholder(forHandle: handle)
            : handle
    }

    private enum PersonLookup {
        case person(Person)
        /// A finished tool result — an error or the candidate list to clarify with.
        case reply(String)
    }

    private func lookupPerson(_ input: [String: Any]) -> PersonLookup {
        guard let argument = ToolJSON.string(input["person"]), !argument.isEmpty else {
            return .reply(ToolJSON.error("person is required"))
        }
        let candidates = people()
        let lowered = argument.lowercased()

        if let exact = candidates.first(where: { $0.key == argument }) { return .person(exact) }

        var matches = candidates.filter { $0.name.lowercased() == lowered }
        if matches.isEmpty {
            let digits = argument.filter(\.isNumber)
            if digits.count >= 7 {
                let suffix = String(digits.suffix(10))
                matches = candidates.filter { person in
                    person.conversations.contains { convo in
                        let handleDigits = convo.handle.filter(\.isNumber)
                        return handleDigits.count >= 7 && String(handleDigits.suffix(10)) == suffix
                    }
                }
            }
        }
        if matches.isEmpty {
            matches = candidates.filter { $0.conversations.contains { $0.handle.lowercased() == lowered } }
        }
        if matches.isEmpty {
            matches = candidates.filter { $0.name.lowercased().contains(lowered) }
        }

        if matches.count == 1 { return .person(matches[0]) }
        if matches.isEmpty {
            return .reply(ToolJSON.error("no person matching \"\(argument)\" — call list_people to see who is there"))
        }
        return .reply(ToolJSON.encode([
            "ambiguous": true,
            "note": "several people match \"\(argument)\" — ask which one is meant, then call again with their merge_key",
            "candidates": matches.sorted { $0.totalMessages > $1.totalMessages }.prefix(20).map(Self.row(for:)),
        ]))
    }

    /// Search snippets mark matched terms with private-use characters for the
    /// UI's highlighting; the model gets plain text.
    private static func plainSnippet(_ snippet: String) -> String {
        snippet
            .replacingOccurrences(of: SearchIndex.markStart, with: "")
            .replacingOccurrences(of: SearchIndex.markEnd, with: "")
    }
}

/// One merged page across both stores, ascending — the same keyset paging the
/// conversation reader does, without its window bookkeeping.
private func fetchMerged(
    im: [Int64], wa: [Int64],
    cursor: (date: Int64, id: Int64),
    older: Bool, limit: Int
) -> [ChatMessage] {
    let imPage = older
        ? ((try? MessageStore().fetchMessages(chatIDs: im, before: cursor, limit: limit)) ?? [])
        : ((try? MessageStore().fetchMessages(chatIDs: im, after: cursor, limit: limit)) ?? [])
    let waPage = older
        ? ((try? WhatsAppStore().fetchMessages(chatIDs: wa, before: cursor, limit: limit)) ?? [])
        : ((try? WhatsAppStore().fetchMessages(chatIDs: wa, after: cursor, limit: limit)) ?? [])

    var merged = (imPage + waPage).sorted {
        ($0.dateNano, $0.source.rawValue, $0.rowID) < ($1.dateNano, $1.source.rawValue, $1.rowID)
    }
    if merged.count > limit {
        merged = older ? Array(merged.suffix(limit)) : Array(merged.prefix(limit))
    }
    return merged
}

/// Read-only SQL for `run_sql`. The database is opened `SQLITE_OPEN_READONLY`,
/// only one SELECT/WITH statement is allowed through, and a watchdog interrupts
/// anything still running after five seconds.
private enum SQLRunner {
    static let timeout: TimeInterval = 5

    static func run(path: String, query: String, rowLimit: Int, textLimit: Int) -> [String: Any] {
        var statement = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if statement.hasSuffix(";") { statement.removeLast() }
        statement = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hasStatementBreak(statement) else {
            return ["error": "only one statement per call"]
        }
        let head = statement.prefix(6).uppercased()
        guard head.hasPrefix("SELECT") || head.hasPrefix("WITH") else {
            return ["error": "query must start with SELECT or WITH"]
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            return ["error": "could not open database: \(message)"]
        }
        sqlite3_busy_timeout(db, 3000)

        let connection = Connection(db: db)
        let watchdog = DispatchWorkItem { connection.interrupt() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel(); connection.close() }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, statement, -1, &stmt, nil) == SQLITE_OK else {
            return ["error": "SQL error: \(String(cString: sqlite3_errmsg(db)))"]
        }
        defer { sqlite3_finalize(stmt) }

        let columnCount = Int(sqlite3_column_count(stmt))
        let columns = (0..<columnCount).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }

        var rows: [[Any]] = []
        var truncated = false
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            if step == SQLITE_INTERRUPT {
                return ["error": "query took longer than \(Int(timeout))s and was cancelled — narrow it down"]
            }
            guard step == SQLITE_ROW else {
                return ["error": "SQL error: \(String(cString: sqlite3_errmsg(db)))"]
            }
            if rows.count == rowLimit { truncated = true; break }
            rows.append((0..<columnCount).map { value(stmt, Int32($0), textLimit: textLimit) })
        }

        return [
            "columns": columns,
            "rows": rows,
            "row_count": rows.count,
            "truncated": truncated,
        ]
    }

    /// True when a `;` sits outside a single-quoted string literal — a real
    /// second statement, rather than a semicolon the query is searching for.
    /// Toggling on every quote handles the `''` escape, since the pair opens
    /// the literal again straight after closing it.
    private static func hasStatementBreak(_ sql: String) -> Bool {
        var inLiteral = false
        for character in sql {
            if character == "'" {
                inLiteral.toggle()
            } else if character == ";" && !inLiteral {
                return true
            }
        }
        return false
    }

    private static func value(_ stmt: OpaquePointer?, _ index: Int32, textLimit: Int) -> Any {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_NULL: return NSNull()
        case SQLITE_INTEGER: return Int(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT: return sqlite3_column_double(stmt, index)
        case SQLITE_BLOB: return "[blob \(sqlite3_column_bytes(stmt, index)) bytes]"
        default:
            guard let text = sqlite3_column_text(stmt, index) else { return NSNull() }
            return ToolJSON.truncate(String(cString: text), textLimit)
        }
    }

    /// Holds the connection so the watchdog can interrupt it without ever
    /// touching a handle the query path has already closed.
    private final class Connection: @unchecked Sendable {
        private let lock = NSLock()
        private var db: OpaquePointer?

        init(db: OpaquePointer) { self.db = db }

        func interrupt() {
            lock.lock()
            defer { lock.unlock() }
            if let db { sqlite3_interrupt(db) }
        }

        func close() {
            lock.lock()
            defer { lock.unlock() }
            if let db { sqlite3_close(db) }
            db = nil
        }
    }
}

/// Compact JSON encoding, the date shapes every tool result uses, and lenient
/// readers for the loosely-typed tool input the model sends.
private enum ToolJSON {
    static func encode(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"error": "could not encode the result"}"#
        }
        return text
    }

    static func error(_ message: String) -> String {
        encode(["error": message])
    }

    static func timestamp(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// Accepts an ISO-8601 timestamp or the plain "YYYY-MM-DD HH:mm:ss" /
    /// "YYYY-MM-DD" / "YYYY-MM" / "YYYY" shapes a model tends to send; local time.
    static func parseDate(_ value: Any?) -> Date? {
        guard let text = string(value) else { return nil }
        if let date = isoFormatter.date(from: text) { return date }
        for formatter in [stampFormatter, spacedStampFormatter, dayFormatter, monthFormatter, yearFormatter] {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// A date argument the model supplied. Absent is fine — no filter — but a
    /// value that can't be read has to come back as an error: treating it as
    /// "no filter" silently answers a different question than the one asked.
    static func date(_ input: [String: Any], _ key: String, error: inout String?) -> Date? {
        guard let text = string(input[key]) else { return nil }
        guard let date = parseDate(text) else {
            error = "could not parse \(key) \"\(text)\" — use YYYY-MM-DD, YYYY-MM, YYYY, or a timestamp like 2024-03-15T10:00:00"
            return nil
        }
        return date
    }

    static func truncate(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()
    private static let stampFormatter = formatter("yyyy-MM-dd'T'HH:mm:ss")
    private static let spacedStampFormatter = formatter("yyyy-MM-dd HH:mm:ss")
    private static let dayFormatter = formatter("yyyy-MM-dd")
    private static let monthFormatter = formatter("yyyy-MM")
    private static let yearFormatter = formatter("yyyy")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }
}
