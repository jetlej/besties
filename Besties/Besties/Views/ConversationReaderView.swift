import SwiftUI

@MainActor
@Observable
final class ReaderModel {
    let target: ReaderTarget
    var messages: [ChatMessage] = []
    var peaks = RelationshipPeaks()
    var scrollTo: String?
    var hasOlder = false
    var hasNewer = false
    var isReady = false

    private var imChatIDs: [Int64] = []
    private var waChatIDs: [Int64] = []
    private var started = false
    private var loading = false

    private let pageSize = 100
    private let contextBefore = 30
    private let windowCap = 1500

    init(target: ReaderTarget) {
        self.target = target
    }

    /// Resolve the person's 1:1 chats once, load peak stats, then land on the anchor.
    func start() async {
        guard !started else { return }
        started = true
        let handleIDs = target.imessageHandleIDs
        imChatIDs = await Task.detached {
            (try? MessageStore().fetchChatIDs(handleIDs: handleIDs)) ?? []
        }.value
        waChatIDs = target.whatsAppChatIDs
        isReady = true
        let im = imChatIDs
        let wa = waChatIDs
        peaks = await Task.detached {
            var counts = (try? MessageStore().fetchDayCounts(chatIDs: im)) ?? [:]
            for (day, c) in (try? WhatsAppStore().fetchDayCounts(chatIDs: wa)) ?? [:] {
                counts[day, default: 0] += c
            }
            return RelationshipPeaks(dayCounts: counts)
        }.value
        await jump(to: target.anchorDate)
    }

    /// One merged page across both stores, ascending. Each source pages from
    /// its own keyset cursor; the merged result is trimmed to `limit` on the
    /// fetch-direction side, and `more` reports whether messages remain beyond
    /// the trim (a full page from either source, or trimmed overflow).
    nonisolated private static func fetchMerged(
        im: [Int64], wa: [Int64],
        imCursor: (date: Int64, id: Int64), waCursor: (date: Int64, id: Int64),
        older: Bool, limit: Int
    ) -> (page: [ChatMessage], more: Bool) {
        let imPage = older
            ? ((try? MessageStore().fetchMessages(chatIDs: im, before: imCursor, limit: limit)) ?? [])
            : ((try? MessageStore().fetchMessages(chatIDs: im, after: imCursor, limit: limit)) ?? [])
        let waPage = older
            ? ((try? WhatsAppStore().fetchMessages(chatIDs: wa, before: waCursor, limit: limit)) ?? [])
            : ((try? WhatsAppStore().fetchMessages(chatIDs: wa, after: waCursor, limit: limit)) ?? [])

        var merged = (imPage + waPage).sorted {
            ($0.dateNano, $0.source.rawValue, $0.rowID) < ($1.dateNano, $1.source.rawValue, $1.rowID)
        }
        let more = imPage.count == limit || waPage.count == limit || merged.count > limit
        if merged.count > limit {
            // Keep the side nearest the window; the dropped remainder is
            // re-fetched by the next page (cursors derive from kept messages).
            merged = older ? Array(merged.suffix(limit)) : Array(merged.prefix(limit))
        }
        return (merged, more)
    }

    /// A source's keyset cursor at the window edge: its outermost message in
    /// the window, or — when the window holds none of its messages — the
    /// window edge itself, exclusive.
    private func edgeCursor(older: Bool, source: MessageSource) -> (date: Int64, id: Int64) {
        if older {
            if let m = messages.first(where: { $0.source == source }) { return (m.dateNano, m.rowID) }
            return (messages.first?.dateNano ?? 0, Int64.min)
        }
        if let m = messages.last(where: { $0.source == source }) { return (m.dateNano, m.rowID) }
        return (messages.last?.dateNano ?? 0, Int64.max)
    }

    /// Replace the window with context around `date`: a little history above,
    /// a page of messages at/after the anchor below.
    func jump(to date: Date) async {
        guard imChatIDs.isEmpty == false || waChatIDs.isEmpty == false, !loading else { return }
        loading = true
        defer { loading = false }

        let anchor = MessageStore.nanoseconds(from: date)
        let im = imChatIDs
        let wa = waChatIDs
        let before = contextBefore
        let after = pageSize
        let result = await Task.detached { () -> (older: (page: [ChatMessage], more: Bool), newer: (page: [ChatMessage], more: Bool)) in
            // (anchor, Int64.min) splits cleanly: older is strictly < anchor, newer is >= anchor.
            let older = Self.fetchMerged(im: im, wa: wa, imCursor: (anchor, Int64.min), waCursor: (anchor, Int64.min), older: true, limit: before)
            let newer = Self.fetchMerged(im: im, wa: wa, imCursor: (anchor, Int64.min), waCursor: (anchor, Int64.min), older: false, limit: after)
            return (older, newer)
        }.value

        messages = result.older.page + result.newer.page
        hasOlder = result.older.more
        hasNewer = result.newer.more
        scrollTo = result.newer.page.first?.id ?? result.older.page.last?.id
    }

    func loadOlder() async {
        guard hasOlder, !loading, let first = messages.first else { return }
        loading = true
        defer { loading = false }

        let im = imChatIDs
        let wa = waChatIDs
        let imCursor = edgeCursor(older: true, source: .iMessage)
        let waCursor = edgeCursor(older: true, source: .whatsApp)
        let size = pageSize
        let result = await Task.detached {
            Self.fetchMerged(im: im, wa: wa, imCursor: imCursor, waCursor: waCursor, older: true, limit: size)
        }.value

        guard !result.page.isEmpty else { hasOlder = false; return }
        messages.insert(contentsOf: result.page, at: 0)
        hasOlder = result.more
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

        let im = imChatIDs
        let wa = waChatIDs
        let imCursor = edgeCursor(older: false, source: .iMessage)
        let waCursor = edgeCursor(older: false, source: .whatsApp)
        let size = pageSize
        let result = await Task.detached {
            Self.fetchMerged(im: im, wa: wa, imCursor: imCursor, waCursor: waCursor, older: false, limit: size)
        }.value

        guard !result.page.isEmpty else { hasNewer = false; return }
        messages.append(contentsOf: result.page)
        hasNewer = result.more
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
