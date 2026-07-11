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

        Settings {
            SettingsView(appState: appState)
        }
    }
}

@Observable
final class AppState {
    private static let whatsAppEnabledKey = "whatsAppEnabled"

    var hasFullDiskAccess = false

    /// Whether WhatsApp history is folded in. Persisted; flipping it reloads
    /// everything from scratch.
    var whatsAppEnabled: Bool = UserDefaults.standard.object(forKey: whatsAppEnabledKey) as? Bool ?? true {
        didSet {
            guard oldValue != whatsAppEnabled else { return }
            UserDefaults.standard.set(whatsAppEnabled, forKey: Self.whatsAppEnabledKey)
            guard hasFullDiskAccess else { return }
            monthlyConversations = [:]
            timelineMonths = []
            peoplePerMonth = []
            sentPerMonth = []
            loadConversations()
        }
    }

    var whatsAppInstalled: Bool { whatsAppStore.isInstalled }
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
    private let whatsAppStore = WhatsAppStore()
    private let analyzer = ConversationAnalyzer()
    private let contactResolver = ContactResolver()

    func reconnectConversations(maxDays: Int) -> [Conversation] {
        var a = analyzer
        a.maximumDormantDays = maxDays
        return a.score(Self.mergedByPerson(resolvedConversations))
    }

    /// Collapses a person's conversations (iMessage + SMS + WhatsApp) into one
    /// combined row, so dormancy reflects the last contact on *any* platform
    /// and nobody shows up twice in Reconnect. The busiest conversation keeps
    /// the row's handle/source for the message button.
    private static func mergedByPerson(_ conversations: [Conversation]) -> [Conversation] {
        var groups: [String: [Conversation]] = [:]
        for c in conversations { groups[c.mergeKey, default: []].append(c) }
        return groups.values.map { group in
            guard group.count > 1,
                  let busiest = group.max(by: { $0.totalMessages < $1.totalMessages }),
                  let latest = group.max(by: { $0.lastMessageDate < $1.lastMessageDate })
            else { return group[0] }
            return Conversation(
                rowID: busiest.rowID,
                source: busiest.source,
                handle: busiest.handle,
                displayName: busiest.displayName ?? group.compactMap(\.displayName).first,
                personID: busiest.personID,
                totalMessages: group.reduce(0) { $0 + $1.totalMessages },
                sentMessages: group.reduce(0) { $0 + $1.sentMessages },
                receivedMessages: group.reduce(0) { $0 + $1.receivedMessages },
                firstMessageDate: group.map(\.firstMessageDate).min() ?? busiest.firstMessageDate,
                lastMessageDate: latest.lastMessageDate,
                lastMessageIsFromMe: latest.lastMessageIsFromMe
            )
        }
    }

    func loadTimeline() {
        guard !timelineLoading, monthlyConversations.isEmpty else { return }
        timelineLoading = true

        let names: [String: String] = Dictionary(
            resolvedConversations.compactMap { c in c.displayName.map { (c.handle, $0) } },
            uniquingKeysWith: { first, _ in first }
        )

        let includeWhatsApp = whatsAppEnabled
        Task { [messageStore, whatsAppStore] in
            let result: Result<([String: [Conversation]], [String], [Int], [Int], GlobalStats), Error> = await Task.detached {
                do {
                    var byMonth = try messageStore.fetchConversationsByMonth()
                    if includeWhatsApp {
                        for (month, convos) in (try? whatsAppStore.fetchConversationsByMonth()) ?? [:] {
                            byMonth[month, default: []] += convos
                        }
                    }
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
                        var keys = Set<String>()
                        var sentCount = 0
                        for convo in byMonth[month] ?? [] {
                            keys.insert(convo.mergeKey)
                            sentCount += convo.sentMessages
                        }
                        people.append(keys.count)
                        sent.append(sentCount)
                    }
                    var stats = (try? messageStore.fetchGlobalStats()) ?? GlobalStats()
                    if includeWhatsApp, let waHours = try? whatsAppStore.fetchSentHourCounts() {
                        stats.sentHourCounts = zip(stats.sentHourCounts, waHours).map(+)
                    }
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
        var nameByDigits: [String: String] = [:]
        for c in conversations {
            guard let name = c.displayName else { continue }
            if let pid = c.personID, nameByPerson[pid] == nil { nameByPerson[pid] = name }
            if nameByHandle[c.handle] == nil { nameByHandle[c.handle] = name }
            // Digit key spreads a name across sources even when the handle
            // formatting differs (e.g. a WhatsApp partner name onto the same
            // number's unsaved iMessage handle).
            let digits = c.handle.filter(\.isNumber)
            if digits.count >= 7 {
                let key = String(digits.suffix(10))
                if nameByDigits[key] == nil { nameByDigits[key] = name }
            }
        }
        for i in conversations.indices where conversations[i].displayName == nil {
            if let pid = conversations[i].personID, let name = nameByPerson[pid] {
                conversations[i].displayName = name
            } else if let name = nameByHandle[conversations[i].handle] {
                conversations[i].displayName = name
            } else {
                let digits = conversations[i].handle.filter(\.isNumber)
                if digits.count >= 7, let name = nameByDigits[String(digits.suffix(10))] {
                    conversations[i].displayName = name
                }
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

        let includeWhatsApp = whatsAppEnabled
        Task { [messageStore, whatsAppStore, contactResolver] in
            let result: Result<[Conversation], Error> = await Task.detached {
                contactResolver.loadContacts()
                do {
                    let raw = try messageStore.fetchConversations()
                        + (includeWhatsApp ? ((try? whatsAppStore.fetchConversations()) ?? []) : [])
                    var resolved = raw
                    for i in resolved.indices {
                        // Keep WhatsApp's partner-name fallback when the number
                        // isn't on a contact card here.
                        if let name = contactResolver.resolve(handle: resolved[i].handle) {
                            resolved[i].displayName = name
                        }
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
