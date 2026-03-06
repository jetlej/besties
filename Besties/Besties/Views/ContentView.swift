import SwiftUI

enum Tab: String, CaseIterable {
    case reconnect = "Reconnect"
    case allTime = "All Time"
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
    @State private var selectedTab = Tab.reconnect
    @State private var selectedRange = TimeRange.sixMonths

    private var filteredReconnect: [Conversation] {
        appState.reconnectConversations(maxDays: selectedRange.rawValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Spacer()

                Text("Last Contact:")
                    .foregroundStyle(.secondary)
                Picker("", selection: $selectedRange) {
                    ForEach(TimeRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .fixedSize()
                .opacity(selectedTab == .reconnect ? 1 : 0)
                .disabled(selectedTab != .reconnect)
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
                            allTimeTable
                        }
                    }
                }
            }
        }
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

    private var allTimeTable: some View {
        Table(appState.allConversations) {
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

    private func openInMessages(handle: String) {
        let cleaned = handle.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? handle
        if let url = URL(string: "imessage://\(cleaned)") {
            NSWorkspace.shared.open(url)
        }
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
