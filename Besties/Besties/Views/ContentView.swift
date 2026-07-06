import SwiftUI
import Charts

enum Tab: String, CaseIterable {
    case allTime = "All Time"
    case reconnect = "Reconnect"
    case timeMachine = "Time Machine"
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

    private var filteredReconnect: [Conversation] {
        appState.reconnectConversations(maxDays: selectedRange.rawValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                switch selectedTab {
                case .reconnect:
                    Text("People you used to talk to all the time — ranked by who's most worth a text.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 6) {
                        Text("Last Contact:")
                            .foregroundStyle(.secondary)
                        Picker("", selection: $selectedRange) {
                            ForEach(TimeRange.allCases) { range in
                                Text(range.label).tag(range)
                            }
                        }
                        .fixedSize()
                    }
                case .timeMachine:
                    Text("Drag through your history to see who you were texting, month by month.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                case .allTime:
                    EmptyView()
                }
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
                        if filteredReconnect.isEmpty {
                            Text("No one to reconnect with right now.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            reconnectTable
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
        selectedMonthKey.flatMap { appState.monthlyConversations[$0] } ?? []
    }

    private var currentPeopleCount: Int {
        appState.peoplePerMonth.indices.contains(currentMonthIndex)
            ? appState.peoplePerMonth[currentMonthIndex] : 0
    }

    private var currentSentCount: Int {
        appState.sentPerMonth.indices.contains(currentMonthIndex)
            ? appState.sentPerMonth[currentMonthIndex] : 0
    }

    /// Groups conversations by resolved name (merging a person's iMessage + SMS
    /// handles), sorted by message count descending. Each entry keeps the handle
    /// of its busiest conversation for the avatar and Messages button.
    private func mergedEntries(_ conversations: [Conversation]) -> [(name: String, count: Int, handle: String)] {
        var merged: [String: (count: Int, handle: String, topCount: Int)] = [:]
        for convo in conversations {
            var agg = merged[convo.resolvedName] ?? (0, convo.handle, -1)
            agg.count += convo.totalMessages
            if convo.totalMessages > agg.topCount {
                agg.topCount = convo.totalMessages
                agg.handle = convo.handle
            }
            merged[convo.resolvedName] = agg
        }
        return merged
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            .map { (name: $0.key, count: $0.value.count, handle: $0.value.handle) }
    }

    private var monthTopFive: [RaceEntry] {
        mergedEntries(monthConversations)
            .prefix(5)
            .map { RaceEntry(name: $0.name, count: $0.count, avatar: appState.avatar(forHandle: $0.handle)) }
    }

    private func leaderboardRows(_ entries: [(name: String, count: Int, handle: String)]) -> some View {
        let maxCount = Double(max(entries.first?.count ?? 1, 1))
        return LazyVStack(spacing: 8) {
            ForEach(entries, id: \.name) { entry in
                LeaderboardRow(
                    name: entry.name,
                    count: entry.count,
                    avatar: appState.avatar(forHandle: entry.handle),
                    fraction: Double(entry.count) / maxCount,
                    onMessage: { openInMessages(handle: entry.handle) }
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func leaderboardList(_ conversations: [Conversation]) -> some View {
        ScrollView { leaderboardRows(mergedEntries(conversations)) }
    }

    private var allTimeView: some View {
        let entries = mergedEntries(appState.allConversations)
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

                leaderboardRows(entries)
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
        Table(filteredReconnect) {
            TableColumn("Name") { convo in
                Text(convo.resolvedName)
            }
            .width(min: 120)

            TableColumn("Last Message") { convo in
                Text("\(convo.daysSinceLastMessage)d ago")
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 70, max: 90)

            TableColumn("Messages") { convo in
                Text("\(convo.totalMessages)")
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 60, max: 75)

            TableColumn("Score") { convo in
                ScoreCell(score: convo.score, breakdown: convo.scoreBreakdown)
            }
            .width(min: 40, ideal: 40, max: 50)

            TableColumn("") { convo in
                Button {
                    openInMessages(handle: convo.handle)
                } label: {
                    Image(systemName: "bubble.left.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .width(30)
        }
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
                    HStack {
                        Spacer()
                        Toggle(isOn: $showChart) {
                            Image(systemName: "chart.xyaxis.line")
                        }
                        .toggleStyle(.button)
                        .help("Show podium")
                    }
                }
                Slider(
                    value: $monthPosition,
                    in: 0...Double(max(appState.timelineMonths.count - 1, 1)),
                    step: 1
                )
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

            if showChart {
                PodiumView(entries: monthTopFive)
                    .animation(.spring(duration: 0.4), value: currentMonthIndex)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            if monthConversations.isEmpty {
                Text("No conversations this month.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                leaderboardList(monthConversations)
            }
        }
    }

    private func openInMessages(handle: String) {
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
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
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
            var e = byPerson[c.resolvedName] ?? (0, 0)
            e.sent += c.sentMessages
            e.received += c.receivedMessages
            byPerson[c.resolvedName] = e
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
    var id: String { name }
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
                            .foregroundStyle(.yellow)
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
            }
        }
    }
}

let leaderboardColor = Color.blue

struct LeaderboardRow: View {
    let name: String
    let count: Int
    let avatar: Data?
    let fraction: Double
    let onMessage: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(name: name, imageData: avatar, color: leaderboardColor, size: 28)
            Text(name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 150, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(leaderboardColor.opacity(0.12))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(leaderboardColor)
                        .frame(width: max(geo.size.width * CGFloat(fraction), 4))
                }
            }
            .frame(height: 22)
            Text("\(count)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            Button(action: onMessage) {
                Image(systemName: "bubble.left.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
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
