import SwiftUI
import Charts

enum Tab: String, CaseIterable {
    case allTime = "All Time"
    case timeMachine = "Time Machine"
    case reconnect = "Reconnect"
    case search = "Search"

    var systemImage: String {
        switch self {
        case .allTime: "trophy.fill"
        case .timeMachine: "clock.arrow.circlepath"
        case .reconnect: "bubble.left.and.bubble.right.fill"
        case .search: "magnifyingglass"
        }
    }

    /// One-line description shown inside the tab, under the title.
    var blurb: String {
        switch self {
        case .allTime: "Your lifetime leaderboard"
        case .timeMachine: "Rewind month by month"
        case .reconnect: "Who's worth a text"
        case .search: "Find any message by keyword"
        }
    }
}

/// The full-width tab bar: icon + title with a one-line description inside
/// each tab, on a flat gray track, sun pill sliding to the selection.
/// Descriptions drop at narrow widths so the titles never truncate.
struct TabBar: View {
    @Binding var selection: Tab
    var showDescriptions = true
    @Namespace private var pillNS
    @State private var hovered: Tab?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    if reduceMotion {
                        selection = tab
                    } else {
                        withAnimation(.spring(duration: 0.28)) { selection = tab }
                    }
                } label: {
                    VStack(spacing: 1) {
                        HStack(spacing: 5) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 12, weight: .semibold))
                            Text(tab.rawValue)
                                .font(.callout.weight(.semibold))
                        }
                        if showDescriptions {
                            Text(tab.blurb)
                                .font(.caption2)
                                .foregroundStyle(Color.ink.opacity(selection == tab ? 0.72 : 0.45))
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(selection == tab ? Color.ink : Color.ink.opacity(0.55))
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color.sun)
                                .matchedGeometryEffect(id: "pill", in: pillNS)
                        } else if hovered == tab {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color.ink.opacity(0.055))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hovered = tab } else if hovered == tab { hovered = nil }
                }
            }
        }
        .padding(3)
        .background(Color.ink.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
    }
}


enum TimeRange: Int, CaseIterable, Identifiable {
    case oneWeek = 7
    case twoWeeks = 14
    case oneMonth = 30
    case twoMonths = 60
    case threeMonths = 90
    case sixMonths = 183
    case oneYear = 365
    case twoYears = 730
    case threeYears = 1095
    case fourYears = 1460
    case fiveYears = 1825
    case tenYears = 3650

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .oneWeek: "1 week"
        case .twoWeeks: "2 weeks"
        case .oneMonth: "1 month"
        case .twoMonths: "2 months"
        case .threeMonths: "3 months"
        case .sixMonths: "6 months"
        case .oneYear: "1 year"
        case .twoYears: "2 years"
        case .threeYears: "3 years"
        case .fourYears: "4 years"
        case .fiveYears: "5 years"
        case .tenYears: "10 years"
        }
    }
}

struct ContentView: View {
    let appState: AppState
    @State private var selectedTab = Tab.allTime
    @State private var selectedRange = TimeRange.sixMonths
    @State private var monthPosition: Double = 0
    @State private var showChart = true
    @State private var readerTarget: ReaderTarget?
    @State private var searchText = ""
    @State private var headerWidth: CGFloat = 0
    @State private var sortOrder = [KeyPathComparator(\Conversation.score, order: .reverse)]

    private static let searchFieldWidth: CGFloat = 220

    /// The people filter, right-aligned directly above whichever list it filters.
    private var filterRow: some View {
        HStack {
            Spacer(minLength: 0)
            searchField
                .frame(width: Self.searchFieldWidth)
        }
        .padding(.horizontal, 16)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
            TextField("Filter people…", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var filteredReconnect: [Conversation] {
        appState.reconnectConversations(maxDays: selectedRange.rawValue)
            .filter(matchesSearch)
            .sorted(using: sortOrder)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Matches by name or handle; digit-only comparison lets "555-1234"
    /// find "+15551234".
    private func matchesSearch(_ convo: Conversation) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        if convo.resolvedName.localizedCaseInsensitiveContains(query) { return true }
        if convo.handle.localizedCaseInsensitiveContains(query) { return true }
        let queryDigits = query.filter(\.isNumber)
        return !queryDigits.isEmpty && convo.handle.filter(\.isNumber).contains(queryDigits)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                TabBar(selection: $selectedTab, showDescriptions: headerWidth == 0 || headerWidth >= 560)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerWidth = $0 }

            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Group {
                if appState.isLoading {
                    ProgressView("Reading your messages…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = appState.error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(error)
                            .foregroundStyle(.secondary)
                        Button("Retry") { appState.loadConversations() }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch selectedTab {
                    case .reconnect:
                        VStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Text("Last Contact:")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $selectedRange) {
                                    ForEach(TimeRange.allCases) { range in
                                        Text(range.label).tag(range)
                                    }
                                }
                                .fixedSize()
                                Spacer(minLength: 0)
                                searchField
                                    .frame(width: Self.searchFieldWidth)
                            }
                            .padding(.horizontal, 16)
                            if filteredReconnect.isEmpty {
                                Text(isSearching ? "No matches." : "No one to reconnect with right now.")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                reconnectTable
                            }
                        }
                    case .allTime:
                        if appState.allConversations.isEmpty {
                            Text("No conversations found.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            allTimeView
                        }
                    case .timeMachine:
                        if appState.timelineLoading {
                            ProgressView("Reading your messages…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if appState.timelineMonths.isEmpty {
                            Text("No conversations found.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            timelineView
                        }
                    case .search:
                        SearchView(
                            appState: appState,
                            onOpen: { key, date, messageID, terms in
                                openReader(key: key, anchorDate: date, anchorMessageID: messageID, highlightTerms: terms)
                            },
                            onOpenGroup: { chatID, name, date, messageID, terms in
                                openGroupReader(chatID: chatID, name: name, anchorDate: date, anchorMessageID: messageID, highlightTerms: terms)
                            }
                        )
                    }
                }
            }
        }
        .task(id: "\(selectedTab.rawValue)-\(appState.isLoading)") {
            if selectedTab != .reconnect && !appState.isLoading {
                appState.loadTimeline()
            }
        }
        .onChange(of: appState.timelineMonths) {
            monthPosition = Double(max(appState.timelineMonths.count - 1, 0))
        }
        .onChange(of: appState.searchFocusRequest) { selectedTab = .search }
        .onChange(of: appState.requestedTab) {
            if let tab = appState.requestedTab {
                selectedTab = tab
                appState.requestedTab = nil
            }
        }
        .sheet(item: $readerTarget) { target in
            ConversationReaderView(target: target, appState: appState)
                .frame(minWidth: 480, idealWidth: 560, minHeight: 560, idealHeight: 680)
        }
    }

    /// Opens the person view. In Time Machine we land on the selected month,
    /// from Search on the matched message; elsewhere on their most recent message.
    private func openReader(key: String, monthKey: String? = nil, anchorDate: Date? = nil, anchorMessageID: String? = nil, highlightTerms: [String] = []) {
        let convos = appState.resolvedConversations.filter { $0.mergeKey == key }
        guard let busiest = convos.max(by: { $0.totalMessages < $1.totalMessages }) else { return }
        let first = convos.map(\.firstMessageDate).min() ?? .now
        let last = convos.map(\.lastMessageDate).max() ?? .now
        let anchor = anchorDate ?? monthKey.flatMap(Self.monthKeyParser.date(from:)) ?? last
        readerTarget = ReaderTarget(
            key: key,
            name: busiest.resolvedName,
            handle: busiest.handle,
            imessageHandleIDs: convos.filter { $0.source == .iMessage }.map(\.rowID),
            whatsAppChatIDs: convos.filter { $0.source == .whatsApp }.map(\.rowID),
            anchorDate: anchor,
            anchorMessageID: anchorMessageID,
            highlightTerms: highlightTerms,
            firstDate: first,
            lastDate: last,
            totalMessages: convos.reduce(0) { $0 + $1.totalMessages },
            sentMessages: convos.reduce(0) { $0 + $1.sentMessages },
            receivedMessages: convos.reduce(0) { $0 + $1.receivedMessages }
        )
    }

    /// Opens a group chat from Search. Group chats aren't part of the
    /// person-level aggregates, so its totals are read on the spot.
    private func openGroupReader(chatID: Int64, name: String, anchorDate: Date, anchorMessageID: String, highlightTerms: [String] = []) {
        Task {
            let stats = await Task.detached {
                try? MessageStore().fetchChatStats(chatID: chatID)
            }.value
            guard let stats else { return }
            readerTarget = ReaderTarget(
                key: "chat:\(chatID)",
                name: name,
                handle: "",
                imessageHandleIDs: [],
                imessageChatIDs: [chatID],
                whatsAppChatIDs: [],
                anchorDate: anchorDate,
                anchorMessageID: anchorMessageID,
                highlightTerms: highlightTerms,
                firstDate: stats.first,
                lastDate: stats.last,
                totalMessages: stats.total,
                sentMessages: stats.sent,
                receivedMessages: stats.total - stats.sent
            )
        }
    }

    private var currentMonthIndex: Int {
        min(max(Int(monthPosition.rounded()), 0), max(appState.timelineMonths.count - 1, 0))
    }

    private var selectedMonthKey: String? {
        let months = appState.timelineMonths
        guard !months.isEmpty else { return nil }
        return months[currentMonthIndex]
    }

    private var monthConversations: [Conversation] {
        (selectedMonthKey.flatMap { appState.monthlyConversations[$0] } ?? []).filter(matchesSearch)
    }

    private var currentPeopleCount: Int {
        appState.peoplePerMonth.indices.contains(currentMonthIndex)
            ? appState.peoplePerMonth[currentMonthIndex] : 0
    }

    private var currentSentCount: Int {
        appState.sentPerMonth.indices.contains(currentMonthIndex)
            ? appState.sentPerMonth[currentMonthIndex] : 0
    }

    /// Groups conversations by person (merging iMessage + SMS + WhatsApp via
    /// mergeKey), sorted by message count descending. Each entry keeps the
    /// name, handle, and source of its busiest conversation for the label,
    /// avatar, and message button.
    private func mergedEntries(_ conversations: [Conversation]) -> [(key: String, name: String, count: Int, handle: String, source: MessageSource)] {
        var merged: [String: (name: String, count: Int, handle: String, source: MessageSource, topCount: Int)] = [:]
        for convo in conversations {
            var agg = merged[convo.mergeKey] ?? (convo.resolvedName, 0, convo.handle, convo.source, -1)
            agg.count += convo.totalMessages
            if convo.totalMessages > agg.topCount {
                agg.topCount = convo.totalMessages
                agg.name = convo.resolvedName
                agg.handle = convo.handle
                agg.source = convo.source
            }
            merged[convo.mergeKey] = agg
        }
        return merged
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.value.name < $1.value.name }
            .map { (key: $0.key, name: $0.value.name, count: $0.value.count, handle: $0.value.handle, source: $0.value.source) }
    }

    private var monthTopFive: [RaceEntry] {
        mergedEntries(monthConversations)
            .prefix(5)
            .map { RaceEntry(key: $0.key, name: $0.name, count: $0.count, avatar: appState.avatar(forHandle: $0.handle)) }
    }

    private func leaderboardRows(_ entries: [(key: String, name: String, count: Int, handle: String, source: MessageSource)], monthKey: String? = nil) -> some View {
        let maxCount = Double(max(entries.first?.count ?? 1, 1))
        return LazyVStack(spacing: 8) {
            ForEach(Array(entries.enumerated()), id: \.element.key) { index, entry in
                LeaderboardRow(
                    rank: index + 1,
                    name: entry.name,
                    count: entry.count,
                    avatar: appState.avatar(forHandle: entry.handle),
                    fraction: Double(entry.count) / maxCount,
                    onMessage: { openInMessages(handle: entry.handle, source: entry.source) },
                    onOpen: { openReader(key: entry.key, monthKey: monthKey) }
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func leaderboardList(_ conversations: [Conversation], monthKey: String? = nil) -> some View {
        ScrollView { leaderboardRows(mergedEntries(conversations), monthKey: monthKey) }
    }

    private var allTimeView: some View {
        let entries = mergedEntries(appState.allConversations.filter(matchesSearch))
        return ScrollView {
            VStack(spacing: 16) {
                AllTimeKPIView(appState: appState)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                if !appState.sentPerMonth.isEmpty {
                    HStack(spacing: 16) {
                        TrendChartView(
                            title: "People you texted",
                            values: appState.peoplePerMonth,
                            months: appState.timelineMonths,
                            color: .blue
                        )
                        TrendChartView(
                            title: "Messages you sent",
                            values: appState.sentPerMonth,
                            months: appState.timelineMonths,
                            color: .green
                        )
                    }
                    .padding(.horizontal, 16)
                }

                filterRow
                    .padding(.bottom, -8)

                if entries.isEmpty && isSearching {
                    Text("No matches.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                } else {
                    leaderboardRows(entries)
                }
            }
        }
    }

    private static let monthKeyParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private func monthLabel(_ key: String) -> String {
        guard let date = Self.monthKeyParser.date(from: key) else { return key }
        return date.formatted(.dateTime.month(.wide).year())
    }

    private var reconnectTable: some View {
        Table(filteredReconnect, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.resolvedName, comparator: .localizedStandard) { convo in
                HStack(spacing: 10) {
                    AvatarView(
                        name: convo.resolvedName,
                        imageData: appState.avatar(forHandle: convo.handle),
                        color: leaderboardColor,
                        size: 28
                    )
                    Text(convo.resolvedName)
                }
                .contentShape(Rectangle())
                .onTapGesture { openReader(key: convo.mergeKey) }
            }
            .width(min: 120)

            TableColumn("Last Message", value: \.daysSinceLastMessage) { convo in
                Text("\(convo.daysSinceLastMessage)d ago")
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 70, max: 90)

            TableColumn("Messages", value: \.totalMessages) { convo in
                Text("\(convo.totalMessages)")
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 60, max: 75)

            TableColumn("Score", value: \.score) { convo in
                ScoreCell(score: convo.score, breakdown: convo.scoreBreakdown)
            }
            .width(min: 40, ideal: 40, max: 50)

            TableColumn("") { convo in
                Button {
                    openInMessages(handle: convo.handle, source: convo.source)
                } label: {
                    Image(systemName: "bubble.left.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .width(30)
        }
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .background(Color.paper)
    }

    private var timelineView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                ZStack {
                    VStack(spacing: 1) {
                        Text(selectedMonthKey.map(monthLabel) ?? "")
                            .font(.headline)
                        Text("\(currentPeopleCount) people · \(currentSentCount) messages sent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Slider(
                    value: $monthPosition,
                    in: 0...Double(max(appState.timelineMonths.count - 1, 1)),
                    step: 1
                )
                .tint(.sun)
                HStack {
                    Text(appState.timelineMonths.first.map(monthLabel) ?? "")
                    Spacer()
                    Text("Now")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            filterRow
                .padding(.bottom, 8)

            if monthConversations.isEmpty {
                Text(isSearching ? "No matches." : "No conversations this month.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                leaderboardList(monthConversations, monthKey: selectedMonthKey)
            }
        }
    }

    private func openInMessages(handle: String, source: MessageSource) {
        if source == .whatsApp {
            if let url = URL(string: "whatsapp://send?phone=\(handle.filter(\.isNumber))") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let cleaned = handle.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? handle
        if let url = URL(string: "imessage://\(cleaned)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct KPICard: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.ink.opacity(0.08)))
    }
}

struct AllTimeKPIView: View {
    let appState: AppState

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                KPICard(value: card.value, label: card.label)
            }
        }
    }

    private var cards: [(value: String, label: String)] {
        let convos = appState.allConversations
        let sent = convos.reduce(0) { $0 + $1.sentMessages }
        let received = convos.reduce(0) { $0 + $1.receivedMessages }
        let total = sent + received

        // Merge each person's handles into combined sent/received totals.
        var byPerson: [String: (sent: Int, received: Int)] = [:]
        for c in convos {
            var e = byPerson[c.mergeKey] ?? (0, 0)
            e.sent += c.sentMessages
            e.received += c.receivedMessages
            byPerson[c.mergeKey] = e
        }
        let people = byPerson.count
        let avg = people > 0 ? total / people : 0
        let sentShare = total > 0 ? Int((Double(sent) / Double(total) * 100).rounded()) : 0

        var result: [(value: String, label: String)] = [
            (total.formatted(), "Total messages"),
            ("\(sentShare)%", "Share you sent"),
            (people.formatted(), "People messaged"),
            (avg.formatted(), "Avg per person"),
        ]

        // Monthly-derived (available once the timeline finishes loading).
        if !appState.sentPerMonth.isEmpty {
            var byYear: [String: Int] = [:]
            for (i, month) in appState.timelineMonths.enumerated() where i < appState.sentPerMonth.count {
                byYear[String(month.prefix(4)), default: 0] += appState.sentPerMonth[i]
            }
            if let busiestYear = byYear.max(by: { $0.value < $1.value })?.key {
                result.append((busiestYear, "Busiest year"))
            }
            if let peakIndex = appState.sentPerMonth.indices.max(by: { appState.sentPerMonth[$0] < appState.sentPerMonth[$1] }),
               appState.timelineMonths.indices.contains(peakIndex),
               let date = Self.monthParser.date(from: appState.timelineMonths[peakIndex]) {
                result.append((date.formatted(.dateTime.month(.abbreviated).year()), "Busiest month"))
            }
        }

        // Message-level stats (available once global stats finish loading).
        let g = appState.globalStats
        let sentTotal = g.sentHourCounts.reduce(0, +)
        if sentTotal > 0 {
            let nightOwl = (0..<5).reduce(0) { $0 + g.sentHourCounts[$1] }
            result.append(("\(Int((Double(nightOwl) / Double(sentTotal) * 100).rounded()))%", "Night-owl share"))
        }

        return result
    }

    private static let monthParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f
    }()
}

struct TrendChartView: View {
    let title: String
    let values: [Int]
    let months: [String]
    let color: Color

    private var yearTicks: [Int] {
        months.indices.filter { months[$0].hasSuffix("-01") }
    }

    /// Thins year ticks to what fits the current chart width without overlap.
    private func tickValues(for width: CGFloat) -> [Int] {
        let ticks = yearTicks
        guard !ticks.isEmpty else { return [] }
        let maxLabels = max(Int(width / 48), 1)
        let strideBy = max(Int((Double(ticks.count) / Double(maxLabels)).rounded(.up)), 1)
        return stride(from: 0, to: ticks.count, by: strideBy).map { ticks[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                chart(tickValues: tickValues(for: geo.size.width))
            }
            .frame(height: 100)
        }
    }

    private func chart(tickValues: [Int]) -> some View {
        Chart {
                ForEach(values.indices, id: \.self) { index in
                    AreaMark(
                        x: .value("Month", index),
                        y: .value("Value", values[index])
                    )
                    .foregroundStyle(color.opacity(0.12))
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("Month", index),
                        y: .value("Value", values[index])
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                }
            }
            .chartXAxis {
                AxisMarks(values: tickValues) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let index = value.as(Int.self), months.indices.contains(index) {
                            Text(String(months[index].prefix(4)))
                        }
                    }
                }
            }
    }
}

struct RaceEntry: Identifiable {
    var id: String { key }
    let key: String
    let name: String
    let count: Int
    let avatar: Data?
}

private let personPalette: [Color] = [.purple, .teal, .orange, .pink, .blue, .green, .red, .indigo]

private func personColor(for name: String) -> Color {
    let hash = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
    return personPalette[hash % personPalette.count]
}

struct PodiumView: View {
    let entries: [RaceEntry]
    var onOpen: ((RaceEntry) -> Void)? = nil

    private static let sizes: [CGFloat] = [56, 48, 40, 34, 30]

    private var arranged: [(rank: Int, entry: RaceEntry)] {
        Array(entries.prefix(Self.sizes.count).enumerated()).map { ($0.offset, $0.element) }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(arranged, id: \.entry.id) { item in
                VStack(spacing: 3) {
                    if item.rank == 0 {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.sun)
                    }
                    AvatarView(
                        name: item.entry.name,
                        imageData: item.entry.avatar,
                        color: personColor(for: item.entry.name),
                        size: Self.sizes[item.rank]
                    )
                    Text(item.entry.name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\(item.entry.count)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { onOpen?(item.entry) }
            }
        }
    }
}

let leaderboardColor = Color.brandBlue

struct LeaderboardRow: View {
    let rank: Int
    let name: String
    let count: Int
    let avatar: Data?
    let fraction: Double
    let onMessage: () -> Void
    var onOpen: (() -> Void)? = nil

    /// Only the top three are enlarged; every column keeps a constant width so
    /// the avatars, names, and bars align like a table across all rows.
    private var avatarSize: CGFloat {
        switch rank {
        case 1: 46
        case 2: 40
        case 3: 34
        default: 28
        }
    }
    private var nameFontSize: CGFloat {
        switch rank {
        case 1: 15.5
        case 2: 14.5
        case 3: 13.5
        default: 12
        }
    }
    private var barHeight: CGFloat { rank <= 3 ? 26 : 22 }

    /// Fixed column widths, independent of rank.
    private static let rankColumn: CGFloat = 26
    private static let avatarColumn: CGFloat = 46
    private static let nameColumn: CGFloat = 160

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                rankBadge
                    .frame(width: Self.rankColumn, alignment: .trailing)
                AvatarView(name: name, imageData: avatar, color: leaderboardColor, size: avatarSize)
                    .frame(width: Self.avatarColumn)
                Text(name)
                    .font(.system(size: nameFontSize, weight: rank <= 3 ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: Self.nameColumn, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(leaderboardColor.opacity(0.12))
                        RoundedRectangle(cornerRadius: 5)
                            .fill(leaderboardColor)
                            .frame(width: max(geo.size.width * CGFloat(fraction), 4))
                    }
                }
                .frame(height: barHeight)
                Text("\(count)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen?() }
            Button(action: onMessage) {
                Image(systemName: "bubble.left.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    /// Gold/silver/bronze medal for the top three, plain number below.
    @ViewBuilder
    private var rankBadge: some View {
        if let medal = Medal(rank: rank) {
            let diameter = max(20, avatarSize * 0.48)
            Text("\(rank)")
                .font(.system(size: diameter * 0.55, weight: .heavy))
                .foregroundStyle(medal.text)
                .frame(width: diameter, height: diameter)
                .background(
                    LinearGradient(colors: medal.fill, startPoint: .top, endPoint: .bottom),
                    in: Circle()
                )
                .shadow(color: Color.ink.opacity(0.25), radius: 1, y: 1)
        } else {
            Text("\(rank)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private struct Medal {
        let fill: [Color]
        let text: Color

        init?(rank: Int) {
            switch rank {
            case 1: fill = [Color(red: 1, green: 0.85, blue: 0.45), Color(red: 0.91, green: 0.66, blue: 0.13)]
                    text = Color(red: 0.42, green: 0.30, blue: 0)
            case 2: fill = [Color(red: 0.91, green: 0.92, blue: 0.93), Color(red: 0.68, green: 0.71, blue: 0.75)]
                    text = Color(red: 0.29, green: 0.31, blue: 0.35)
            case 3: fill = [Color(red: 0.89, green: 0.66, blue: 0.47), Color(red: 0.71, green: 0.45, blue: 0.25)]
                    text = Color(red: 0.37, green: 0.23, blue: 0.11)
            default: return nil
            }
        }
    }
}

struct AvatarView: View {
    let name: String
    let imageData: Data?
    let color: Color
    let size: CGFloat

    var body: some View {
        Group {
            if let data = imageData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(color.opacity(0.2))
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(color)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(color, lineWidth: 1.5))
    }

    private var initials: String {
        let parts = name.split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? ""
        let last = parts.dropFirst().first?.first.map(String.init) ?? ""
        let combined = first + last
        return combined.isEmpty ? "?" : combined
    }
}

struct ScoreCell: View {
    let score: Double
    let breakdown: ScoreBreakdown?
    @State private var showPopover = false

    var body: some View {
        Text("\(Int(score))")
            .bold()
            .monospacedDigit()
            .foregroundStyle(.blue)
            .onHover { inside in
                if inside {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onTapGesture { showPopover.toggle() }
            .popover(isPresented: $showPopover, arrowEdge: .leading) {
                if let b = breakdown {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Score Breakdown")
                            .font(.headline)
                        Divider()
                        row("Dormancy", b.dormancy)
                        row("Messages", b.totalMessages)
                        row("Frequency", b.frequency)
                        row("Reciprocity", b.reciprocity)
                        row("Direction", b.direction)
                        Divider()
                        HStack {
                            Text("Total").bold()
                            Spacer()
                            Text("\(Int(score))").bold()
                        }
                    }
                    .padding(12)
                    .frame(width: 200)
                }
            }
    }

    private func row(_ label: String, _ value: Double) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.1f", value))
                .monospacedDigit()
        }
        .font(.callout)
    }
}
