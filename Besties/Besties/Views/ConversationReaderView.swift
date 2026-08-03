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
    /// The message a search sent the reader to — flashed briefly, then cleared.
    var highlightID: String?
    /// Same message, but persistent: its matched words stay marked so the eye
    /// can find the mention after the ring fades. Cleared on the next plain jump.
    var textHighlightID: String?
    var highlightTerms: [String] = []

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
        if let chatIDs = target.imessageChatIDs {
            imChatIDs = chatIDs
        } else {
            let handleIDs = target.imessageHandleIDs
            imChatIDs = await Task.detached {
                (try? MessageStore().fetchChatIDs(handleIDs: handleIDs)) ?? []
            }.value
        }
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
        await jump(to: target.anchorDate, highlight: target.anchorMessageID, terms: target.highlightTerms)
    }

    /// This conversation's chats, for scoping search to it.
    var chatRefs: [SearchIndex.ChatRef] {
        imChatIDs.map { SearchIndex.ChatRef(source: .iMessage, id: $0) }
            + waChatIDs.map { SearchIndex.ChatRef(source: .whatsApp, id: $0) }
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
    /// a page of messages at/after the anchor below. `highlight` is the
    /// ChatMessage.id of a searched-for message, flashed once it's on screen.
    func jump(to date: Date, highlight: String? = nil, terms: [String] = []) async {
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

        highlightID = highlight
        textHighlightID = highlight
        highlightTerms = highlight == nil ? [] : terms
        guard let highlight else { return }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if highlightID == highlight { highlightID = nil }
        }
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
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var searchResults: [SearchIndex.Result] = []
    @State private var searchTotal = 0
    @FocusState private var searchFocused: Bool
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
            if showSearch {
                searchPanel
                Divider()
            }
            kpiBand
            Divider()
            transcript
            Divider()
            scrubber
        }
        .background(Color.paper)
        .fontDesign(.rounded)
        .task { await model.start() }
        .task(id: "\(searchQuery)|\(model.isReady)") { await runSearch() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(name: target.name, imageData: appState.avatar(forHandle: target.handle),
                       color: leaderboardColor, size: 32)
            Text(target.name)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button {
                showSearch.toggle()
                if showSearch { searchFocused = true } else { searchQuery = "" }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .help("Search this conversation")
            Button("Done") { dismiss() }
        }
        .padding(12)
    }

    // MARK: - In-conversation search

    /// Searches the same index as the Search tab, scoped to this
    /// conversation's chats; picking a match jumps the transcript to it.
    private var searchPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search this conversation", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if searchTotal > 0 {
                    Text("\(searchTotal.formatted()) \(searchTotal == 1 ? "match" : "matches")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    showSearch = false
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !searchResults.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(searchResults) { result in
                            Button {
                                scrub(to: result.date, highlight: result.id, terms: queryTerms)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(result.date.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                    Text(searchSnippetText(result.snippet, isFromMe: result.isFromMe))
                                        .font(.callout)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 160)
            } else if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Divider()
                Text("No matches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
    }

    private func runSearch() async {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        guard model.isReady, !trimmed.isEmpty else {
            searchResults = []
            searchTotal = 0
            return
        }
        // Debounce keystrokes; the task is cancelled and restarted on each change.
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }

        var options = SearchIndex.Options()
        options.chats = model.chatRefs
        options.sort = .newest
        options.limit = 60
        let index = appState.searchIndex
        let response = await Task.detached {
            try? index.search(trimmed, options: options)
        }.value
        guard !Task.isCancelled else { return }
        searchResults = response?.results ?? []
        searchTotal = response?.total ?? 0
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
    private func scrub(to date: Date, highlight: String? = nil, terms: [String] = []) {
        let t = min(max(date.timeIntervalSinceReferenceDate, scrubLo), scrubHi)
        scrubPosition = t
        let clamped = Date(timeIntervalSinceReferenceDate: t)
        Task { await model.jump(to: clamped, highlight: highlight, terms: terms) }
    }

    /// The words of the in-conversation query, for marking them in the bubble.
    private var queryTerms: [String] {
        searchQuery.replacingOccurrences(of: "\"", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
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
                    MessageBubble(
                        message: msg,
                        highlight: msg.id == model.highlightID,
                        highlightTerms: msg.id == model.textHighlightID ? model.highlightTerms : []
                    )
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
        .background(Color.white)
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
            .tint(.sun)
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
    /// The message a search landed on: rings it in sun, which fades as the
    /// highlight clears.
    var highlight = false
    /// Search terms marked inside the bubble text; these persist after the
    /// ring fades so the mention stays findable.
    var highlightTerms: [String] = []

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 40) }
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                Text(bubbleText)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(message.isFromMe ? Color.brandBlue : Color.bubbleTan)
                    .foregroundStyle(message.isFromMe ? Color.white : Color.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.sun, lineWidth: 2.5)
                            .opacity(highlight ? 1 : 0)
                    }
                    .shadow(color: Color.sun.opacity(highlight ? 0.85 : 0), radius: 9)
                    .animation(.easeOut(duration: 0.7), value: highlight)
                Text(message.date.formatted(.dateTime.hour().minute()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !message.isFromMe { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)
    }

    /// The bubble text with every occurrence of the search terms marked in sun,
    /// matching case- and diacritic-insensitively (same spirit as the index).
    private var bubbleText: AttributedString {
        let text = message.text
        guard !highlightTerms.isEmpty else { return AttributedString(text) }

        var ranges: [Range<String.Index>] = []
        for term in highlightTerms where !term.isEmpty {
            var start = text.startIndex
            while start < text.endIndex,
                  let r = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: start..<text.endIndex) {
                ranges.append(r)
                start = r.upperBound
            }
        }
        guard !ranges.isEmpty else { return AttributedString(text) }

        // Merge overlaps (e.g. terms "birth" and "birthday") into clean runs.
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = [ranges[0]]
        for r in ranges.dropFirst() {
            let last = merged[merged.count - 1]
            if r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }

        var attr = AttributedString()
        var cursor = text.startIndex
        for r in merged {
            if cursor < r.lowerBound {
                attr += AttributedString(String(text[cursor..<r.lowerBound]))
            }
            var piece = AttributedString(String(text[r]))
            piece.backgroundColor = Color.sun
            piece.foregroundColor = Color.ink
            attr += piece
            cursor = r.upperBound
        }
        if cursor < text.endIndex {
            attr += AttributedString(String(text[cursor...]))
        }
        return attr
    }
}
