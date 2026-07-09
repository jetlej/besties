import SwiftUI

@MainActor
@Observable
final class ReaderModel {
    let target: ReaderTarget
    var messages: [ChatMessage] = []
    var peaks = RelationshipPeaks()
    var scrollTo: Int64?
    var hasOlder = false
    var hasNewer = false
    var isReady = false

    private var chatIDs: [Int64] = []
    private var loading = false

    private let pageSize = 100
    private let contextBefore = 30
    private let windowCap = 1500

    init(target: ReaderTarget) {
        self.target = target
    }

    /// Resolve the person's 1:1 chats once, load peak stats, then land on the anchor.
    func start() async {
        guard chatIDs.isEmpty else { return }
        let handleIDs = target.handleIDs
        chatIDs = await Task.detached {
            (try? MessageStore().fetchChatIDs(handleIDs: handleIDs)) ?? []
        }.value
        isReady = true
        let ids = chatIDs
        peaks = await Task.detached {
            (try? MessageStore().fetchRelationshipPeaks(chatIDs: ids)) ?? RelationshipPeaks()
        }.value
        await jump(to: target.anchorDate)
    }

    /// Replace the window with context around `date`: a little history above,
    /// a page of messages at/after the anchor below.
    func jump(to date: Date) async {
        guard !chatIDs.isEmpty, !loading else { return }
        loading = true
        defer { loading = false }

        let anchor = MessageStore.nanoseconds(from: date)
        let ids = chatIDs
        let before = contextBefore
        let after = pageSize
        let result = await Task.detached { () -> (older: [ChatMessage], newer: [ChatMessage]) in
            let store = MessageStore()
            // (anchor, Int64.min) splits cleanly: older is strictly < anchor, newer is >= anchor.
            let older = (try? store.fetchMessages(chatIDs: ids, before: (anchor, Int64.min), limit: before)) ?? []
            let newer = (try? store.fetchMessages(chatIDs: ids, after: (anchor, Int64.min), limit: after)) ?? []
            return (older, newer)
        }.value

        messages = result.older + result.newer
        hasOlder = result.older.count == before
        hasNewer = result.newer.count == after
        scrollTo = result.newer.first?.id ?? result.older.last?.id
    }

    func loadOlder() async {
        guard hasOlder, !loading, let first = messages.first else { return }
        loading = true
        defer { loading = false }

        let cursor = (first.dateNano, first.id)
        let ids = chatIDs
        let size = pageSize
        let page = await Task.detached {
            (try? MessageStore().fetchMessages(chatIDs: ids, before: cursor, limit: size)) ?? []
        }.value

        guard !page.isEmpty else { hasOlder = false; return }
        messages.insert(contentsOf: page, at: 0)
        hasOlder = page.count == size
        if messages.count > windowCap {
            messages.removeLast(messages.count - windowCap)
            hasNewer = true
        }
        scrollTo = first.id   // keep the previously-first message in place
    }

    func loadNewer() async {
        guard hasNewer, !loading, let last = messages.last else { return }
        loading = true
        defer { loading = false }

        let cursor = (last.dateNano, last.id)
        let ids = chatIDs
        let size = pageSize
        let page = await Task.detached {
            (try? MessageStore().fetchMessages(chatIDs: ids, after: cursor, limit: size)) ?? []
        }.value

        guard !page.isEmpty else { hasNewer = false; return }
        messages.append(contentsOf: page)
        hasNewer = page.count == size
        if messages.count > windowCap {
            messages.removeFirst(messages.count - windowCap)
            hasOlder = true
            scrollTo = last.id   // pin to where the reader was before trimming above
        }
    }
}

struct ConversationReaderView: View {
    @State private var model: ReaderModel
    @State private var scrubPosition: Double
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    private let target: ReaderTarget

    init(target: ReaderTarget, appState: AppState) {
        self.target = target
        self.appState = appState
        _model = State(initialValue: ReaderModel(target: target))
        _scrubPosition = State(initialValue: target.anchorDate.timeIntervalSinceReferenceDate)
    }

    private var scrubLo: Double { target.firstDate.timeIntervalSinceReferenceDate }
    private var scrubHi: Double { max(target.lastDate.timeIntervalSinceReferenceDate, scrubLo + 1) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            kpiBand
            Divider()
            transcript
            Divider()
            scrubber
        }
        .task { await model.start() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(name: target.name, imageData: appState.avatar(forHandle: target.handle),
                       color: leaderboardColor, size: 32)
            Text(target.name)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button("Done") { dismiss() }
        }
        .padding(12)
    }

    private var kpiBand: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], spacing: 8) {
            ForEach(Array(kpiCards.enumerated()), id: \.offset) { _, card in
                if let jump = card.jump {
                    KPICard(value: card.value, label: card.label)
                        .contentShape(Rectangle())
                        .onTapGesture { scrub(to: jump) }
                        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
                } else {
                    KPICard(value: card.value, label: card.label)
                }
            }
        }
        .padding(12)
    }

    /// Static totals first, then the three busiest-period cards which jump the
    /// scrubber to the start of that day / month / year when clicked.
    private var kpiCards: [(value: String, label: String, jump: Date?)] {
        let total = target.totalMessages
        let sentShare = total > 0 ? Int((Double(target.sentMessages) / Double(total) * 100).rounded()) : 0
        var cards: [(String, String, Date?)] = [
            (total.formatted(), "Total messages", nil),
            ("\(sentShare)%", "Sent by you", nil),
            (durationLabel(from: target.firstDate, to: target.lastDate), "Talking for", nil),
        ]
        if let d = model.peaks.busiestDay {
            cards.append((d.date.formatted(.dateTime.month(.abbreviated).day().year()), "Busiest day (\(d.count))", d.date))
        }
        if let m = model.peaks.busiestMonth {
            cards.append((m.date.formatted(.dateTime.month(.abbreviated).year()), "Busiest month (\(m.count))", m.date))
        }
        if let y = model.peaks.busiestYear {
            let start = Calendar.current.date(from: DateComponents(year: y.year, month: 1, day: 1)) ?? target.firstDate
            cards.append((String(y.year), "Busiest year (\(y.count))", start))
        }
        return cards
    }

    /// Move the scrubber and jump the transcript to a date, clamped to the range.
    private func scrub(to date: Date) {
        let t = min(max(date.timeIntervalSinceReferenceDate, scrubLo), scrubHi)
        scrubPosition = t
        let clamped = Date(timeIntervalSinceReferenceDate: t)
        Task { await model.jump(to: clamped) }
    }

    private func durationLabel(from: Date, to: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: from, to: to)
        let y = c.year ?? 0, m = c.month ?? 0
        if y > 0 && m > 0 { return "\(y)y \(m)mo" }
        if y > 0 { return "\(y)y" }
        return "\(max(m, 0))mo"
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if model.hasOlder {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .onAppear { Task { await model.loadOlder() } }
                }
                ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, msg in
                    if index == 0 || !Calendar.current.isDate(msg.date, inSameDayAs: model.messages[index - 1].date) {
                        DaySeparator(date: msg.date)
                    }
                    MessageBubble(message: msg)
                        .id(msg.id)
                }
                if model.hasNewer {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .onAppear { Task { await model.loadNewer() } }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollPosition(id: Binding(get: { model.scrollTo }, set: { model.scrollTo = $0 }), anchor: .center)
        .overlay {
            if model.isReady && model.messages.isEmpty {
                Text("No messages.").foregroundStyle(.secondary)
            }
        }
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Text(Date(timeIntervalSinceReferenceDate: scrubPosition).formatted(.dateTime.month(.wide).year()))
                .font(.headline)
                .monospacedDigit()
            Slider(
                value: $scrubPosition,
                in: scrubLo...scrubHi,
                onEditingChanged: { editing in
                    if !editing {
                        let date = Date(timeIntervalSinceReferenceDate: scrubPosition)
                        Task { await model.jump(to: date) }
                    }
                }
            )
            HStack {
                Text(target.firstDate.formatted(.dateTime.month(.abbreviated).year()))
                Spacer()
                Text(target.lastDate.formatted(.dateTime.month(.abbreviated).year()))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

private struct DaySeparator: View {
    let date: Date

    var body: some View {
        Text(date.formatted(.dateTime.weekday(.abbreviated).month().day().year()))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 40) }
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(message.isFromMe ? Color.accentColor : Color(.quaternaryLabelColor))
                    .foregroundStyle(message.isFromMe ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Text(message.date.formatted(.dateTime.hour().minute()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !message.isFromMe { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)
    }
}
