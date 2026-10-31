import Foundation
import Network
import Observation

/// The MCP tools' view of the app: a snapshot of the people list (handed
/// over from AppState on the main thread whenever it reloads) plus direct,
/// read-only reads of chat.db, WhatsApp and the search index.
final class MCPAppLibrary: MCPLibrary {
    private let lock = NSLock()
    private var conversations: [Conversation] = []
    private var chatInfoByID: [Int64: MessageStore.ChatInfo] = [:]
    private let searchIndex: SearchIndex

    init(searchIndex: SearchIndex) {
        self.searchIndex = searchIndex
    }

    func update(conversations: [Conversation], chatInfoByID: [Int64: MessageStore.ChatInfo]) {
        lock.withLock {
            self.conversations = conversations
            self.chatInfoByID = chatInfoByID
        }
    }

    private var snapshot: (conversations: [Conversation], chats: [Int64: MessageStore.ChatInfo]) {
        lock.withLock { (conversations, chatInfoByID) }
    }

    func people() -> [MCPPerson] {
        Dictionary(grouping: snapshot.conversations, by: \.mergeKey)
            .compactMap { key, group in Self.person(key: key, group: group) }
            .sorted { $0.totalMessages > $1.totalMessages }
    }

    func reconnect(maxDaysSinceContact: Int, limit: Int) -> [MCPPerson] {
        var analyzer = ConversationAnalyzer()
        analyzer.maximumDormantDays = maxDaysSinceContact
        let all = snapshot.conversations
        return analyzer.score(AppState.mergedByPerson(all)).prefix(limit).compactMap { row in
            Self.person(key: row.mergeKey, group: all.filter { $0.mergeKey == row.mergeKey })
        }
    }

    func messages(personID: String, from: Date?, to: Date?, limit: Int) throws -> [MCPMessage] {
        let (im, wa) = try chats(for: personID)
        let page: [ChatMessage]
        if let from {
            let cursor = (date: MessageStore.nanoseconds(from: from), id: Int64.min)
            let end = to.map(MessageStore.nanoseconds(from:)) ?? .max
            let merged = try (MessageStore().fetchMessages(chatIDs: im, after: cursor, limit: limit)
                + WhatsAppStore().fetchMessages(chatIDs: wa, after: cursor, limit: limit))
                .filter { $0.dateNano < end }
                .sorted { ($0.dateNano, $0.rowID) < ($1.dateNano, $1.rowID) }
            page = Array(merged.prefix(limit))
        } else {
            let cursor = to.map { (date: MessageStore.nanoseconds(from: $0), id: Int64.min) } ?? (date: .max, id: .max)
            let merged = try (MessageStore().fetchMessages(chatIDs: im, before: cursor, limit: limit)
                + WhatsAppStore().fetchMessages(chatIDs: wa, before: cursor, limit: limit))
                .sorted { ($0.dateNano, $0.rowID) < ($1.dateNano, $1.rowID) }
            page = Array(merged.suffix(limit))
        }
        return page.compactMap { m in
            guard m.text != "[unsupported]" else { return nil }
            return MCPMessage(date: m.date, isFromMe: m.isFromMe, text: m.text == "[attachment]" ? "(attachment)" : m.text)
        }
    }

    func search(_ query: String, personID: String?, limit: Int) throws -> [MCPSearchHit] {
        var options = SearchIndex.Options()
        options.sort = .newest
        options.limit = limit
        if let personID {
            let (im, wa) = try chats(for: personID)
            options.chats = im.map { SearchIndex.ChatRef(source: .iMessage, id: $0) }
                + wa.map { SearchIndex.ChatRef(source: .whatsApp, id: $0) }
        }
        let (conversations, chats) = snapshot
        let bySession = Dictionary(conversations.filter { $0.source == .whatsApp }.map { ($0.rowID, $0) }, uniquingKeysWith: { a, _ in a })
        let byHandle = Dictionary(conversations.filter { $0.source == .iMessage }.map { ($0.rowID, $0) }, uniquingKeysWith: { a, _ in a })
        return try searchIndex.search(query, options: options).results.map { hit in
            let chat: String
            if hit.source == .whatsApp {
                chat = bySession[hit.chatID]?.resolvedName ?? "Unknown"
            } else if let info = chats[hit.chatID] {
                chat = info.isGroup ? (info.displayName ?? "Group chat")
                    : info.handleID.flatMap { byHandle[$0]?.resolvedName } ?? info.displayName ?? "Unknown"
            } else {
                chat = "Unknown"
            }
            let snippet = hit.snippet
                .replacingOccurrences(of: SearchIndex.markStart, with: "")
                .replacingOccurrences(of: SearchIndex.markEnd, with: "")
            return MCPSearchHit(date: hit.date, chat: chat, isFromMe: hit.isFromMe, snippet: snippet)
        }
    }

    /// A person's 1:1 chat rowids (iMessage) and WhatsApp session ids.
    private func chats(for personID: String) throws -> (iMessage: [Int64], whatsApp: [Int64]) {
        let group = snapshot.conversations.filter { $0.mergeKey == personID }
        guard !group.isEmpty else { throw MessageStoreError.queryFailed("Unknown person \(personID)") }
        let handles = group.filter { $0.source == .iMessage }.map(\.rowID)
        return (try MessageStore().fetchChatIDs(handleIDs: handles), group.filter { $0.source == .whatsApp }.map(\.rowID))
    }

    private static func person(key: String, group: [Conversation]) -> MCPPerson? {
        guard let busiest = group.max(by: { $0.totalMessages < $1.totalMessages }) else { return nil }
        return MCPPerson(
            id: key,
            name: busiest.resolvedName,
            totalMessages: group.reduce(0) { $0 + $1.totalMessages },
            sentMessages: group.reduce(0) { $0 + $1.sentMessages },
            firstDate: group.map(\.firstMessageDate).min() ?? busiest.firstMessageDate,
            lastDate: group.map(\.lastMessageDate).max() ?? busiest.lastMessageDate
        )
    }
}

/// On/off, token and port for the MCP server. Off by default; when on, it
/// runs for as long as the app is open.
@Observable
final class MCPController {
    static let defaultPort: UInt16 = 47210
    private static let tokenAccount = "mcpToken"
    /// Same Keychain service as the AI subscription's items.
    private static let keychain = KeychainStore(service: "com.besties.app")

    enum State: Equatable {
        case off
        case starting
        case running
        case failed(String)
    }

    private(set) var state = State.off
    let library: MCPAppLibrary
    @ObservationIgnored private var listener: MCPListener?
    @ObservationIgnored private var handler: MCPHandler?

    var enabled = UserDefaults.standard.bool(forKey: "mcpEnabled") {
        didSet {
            guard oldValue != enabled else { return }
            UserDefaults.standard.set(enabled, forKey: "mcpEnabled")
            enabled ? start() : stop()
        }
    }

    var port: UInt16 = UInt16(exactly: UserDefaults.standard.integer(forKey: "mcpPort")).flatMap { $0 == 0 ? nil : $0 } ?? MCPController.defaultPort {
        didSet {
            guard oldValue != port else { return }
            UserDefaults.standard.set(Int(port), forKey: "mcpPort")
            if enabled { stop(); start() }
        }
    }

    /// The bearer token AI apps must send. Kept in the Keychain; read (or
    /// created) only once the feature is used.
    private(set) var token = ""

    var endpoint: String { "http://127.0.0.1:\(port)\(MCPHandler.path)" }

    init(searchIndex: SearchIndex) {
        library = MCPAppLibrary(searchIndex: searchIndex)
        if enabled { start() }
    }

    func loadToken() {
        guard token.isEmpty else { return }
        if let saved = Self.keychain.read(Self.tokenAccount), !saved.isEmpty {
            token = saved
        } else {
            token = MCPHandler.makeToken()
            Self.keychain.write(token, for: Self.tokenAccount)
        }
    }

    /// Issues a new token; apps using the old one stop working.
    func resetToken() {
        token = MCPHandler.makeToken()
        Self.keychain.write(token, for: Self.tokenAccount)
        handler?.setToken(token)
    }

    private func start() {
        loadToken()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        let handler = MCPHandler(token: token, library: library, serverVersion: version)
        let listener = MCPListener(handler: handler)
        state = .starting
        do {
            try listener.start(port: port) { [weak self] newState in
                DispatchQueue.main.async {
                    guard let self, self.listener === listener else { return }
                    switch newState {
                    case .ready:
                        self.state = .running
                    case .failed(let error), .waiting(let error):
                        // e.g. the port is taken: give up and say so.
                        self.listener?.stop()
                        self.listener = nil
                        self.handler = nil
                        self.state = .failed("Couldn't start on port \(self.port): \(error.localizedDescription). Try another port.")
                    default:
                        break
                    }
                }
            }
            self.listener = listener
            self.handler = handler
        } catch {
            state = .failed("Couldn't start on port \(port): \(error.localizedDescription)")
        }
    }

    private func stop() {
        listener?.stop()
        listener = nil
        handler = nil
        state = .off
    }
}
