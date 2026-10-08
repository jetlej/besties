import SwiftUI

/// One rendered line of the transcript. Footers live in the same list as the
/// bubbles so everything stays in the order it happened.
private struct ChatItem: Identifiable {
    enum Role: String { case user, assistant, error, footer }

    let id = UUID()
    var role: Role
    var text = ""
    var usage = AIUsage()
    var stopReason = ""

    var dictionary: [String: Any] {
        ["role": role.rawValue, "text": text, "stop": stopReason,
         "in": usage.inputTokens, "out": usage.outputTokens,
         "cr": usage.cacheReadTokens, "cw": usage.cacheCreationTokens]
    }

    init(role: Role, text: String = "", usage: AIUsage = AIUsage(), stopReason: String = "") {
        self.role = role
        self.text = text
        self.usage = usage
        self.stopReason = stopReason
    }

    init?(dictionary: [String: Any]) {
        guard let role = Role(rawValue: dictionary["role"] as? String ?? "") else { return nil }
        self.role = role
        text = dictionary["text"] as? String ?? ""
        stopReason = dictionary["stop"] as? String ?? ""
        usage = AIUsage(inputTokens: dictionary["in"] as? Int ?? 0,
                        outputTokens: dictionary["out"] as? Int ?? 0,
                        cacheReadTokens: dictionary["cr"] as? Int ?? 0,
                        cacheCreationTokens: dictionary["cw"] as? Int ?? 0)
    }
}

@MainActor
@Observable
private final class AIChatModel {
    var draft = ""
    private(set) var items: [ChatItem] = []
    /// The session's own `isRunning` isn't observable, so the view watches this.
    private(set) var isRunning = false
    private(set) var lastQuestion: String?
    /// Saved conversations, newest first. `currentID == nil` means an unsaved
    /// fresh chat — it gets an id (and a title) on its first completed turn.
    private(set) var chats: [AIStoredChat] = []
    private(set) var currentID: UUID?

    private let toolbox: AIToolbox
    private var session: AIChatSession
    private var sessionKey: String
    private(set) var turnStartedAt = Date()
    private var turnToolCalls = 0

    /// Switching tabs tears the view down, so the conversation lives here
    /// rather than in view state — still memory only, still gone on quit.
    private static var shared: AIChatModel?

    static func current(appState: AppState) -> AIChatModel {
        if let shared { return shared }
        let model = AIChatModel(appState: appState)
        shared = model
        return model
    }

    private init(appState: AppState) {
        let toolbox = AIToolbox(appState: appState)
        let key = SubscriptionManager.shared.activeKey ?? ""
        self.toolbox = toolbox
        sessionKey = key
        session = AIChatSession(apiKey: key, toolbox: toolbox)
        chats = AIChatStore.load()
    }

    /// The key can change under a live chat — sign-in, a BYOK key added or
    /// removed — so each question rebuilds the session on a new key, carrying
    /// the history over. Never mid-turn: `ask` only gets here when idle.
    private func sessionForCurrentKey() -> AIChatSession? {
        guard let key = SubscriptionManager.shared.activeKey else { return nil }
        if key != sessionKey {
            let history = session.history
            session = AIChatSession(apiKey: key, toolbox: toolbox)
            session.restore(history: history)
            sessionKey = key
        }
        return session
    }

    func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        ask(question, echo: true)
    }

    /// Re-asks the last question after a failure. The client rolled its own
    /// history back, so this starts clean rather than stacking a second turn.
    func retry() {
        guard let question = lastQuestion else { return }
        // Every failure appends its usage footer after the error row, so the
        // row to clear sits just past the trailing footers.
        let trailingFooters = items.reversed().prefix { $0.role == .footer }.count
        let errorIndex = items.count - trailingFooters - 1
        if errorIndex >= 0, items[errorIndex].role == .error { items.remove(at: errorIndex) }
        ask(question, echo: false)
    }

    func newChat() {
        guard !isRunning else { return }
        session.reset()
        items.removeAll()
        lastQuestion = nil
        currentID = nil
    }

    func select(_ chat: AIStoredChat) {
        guard !isRunning, chat.id != currentID else { return }
        currentID = chat.id
        items = chat.items.compactMap(ChatItem.init(dictionary:))
        lastQuestion = items.last(where: { $0.role == .user })?.text
        session.restore(history: chat.apiHistory)
    }

    func delete(_ chat: AIStoredChat) {
        guard !isRunning else { return }
        chats.removeAll { $0.id == chat.id }
        AIChatStore.save(chats)
        if currentID == chat.id { newChat() }
    }

    /// Writes the current conversation to disk after every completed turn,
    /// creating (and titling) it on the first one.
    private func persist() {
        let stored = items.map(\.dictionary)
        if let index = chats.firstIndex(where: { $0.id == currentID }) {
            chats[index].items = stored
            chats[index].apiHistory = session.history
            chats[index].updatedAt = .now
            chats.insert(chats.remove(at: index), at: 0)
        } else {
            let first = items.first(where: { $0.role == .user })?.text ?? "New chat"
            let chat = AIStoredChat(title: String(first.prefix(60)),
                                    items: stored, apiHistory: session.history)
            currentID = chat.id
            chats.insert(chat, at: 0)
        }
        AIChatStore.save(chats)
    }

    private func ask(_ question: String, echo: Bool) {
        guard !isRunning, let session = sessionForCurrentKey() else { return }
        if echo { items.append(ChatItem(role: .user, text: question)) }
        lastQuestion = question
        isRunning = true
        turnStartedAt = .now
        turnToolCalls = 0

        Task {
            await session.ask(question) { [weak self] event in
                self?.handle(event)
            }
            isRunning = false
        }
    }

    private func handle(_ event: AIStreamEvent) {
        switch event {
        case .textDelta(let chunk):
            if items.last?.role == .assistant {
                items[items.count - 1].text += chunk
            } else {
                items.append(ChatItem(role: .assistant, text: chunk))
            }

        case .toolStarted:
            turnToolCalls += 1

        case .toolFinished:
            break

        case .turnCompleted(let turnID, let usage, let stopReason):
            let latency = Int(Date().timeIntervalSince(turnStartedAt) * 1000)
            items.append(ChatItem(role: .footer, usage: usage, stopReason: stopReason))
            AIUsageLog.record(turnID: turnID, source: "chat", usage: usage, stopReason: stopReason,
                              latencyMs: latency, toolCallCount: turnToolCalls)
            persist()
            Task { await SubscriptionManager.shared.refreshMeter() }

        case .failed(let message):
            items.append(ChatItem(role: .error, text: message))
        }
    }
}

/// A report the view is showing. `AIReportKind` isn't Identifiable (and two
/// runs of the same kind are two different sheets), so it rides in a wrapper.
private struct ReportRequest: Identifiable {
    let id = UUID()
    let kind: AIReportKind
}

struct AIChatView: View {
    let appState: AppState
    @State private var model: AIChatModel
    @FocusState private var inputFocused: Bool
    @State private var momentPicker: AIMomentPicker.Moment?
    @State private var pendingKind: AIReportKind?
    @State private var reportRequest: ReportRequest?
    private let subscription = SubscriptionManager.shared

    init(appState: AppState) {
        self.appState = appState
        _model = State(initialValue: AIChatModel.current(appState: appState))
    }

    var body: some View {
        Group {
            if subscription.isActive {
                chat
            } else {
                AIPaywallView()
            }
        }
        .background(Color.paper)
        // Reconnect's ✨ button switches to this tab and leaves a request
        // behind; the tab is built fresh on the switch, so both the arrival
        // and any later request have to be picked up.
        .task { consumeReportRequest() }
        .onChange(of: appState.aiReportRequest) { consumeReportRequest() }
        // The report is presented from the picker's onDismiss, not from the
        // pick itself: swapping one sheet for another in a single update drops
        // the second one.
        .sheet(item: $momentPicker, onDismiss: {
            guard let kind = pendingKind else { return }
            pendingKind = nil
            reportRequest = ReportRequest(kind: kind)
        }) { moment in
            AIMomentPicker(appState: appState, moment: moment) { kind in
                pendingKind = kind
                momentPicker = nil
            }
        }
        .sheet(item: $reportRequest) { request in
            AIReportView(appState: appState, kind: request.kind)
                .frame(minWidth: 520, idealWidth: 620, minHeight: 520, idealHeight: 720)
        }
    }

    private func consumeReportRequest() {
        guard let kind = appState.aiReportRequest else { return }
        appState.aiReportRequest = nil
        // Without a subscription this tab is the paywall (and Reconnect's ✨
        // is hidden), so drop the request — cleared above, so it doesn't fire
        // again — and leave the paywall up.
        guard subscription.isActive else { return }
        reportRequest = ReportRequest(kind: kind)
    }

    // MARK: - Chat

    /// The transcript scrolls inside a flexible middle; the composer is the
    /// last row of the stack, so streaming text never moves it.
    private var chat: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 190)
            Divider()
            VStack(spacing: 0) {
                if model.items.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    transcript
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                composer
                AICreditMeter()
                    .padding(.bottom, 6)
            }
        }
        .task { await subscription.refreshMeter() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.newChat()
            } label: {
                Label("New chat", systemImage: "plus")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.sun, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(model.isRunning)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.chats) { chat in
                        Button {
                            model.select(chat)
                        } label: {
                            Text(chat.title)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(chat.id == model.currentID ? Color.ink.opacity(0.08) : .clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isRunning)
                        .contextMenu {
                            Button("Delete", role: .destructive) { model.delete(chat) }
                        }
                    }
                }
            }
            AIAccountButton()
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.ink.opacity(0.03))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.items) { item in
                        row(item)
                    }
                    if model.isRunning { thinkingRow }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.items.count) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    private static let bottomAnchor = "ai-chat-bottom"

    @ViewBuilder
    private func row(_ item: ChatItem) -> some View {
        switch item.role {
        case .user:
            bubble(item.text, fromMe: true)
        case .assistant:
            bubble(item.text, fromMe: false)
        case .error:
            errorRow(item)
        case .footer:
            footerRow(item)
        }
    }

    private func bubble(_ text: String, fromMe: Bool) -> some View {
        HStack {
            if fromMe { Spacer(minLength: 40) }
            Group {
                if fromMe {
                    Text(text)
                } else {
                    MarkdownBody(text: text)
                }
            }
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                // iMessage-style width cap: long AI answers wrap at a readable
                // measure instead of stretching wall-to-wall.
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(fromMe ? Color.brandBlue : Color.bubbleTan)
                .foregroundStyle(fromMe ? Color.white : Color.ink)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            if !fromMe { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: fromMe ? .trailing : .leading)
    }

    /// Single in-progress line while a turn runs; ticks once a second.
    private var thinkingRow: some View {
        TimelineView(.periodic(from: model.turnStartedAt, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(model.turnStartedAt)))
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Thinking… \(elapsed)s")
                    .font(.caption.monospaced())
            }
            .foregroundStyle(Color.ink.opacity(0.45))
            .padding(.leading, 4)
        }
    }

    private func errorRow(_ item: ChatItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text)
                .textSelection(.enabled)
            Button("Retry") { model.retry() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isRunning || model.lastQuestion == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.bubbleTan)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.5)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footerRow(_ item: ChatItem) -> some View {
        let usage = item.usage
        let tokens = "\(usage.inputTokens.formatted()) in · \(usage.outputTokens.formatted()) out · \(usage.cacheReadTokens.formatted()) cached · \(usage.cacheCreationTokens.formatted()) written"
        let cost = String(format: "$%.4f", usage.costUSD)
        let stop = item.stopReason == "end_turn" ? "" : " · \(item.stopReason)"
        return Text("\(tokens) · \(cost)\(stop)")
            .font(.caption2.monospaced())
            .foregroundStyle(Color.ink.opacity(0.35))
            .padding(.leading, 4)
    }

    private static let suggestions: [(emoji: String, prompt: String, tint: Color)] = [
        ("💬", "Who do I text the most?", .sun),
        ("👀", "Who do I leave on read?", .brandBlue),
        ("📈", "Am I texting more than last year?", .green),
        ("👋", "Who should I reconnect with?", .orange),
        ("🐣", "What was my first ever message?", .purple),
        ("❤️", "Who have I said I love you to the most? Give me a leaderboard", .pink),
    ]

    /// "anything" gets the site's sun-highlight treatment.
    private static let emptyTitle: AttributedString = {
        var title = AttributedString("Ask anything about your messages.")
        if let range = title.range(of: "anything") {
            title[range].backgroundColor = .sun
        }
        return title
    }()

    private var emptyState: some View {
        VStack(spacing: 28) {
            Text(Self.emptyTitle)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
            moments
                .frame(maxWidth: 500)

            VStack(spacing: 10) {
                Text("Or just ask")
                    .font(.caption)
                    .foregroundStyle(Color.ink.opacity(0.45))
                FlowLayout(spacing: 8) {
                    ForEach(Self.suggestions, id: \.prompt) { suggestion in
                        Button {
                            model.draft = suggestion.prompt
                            model.send()
                        } label: {
                            Text("\(suggestion.emoji) \(suggestion.prompt)")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Color.ink)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 8)
                                .background(suggestion.tint.opacity(0.22), in: Capsule())
                                .overlay(Capsule().strokeBorder(suggestion.tint.opacity(0.5)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: 500)
        }
        .padding(24)
    }

    private static let momentCards: [(moment: AIMomentPicker.Moment, emoji: String, title: String, blurb: String, tint: Color)] = [
        (.wrapped, "🎁", "Besties Wrapped",
         "All your messages, one year in review — top people, busiest day, phrase of the year.",
         .sun),
        (.biography, "💛", "Friendship Wrapped",
         "One friendship, wrapped — how it started, your eras, inside jokes, and the longest silence.",
         .purple),
        (.reconnect, "👋", "Reconnect Draft",
         "Reads where you two left off, then writes ready-to-send openers in your voice.",
         .brandBlue),
    ]

    /// The packaged moments: one tap, then a year or a person, then a report.
    private var moments: some View {
        VStack(spacing: 8) {
            Text("Make something worth screenshotting")
                .font(.caption)
                .foregroundStyle(Color.ink.opacity(0.45))
            HStack(alignment: .top, spacing: 10) {
                ForEach(Self.momentCards, id: \.moment) { card in
                    Button {
                        momentPicker = card.moment
                    } label: {
                        VStack(spacing: 4) {
                            Text(card.emoji)
                                .font(.system(size: 24))
                            Text(card.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Color.ink)
                                .multilineTextAlignment(.center)
                            Text(card.blurb)
                                .font(.caption2)
                                .foregroundStyle(Color.ink.opacity(0.5))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.vertical, 13)
                        .padding(.horizontal, 8)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(card.tint.opacity(0.45), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            // Equal-height cards: the HStack sizes to its tallest child and
            // the others stretch to match.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask about your messages…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit { model.send() }
                .disabled(model.isRunning)
            if model.isRunning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    model.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? Color.ink.opacity(0.25) : Color.brandBlue)
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .shadow(color: Color.ink.opacity(0.10), radius: 5, y: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(inputFocused ? Color.sun : Color.ink.opacity(0.12), lineWidth: 1.5))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onAppear { inputFocused = true }
    }
}
