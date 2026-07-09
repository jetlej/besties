import SwiftUI
import AppKit

@main
struct BestiesApp: App {
    @State private var appState = AppState()

    init() {
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count > 1 {
            NSApp.terminate(nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.hasFullDiskAccess {
                    ContentView(appState: appState)
                } else {
                    OnboardingView(appState: appState)
                }
            }
            .frame(minWidth: 500, idealWidth: 600, minHeight: 400)
            .task {
                appState.checkAccess()
                DispatchQueue.main.async {
                    NSApp.windows.first?.title = "Besties"
                }
            }
        }
        .defaultSize(width: 600, height: 500)
    }
}

@Observable
final class AppState {
    var hasFullDiskAccess = false
    var allConversations: [Conversation] = []
    var resolvedConversations: [Conversation] = []
    var timelineMonths: [String] = []
    var monthlyConversations: [String: [Conversation]] = [:]
    var peoplePerMonth: [Int] = []
    var sentPerMonth: [Int] = []
    var globalStats = GlobalStats()
    var timelineLoading = false
    @ObservationIgnored private var avatarCache: [String: Data?] = [:]
    var isLoading = false
    var error: String?

    private let messageStore = MessageStore()
    private let analyzer = ConversationAnalyzer()
    private let contactResolver = ContactResolver()

    func reconnectConversations(maxDays: Int) -> [Conversation] {
        var a = analyzer
        a.maximumDormantDays = maxDays
        return a.score(resolvedConversations)
    }

    func loadTimeline() {
        guard !timelineLoading, monthlyConversations.isEmpty else { return }
        timelineLoading = true

        let names: [String: String] = Dictionary(
            resolvedConversations.compactMap { c in c.displayName.map { (c.handle, $0) } },
            uniquingKeysWith: { first, _ in first }
        )

        Task { [messageStore] in
            let result: Result<([String: [Conversation]], [String], [Int], [Int], GlobalStats), Error> = await Task.detached {
                do {
                    var byMonth = try messageStore.fetchConversationsByMonth()
                    for (month, convos) in byMonth {
                        var resolved = convos
                        for i in resolved.indices {
                            resolved[i].displayName = names[resolved[i].handle]
                        }
                        byMonth[month] = resolved.sorted { $0.totalMessages > $1.totalMessages }
                    }
                    let months = Self.monthRange(from: byMonth.keys.min())
                    var people: [Int] = []
                    var sent: [Int] = []
                    for month in months {
                        var names = Set<String>()
                        var sentCount = 0
                        for convo in byMonth[month] ?? [] {
                            names.insert(convo.resolvedName)
                            sentCount += convo.sentMessages
                        }
                        people.append(names.count)
                        sent.append(sentCount)
                    }
                    let stats = (try? messageStore.fetchGlobalStats()) ?? GlobalStats()
                    return .success((byMonth, months, people, sent, stats))
                } catch {
                    return .failure(error)
                }
            }.value

            switch result {
            case .success(let (byMonth, months, people, sent, stats)):
                self.monthlyConversations = byMonth
                self.timelineMonths = months
                self.peoplePerMonth = people
                self.sentPerMonth = sent
                self.globalStats = stats
            case .failure(let error):
                self.error = error.localizedDescription
            }
            self.timelineLoading = false
        }
    }

    func avatar(forHandle handle: String) -> Data? {
        if let cached = avatarCache[handle] { return cached }
        let data = contactResolver.imageData(forHandle: handle)
        avatarCache[handle] = data
        return data
    }

    /// Fills in missing contact names by spreading a resolved name across every
    /// handle that belongs to the same person. Apple's `person_centric_id` links
    /// handles across services (a phone + an email); handles that share an id
    /// string but only some are on the contact card are covered too. This is why
    /// e.g. an Apple-ID email that isn't saved on the card still shows the
    /// person's name and merges into their totals instead of standing alone.
    private static func propagateNames(_ conversations: inout [Conversation]) {
        var nameByPerson: [String: String] = [:]
        var nameByHandle: [String: String] = [:]
        for c in conversations {
            guard let name = c.displayName else { continue }
            if let pid = c.personID, nameByPerson[pid] == nil { nameByPerson[pid] = name }
            if nameByHandle[c.handle] == nil { nameByHandle[c.handle] = name }
        }
        for i in conversations.indices where conversations[i].displayName == nil {
            if let pid = conversations[i].personID, let name = nameByPerson[pid] {
                conversations[i].displayName = name
            } else if let name = nameByHandle[conversations[i].handle] {
                conversations[i].displayName = name
            }
        }
    }

    /// Every "yyyy-MM" key from the first month with messages through the current month.
    private static func monthRange(from firstKey: String?) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        guard let firstKey, var month = formatter.date(from: firstKey) else { return [] }

        var months: [String] = []
        while month <= .now {
            months.append(formatter.string(from: month))
            guard let next = Calendar.current.date(byAdding: .month, value: 1, to: month) else { break }
            month = next
        }
        return months
    }

    func checkAccess() {
        hasFullDiskAccess = PermissionChecker.hasFullDiskAccess()
        if hasFullDiskAccess {
            loadConversations()
        }
    }

    func loadConversations() {
        isLoading = true
        error = nil

        Task { [messageStore, contactResolver] in
            let result: Result<[Conversation], Error> = await Task.detached {
                contactResolver.loadContacts()
                do {
                    let raw = try messageStore.fetchConversations()
                    var resolved = raw
                    for i in resolved.indices {
                        resolved[i].displayName = contactResolver.resolve(handle: resolved[i].handle)
                    }
                    Self.propagateNames(&resolved)
                    return .success(resolved)
                } catch {
                    return .failure(error)
                }
            }.value

            switch result {
            case .success(let resolved):
                self.resolvedConversations = resolved
                self.allConversations = resolved.sorted { $0.totalMessages > $1.totalMessages }
                self.isLoading = false
            case .failure(let error):
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}
