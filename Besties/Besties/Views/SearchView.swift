import SwiftUI

/// Full-content search across every indexed message, with person / time /
/// sender filters. Results open the person's conversation at that message.
struct SearchView: View {
    let appState: AppState
    let onOpen: (_ mergeKey: String, _ date: Date, _ messageID: String, _ terms: [String]) -> Void
    let onOpenGroup: (_ chatID: Int64, _ name: String, _ date: Date, _ messageID: String, _ terms: [String]) -> Void

    @State private var query = ""
    @State private var selectedPerson: PersonOption?
    @State private var timeFilter = TimeFilter.anyTime
    @State private var senderFilter = SenderFilter.anyone
    @State private var sourceFilter = SourceFilter.all
    @State private var hasAttachment = false
    @State private var hasLink = false
    @State private var sort = SearchIndex.Sort.relevance
    @State private var results: [SearchIndex.Result] = []
    @State private var totalMatches = 0
    @State private var loadingMore = false
    @State private var hasSearched = false
    @State private var showPersonPicker = false
    @State private var personQuery = ""
    @FocusState private var searchFocused: Bool

    private let pageSize = 200

    struct PersonOption: Identifiable, Hashable {
        let key: String     // mergeKey
        let name: String
        let handle: String  // busiest handle, for the avatar
        var id: String { key }
    }

    enum SenderFilter: String, CaseIterable, Identifiable {
        case anyone = "Anyone"
        case me = "Me"
        case them = "Them"
        var id: String { rawValue }
        var fromMe: Bool? {
            switch self {
            case .anyone: nil
            case .me: true
            case .them: false
            }
        }
    }

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case iMessage = "Messages"
        case whatsApp = "WhatsApp"
        var id: String { rawValue }
        var source: MessageSource? {
            switch self {
            case .all: nil
            case .iMessage: .iMessage
            case .whatsApp: .whatsApp
            }
        }
    }

    enum TimeFilter: Hashable {
        case anyTime, pastWeek, pastMonth, pastThreeMonths, pastYear
        case year(Int)

        var label: String {
            switch self {
            case .anyTime: "Any time"
            case .pastWeek: "Past week"
            case .pastMonth: "Past month"
            case .pastThreeMonths: "Past 3 months"
            case .pastYear: "Past year"
            case .year(let y): String(y)
            }
        }

        var range: (start: Date?, end: Date?) {
            let cal = Calendar.current
            switch self {
            case .anyTime: return (nil, nil)
            case .pastWeek: return (cal.date(byAdding: .day, value: -7, to: .now), nil)
            case .pastMonth: return (cal.date(byAdding: .month, value: -1, to: .now), nil)
            case .pastThreeMonths: return (cal.date(byAdding: .month, value: -3, to: .now), nil)
            case .pastYear: return (cal.date(byAdding: .year, value: -1, to: .now), nil)
            case .year(let y):
                let start = cal.date(from: DateComponents(year: y, month: 1, day: 1))
                let end = start.flatMap { cal.date(byAdding: .year, value: 1, to: $0) }
                return (start, end)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                searchBar
                filterBar
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            content
        }
        .task(id: searchSignature) { await runSearch() }
        .onAppear { searchFocused = true }
        .onChange(of: appState.searchFocusRequest) { searchFocused = true }
    }

    // MARK: - Header

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Type a keyword or phrase…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.ink.opacity(0.12)))
    }

    private var filterBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            labeled("Person") { personChip }
            labeled("When") {
                Picker("", selection: $timeFilter) {
                    Text("Any time").tag(TimeFilter.anyTime)
                    Text("Past week").tag(TimeFilter.pastWeek)
                    Text("Past month").tag(TimeFilter.pastMonth)
                    Text("Past 3 months").tag(TimeFilter.pastThreeMonths)
                    Text("Past year").tag(TimeFilter.pastYear)
                    Divider()
                    ForEach(availableYears, id: \.self) { year in
                        Text(String(year)).tag(TimeFilter.year(year))
                    }
                }
                .fixedSize()
            }

            labeled("Sender") {
                Picker("", selection: $senderFilter) {
                    ForEach(SenderFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
            }

            if whatsAppActive {
                labeled("App") {
                    Picker("", selection: $sourceFilter) {
                        ForEach(SourceFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .fixedSize()
                }
            }

            labeled("Contains") {
                Menu(contentFilterLabel) {
                    Toggle("Has attachment", isOn: $hasAttachment)
                    Toggle("Has link", isOn: $hasLink)
                }
                .fixedSize()
            }

            Spacer(minLength: 0)

            labeled("Sort") {
                Picker("", selection: $sort) {
                    ForEach(SearchIndex.Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
            }
        }
        .font(.callout)
    }

    /// A caption over each filter control so the row reads at a glance —
    /// an unfiltered chip otherwise just says "Anyone"/"Any time".
    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            content()
        }
    }

    /// The extras menu names what it's doing, so an active filter is visible
    /// without opening it.
    private var contentFilterLabel: String {
        switch (hasAttachment, hasLink) {
        case (false, false): "Anything"
        case (true, false): "Has attachment"
        case (false, true): "Has link"
        case (true, true): "Attachment + link"
        }
    }

    private var personChip: some View {
        Button {
            personQuery = ""
            showPersonPicker = true
        } label: {
            HStack(spacing: 4) {
                Text(selectedPerson?.name ?? "Anyone")
                    .lineLimit(1)
                if selectedPerson != nil {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .onTapGesture { selectedPerson = nil }
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 180, alignment: .leading)
        .popover(isPresented: $showPersonPicker, arrowEdge: .bottom) {
            personPicker
        }
    }

    private var personPicker: some View {
        VStack(spacing: 0) {
            TextField("Filter by name", text: $personQuery)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredPeople) { person in
                        Button {
                            selectedPerson = person
                            showPersonPicker = false
                        } label: {
                            HStack(spacing: 8) {
                                AvatarView(
                                    name: person.name,
                                    imageData: appState.avatar(forHandle: person.handle),
                                    color: leaderboardColor,
                                    size: 22
                                )
                                Text(person.name)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(width: 240, height: 300)
    }

    // MARK: - Results

    @ViewBuilder
    private var content: some View {
        if let progress = appState.searchProgress, progress.total > 20_000, appState.searchIndexedCount == 0 {
            VStack(spacing: 10) {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .frame(maxWidth: 260)
                Text("Indexing your messages…")
                    .font(.title3.weight(.semibold))
                Text("\(progress.done.formatted()) of \(progress.total.formatted()) — only happens once.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasSearched {
            VStack(spacing: 6) {
                Text("Search everything you've ever texted.")
                    .font(.title2.weight(.semibold))
                if appState.searchIndexedCount > 0 {
                    Text("\(appState.searchIndexedCount.formatted()) messages, ready to search.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            Text("No matches.")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                Text(matchCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                ForEach(results) { result in
                    SearchResultRow(
                        result: result,
                        display: displayInfo(for: result),
                        onOpen: { key, date, id in onOpen(key, date, id, queryTerms) },
                        onOpenGroup: { chatID, name, date, id in onOpenGroup(chatID, name, date, id, queryTerms) }
                    )
                }
                if results.count < totalMatches {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        Text(loadingMore ? "Loading…" : "Show \(min(pageSize, totalMatches - results.count).formatted()) more")
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.bubbleTan, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(loadingMore)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private var matchCountLabel: String {
        totalMatches > results.count
            ? "\(totalMatches.formatted()) matches · showing \(results.count.formatted())"
            : "\(totalMatches.formatted()) \(totalMatches == 1 ? "match" : "matches")"
    }

    // MARK: - Lookup

    struct DisplayInfo {
        let name: String
        let avatar: Data?
        let mergeKey: String?    // nil = not a person; a group chat or unknown
        var groupChatID: Int64?  // set on group chats, which open by chat id
    }

    private func displayInfo(for result: SearchIndex.Result) -> DisplayInfo {
        if result.source == .whatsApp {
            // WhatsApp chat ids are session Z_PKs, and only 1:1 sessions are indexed.
            guard let convo = appState.whatsAppConvoBySessionID[result.chatID] else {
                return DisplayInfo(name: "Unknown", avatar: nil, mergeKey: nil)
            }
            return DisplayInfo(name: convo.resolvedName, avatar: appState.avatar(forHandle: convo.handle), mergeKey: convo.mergeKey)
        }
        guard let info = appState.chatInfoByID[result.chatID] else {
            return DisplayInfo(name: "Unknown", avatar: nil, mergeKey: nil)
        }
        if info.isGroup {
            return DisplayInfo(name: info.displayName ?? "Group chat", avatar: nil, mergeKey: nil, groupChatID: info.chatID)
        }
        guard let handleID = info.handleID,
              let convo = appState.iMessageConvoByHandleID[handleID] else {
            return DisplayInfo(name: info.displayName ?? "Unknown", avatar: nil, mergeKey: nil)
        }
        return DisplayInfo(name: convo.resolvedName, avatar: appState.avatar(forHandle: convo.handle), mergeKey: convo.mergeKey)
    }

    private var people: [PersonOption] {
        var merged: [String: (name: String, handle: String, count: Int, topCount: Int)] = [:]
        for convo in appState.allConversations {
            var agg = merged[convo.mergeKey] ?? (convo.resolvedName, convo.handle, 0, -1)
            agg.count += convo.totalMessages
            if convo.totalMessages > agg.topCount {
                agg.topCount = convo.totalMessages
                agg.name = convo.resolvedName
                agg.handle = convo.handle
            }
            merged[convo.mergeKey] = agg
        }
        return merged
            .sorted { $0.value.count > $1.value.count }
            .map { PersonOption(key: $0.key, name: $0.value.name, handle: $0.value.handle) }
    }

    private var filteredPeople: [PersonOption] {
        let q = personQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return people }
        return people.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var availableYears: [Int] {
        let firstYear = appState.allConversations.map(\.firstMessageDate).min()
            .map { Calendar.current.component(.year, from: $0) }
        guard let firstYear else { return [] }
        let currentYear = Calendar.current.component(.year, from: .now)
        return Array((firstYear...max(firstYear, currentYear)).reversed())
    }

    // MARK: - Search execution

    /// WhatsApp messages are always indexed; whether they show up is the
    /// setting's call, so results refresh when it's flipped.
    private var whatsAppActive: Bool {
        appState.whatsAppInstalled && appState.whatsAppEnabled
    }

    private var searchSignature: String {
        "\(query)|\(selectedPerson?.key ?? "")|\(timeFilter)|\(senderFilter.rawValue)|\(sourceFilter.rawValue)|\(whatsAppActive)|\(hasAttachment)|\(hasLink)|\(sort.rawValue)"
    }

    /// The words of the current query, for highlighting matches in the reader.
    private var queryTerms: [String] {
        query.replacingOccurrences(of: "\"", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            totalMatches = 0
            hasSearched = false
            return
        }
        // Debounce keystrokes; the task is cancelled and restarted on each change.
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }

        let response = await fetch(offset: 0)
        guard !Task.isCancelled else { return }
        results = response?.results ?? []
        totalMatches = response?.total ?? 0
        hasSearched = true
    }

    /// Next page, appended. Every sort order is fully ordered, so paging by
    /// offset can't repeat or skip a result.
    private func loadMore() async {
        guard !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let signature = searchSignature
        guard let response = await fetch(offset: results.count),
              signature == searchSignature else { return }   // filters changed mid-fetch
        results += response.results
        totalMatches = response.total
    }

    private func fetch(offset: Int) async -> (results: [SearchIndex.Result], total: Int)? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var options = SearchIndex.Options()
        if let person = selectedPerson {
            let convos = appState.resolvedConversations.filter { $0.mergeKey == person.key }
            let handleIDs = Set(convos.filter { $0.source == .iMessage }.map(\.rowID))
            options.chats = appState.chatInfoByID.values
                .filter { !$0.isGroup && $0.handleID.map(handleIDs.contains) == true }
                .map { SearchIndex.ChatRef(source: .iMessage, id: $0.chatID) }
                + convos.filter { $0.source == .whatsApp }
                    .map { SearchIndex.ChatRef(source: .whatsApp, id: $0.rowID) }
        }
        options.source = whatsAppActive ? sourceFilter.source : .iMessage
        (options.startDate, options.endDate) = timeFilter.range
        options.fromMe = senderFilter.fromMe
        options.hasAttachment = hasAttachment
        options.hasLink = hasLink
        options.sort = sort
        options.limit = pageSize
        options.offset = offset

        let index = appState.searchIndex
        return await Task.detached {
            try? index.search(trimmed, options: options)
        }.value
    }
}

/// The FTS snippet with matched terms sun-highlighted, prefixed with "You:"
/// on sent messages. Shared with the reader's in-conversation search.
func searchSnippetText(_ snippet: String, isFromMe: Bool) -> AttributedString {
    var attr = AttributedString()
    if isFromMe {
        var you = AttributedString("You: ")
        you.foregroundColor = .secondary
        attr += you
    }
    var buffer = ""
    var inMatch = false
    func flush() {
        guard !buffer.isEmpty else { return }
        var piece = AttributedString(buffer)
        if inMatch {
            piece.backgroundColor = Color.sun.opacity(0.45)
            piece.foregroundColor = Color.ink
            piece.font = .callout.weight(.semibold)
        }
        attr += piece
        buffer = ""
    }
    for char in snippet {
        switch String(char) {
        case SearchIndex.markStart: flush(); inMatch = true
        case SearchIndex.markEnd: flush(); inMatch = false
        default: buffer.append(char)
        }
    }
    flush()
    return attr
}

struct SearchResultRow: View {
    let result: SearchIndex.Result
    let display: SearchView.DisplayInfo
    let onOpen: (_ mergeKey: String, _ date: Date, _ messageID: String) -> Void
    let onOpenGroup: (_ chatID: Int64, _ name: String, _ date: Date, _ messageID: String) -> Void

    var body: some View {
        Button {
            if let key = display.mergeKey {
                onOpen(key, result.date, result.id)
            } else if let chatID = display.groupChatID {
                onOpenGroup(chatID, display.name, result.date, result.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(display.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(result.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Text(searchSnippetText(result.snippet, isFromMe: result.isFromMe))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(display.mergeKey == nil && display.groupChatID == nil)
    }

    @ViewBuilder
    private var avatar: some View {
        if display.mergeKey == nil {
            ZStack {
                Circle().fill(Color.bubbleTan)
                Image(systemName: "person.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 30, height: 30)
        } else {
            AvatarView(
                name: display.name,
                imageData: display.avatar,
                color: leaderboardColor,
                size: 30
            )
        }
    }

}
