import Foundation

/// One saved AI conversation: the rendered transcript rows plus the raw
/// Messages-API history, so a reopened chat keeps its context for the tool
/// loop. Dictionaries rather than Codable because the API history is
/// free-form JSON.
struct AIStoredChat: Identifiable {
    let id: UUID
    var title: String
    var updatedAt: Date
    var items: [[String: Any]]
    var apiHistory: [[String: Any]]

    init(id: UUID = UUID(), title: String, updatedAt: Date = .now,
         items: [[String: Any]] = [], apiHistory: [[String: Any]] = []) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.items = items
        self.apiHistory = apiHistory
    }

    init?(dictionary: [String: Any]) {
        guard let idString = dictionary["id"] as? String,
              let id = UUID(uuidString: idString),
              let title = dictionary["title"] as? String else { return nil }
        self.id = id
        self.title = title
        updatedAt = Date(timeIntervalSince1970: dictionary["updatedAt"] as? Double ?? 0)
        items = dictionary["items"] as? [[String: Any]] ?? []
        apiHistory = dictionary["api"] as? [[String: Any]] ?? []
    }

    var dictionary: [String: Any] {
        ["id": id.uuidString, "title": title,
         "updatedAt": updatedAt.timeIntervalSince1970,
         "items": items, "api": apiHistory]
    }
}

/// All chats live in one JSON file next to the usage log, rewritten atomically
/// on each save — prototype-simple, no migrations to think about.
enum AIChatStore {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Besties/ai-chats.json")
    }

    static func load() -> [AIStoredChat] {
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = json["chats"] as? [[String: Any]] else { return [] }
        return raw.compactMap(AIStoredChat.init(dictionary:))
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func save(_ chats: [AIStoredChat]) {
        let payload: [String: Any] = ["version": 1, "chats": chats.map(\.dictionary)]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
