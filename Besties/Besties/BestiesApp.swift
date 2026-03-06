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
