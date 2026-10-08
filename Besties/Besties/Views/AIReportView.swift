import SwiftUI
import AppKit

/// One packaged moment (Phase 3): the engine runs the whole agent loop and
/// hands back an `AIReport`, which is rendered as native cards rather than
/// prose. Screenshot mode already masks names, so the cards are the share
/// surface — no extra export path.
struct AIReportView: View {
    let appState: AppState
    let kind: AIReportKind

    @Environment(\.dismiss) private var dismiss
    @State private var report: AIReport?
    @State private var failure: String?
    /// The latest tool-activity line, e.g. `searched "ramen" with Alex`.
    @State private var activity: String?
    /// Interim narration the model streams between tool calls; only its last
    /// line is shown, as progress.
    @State private var narration = ""
    @State private var usage = AIUsage()
    @State private var isRunning = false
    @State private var startedAt = Date()
    @State private var copiedDraft: String?
    /// The finished report rendered as an image, ready to copy or share.
    @State private var shareImage: NSImage?
    @State private var shareURL: URL?
    @State private var copiedImage = false
    /// Bumped by Retry. Every run — the first one and every retry — is the
    /// view's own `.task`, so dismissing the sheet cancels whatever is in
    /// flight instead of leaving a 64k-token run burning with nowhere to land.
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            content
            if usage.outputTokens > 0 {
                Divider()
                footer
            }
        }
        .background(Color.paper)
        .task(id: attempt) {
            guard report == nil, !isRunning else { return }
            await run()
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("\(kind.emoji)  \(kind.label)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.ink.opacity(0.5))
            Spacer(minLength: 8)
            if report != nil {
                Button(copiedImage ? "Copied" : "Copy image") { copyImage() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        let tokens = "\(usage.inputTokens.formatted()) in · \(usage.outputTokens.formatted()) out · \(usage.cacheReadTokens.formatted()) cached · \(usage.cacheCreationTokens.formatted()) written"
        return Text("\(tokens) · \(String(format: "$%.4f", usage.costUSD))")
            .font(.caption2.monospaced())
            .foregroundStyle(Color.ink.opacity(0.35))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let report {
                    reportBody(report)
                    if case .biography = kind, messageTarget != nil {
                        sendCTA
                    }
                } else {
                    heroTitle
                    if let failure {
                        failureCard(failure)
                    } else {
                        runningCard
                    }
                }
            }
            .frame(maxWidth: contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The rendered report — shared between the scrolling view and the image
    /// export, so what gets shared is exactly what is on screen.
    private func reportBody(_ report: AIReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heroTitle
            ForEach(Self.blocks(report.sections, heroFirstStat: isPoster)) { block in
                blockView(block)
            }
        }
    }

    /// What `ImageRenderer` draws: the report at its on-screen width on paper,
    /// with a small brand line so a shared screenshot says where it came from.
    private func exportView(_ report: AIReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            reportBody(report)
            Text("✨ made with Besties")
                .font(.caption2)
                .foregroundStyle(Color.ink.opacity(0.35))
                .frame(maxWidth: .infinity)
        }
        .frame(width: contentWidth, alignment: .leading)
        .padding(isPhone ? 16 : 24)
        .background(Color.paper)
    }

    /// The Friendship Wrapped payoff: one tap sends the finished card to the
    /// friend it is about.
    private var sendCTA: some View {
        VStack(spacing: 6) {
            Button {
                sendToFriend()
            } label: {
                Text("💛  Send to \(personFirstName ?? "them")")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.sun, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            Text(messageTarget?.source == .whatsApp
                 ? "Copies the image and opens your WhatsApp thread — paste to send."
                 : "Opens Messages with the image attached.")
                .font(.caption2)
                .foregroundStyle(Color.ink.opacity(0.45))
        }
        .padding(.top, 4)
    }

    /// Both wrapped reports go poster-mode: big centered title over full-bleed
    /// color tiles. Reconnect stays editorial, left-aligned.
    private var isPoster: Bool {
        switch kind {
        case .wrapped, .biography: true
        case .reconnectDraft: false
        }
    }

    /// Friendship Wrapped is designed phone-first: a 390pt column, one
    /// full-width tile per stat, and type sized to read on an iPhone — because
    /// the report's real destination is that friend's Messages thread.
    private var isPhone: Bool {
        if case .biography = kind { return true }
        return false
    }

    private var contentWidth: CGFloat { isPhone ? 390 : 640 }

    /// Medals are Besties Wrapped's top-five language — a leaderboard of
    /// people. Friendship Wrapped's lists are inside jokes, not rankings.
    private var usesMedals: Bool {
        if case .wrapped = kind { return true }
        return false
    }

    private var heroTitle: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(report?.title ?? kind.runningTitle(person: personFirstName))
                .font(.system(size: isPhone ? 40 : (isPoster ? 34 : 27), weight: .heavy, design: .rounded))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = report?.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(isPhone ? .system(size: 16) : .callout)
                    .foregroundStyle(Color.ink.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 2)
    }

    /// Same thinking/elapsed pattern as the chat transcript, with the current
    /// tool activity underneath so a two-minute report doesn't look stuck.
    private var runningCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Reading your messages… \(elapsed)s")
                        .font(.caption.monospaced())
                }
                .foregroundStyle(Color.ink.opacity(0.5))
            }
            if let activity {
                Text(activity)
                    .font(.caption)
                    .foregroundStyle(Color.ink.opacity(0.4))
                    .lineLimit(1)
            }
            if let line = Self.lastLine(narration) {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(Color.ink.opacity(0.4))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.bubbleTan, in: RoundedRectangle(cornerRadius: 12))
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry") { attempt += 1 }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRunning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.bubbleTan, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.5)))
    }

    // MARK: - Sections

    /// Consecutive `stat` sections share one adaptive grid so the numbers read
    /// as a row of tiles instead of a column of banners.
    private enum Block: Identifiable {
        case stats(Int, [AIReport.Section])
        case single(Int, AIReport.Section)

        var id: Int {
            switch self {
            case .stats(let index, _): index
            case .single(let index, _): index
            }
        }
    }

    /// `heroFirstStat` keeps the report's opening stat out of that grouping, so
    /// the number the brief asks for as the hero is the one that gets the
    /// full-width tile — otherwise it lands in a grid with the stats behind it
    /// while some lone stat further down inherits the hero treatment.
    private static func blocks(_ sections: [AIReport.Section], heroFirstStat: Bool) -> [Block] {
        var blocks: [Block] = []
        var stats: [AIReport.Section] = []
        var statsStart = 0

        func flush() {
            guard !stats.isEmpty else { return }
            blocks.append(.stats(statsStart, stats))
            stats = []
        }

        for (index, section) in sections.enumerated() {
            if section.kind == "stat" {
                if heroFirstStat, index == 0 {
                    blocks.append(.stats(0, [section]))
                    continue
                }
                if stats.isEmpty { statsStart = index }
                stats.append(section)
            } else {
                flush()
                blocks.append(.single(index, section))
            }
        }
        flush()
        return blocks
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .stats(let start, let sections):
            if isPoster {
                // Only the report's opening stat is the hero; a lone stat
                // anywhere else is just a tile that happens to be alone.
                if start == 0, sections.count == 1 {
                    posterTile(sections[0], index: start, hero: true)
                } else if isPhone {
                    // Phone-first: one full-width tile per stat, story-style.
                    VStack(spacing: 12) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { offset, section in
                            posterTile(section, index: start + offset, hero: false)
                        }
                    }
                } else {
                    // Manual pair rows instead of a grid: each row sizes to its
                    // tallest tile and the neighbor stretches to match, content
                    // pinned to the top.
                    let rows = stride(from: 0, to: sections.count, by: 2).map {
                        Array(sections[$0..<min($0 + 2, sections.count)])
                    }
                    VStack(spacing: 12) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(Array(row.enumerated()), id: \.offset) { offset, section in
                                    posterTile(section, index: start + rowIndex * 2 + offset, hero: false)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        statCard(section)
                    }
                }
            }
        case .single(let index, let section):
            switch section.kind {
            case "quotes": quotesCard(section)
            case "list":
                if usesMedals { rankedCard(section) } else { listCard(section) }
            case "drafts": draftsCard(section)
            case "emoji": emojiTile(section)
            case "badge": badgeBand(section)
            case "photo": photoPolaroid(section, photoIndex: photoOrdinal(before: index))
            case "chart": chartCard(section)
            case "versus": versusBar(section)
            default: storyCard(section)
            }
        }
    }

    /// Which photo this one is, so consecutive polaroids tilt opposite ways.
    private func photoOrdinal(before index: Int) -> Int {
        report?.sections.prefix(index).filter { $0.kind == "photo" }.count ?? 0
    }

    /// Wrapped's Spotify-style tiles: one loud color, one huge number, one
    /// line under it. Tint rotates with the section's position in the report.
    private static let posterTints: [(background: Color, foreground: Color)] = [
        (.sun, .ink), (.brandBlue, .white), (.purple, .white),
        (.orange, .white), (.pink, .white), (.green, .white),
    ]

    private func posterTile(_ section: AIReport.Section, index: Int, hero: Bool) -> some View {
        let tint = Self.posterTints[index % Self.posterTints.count]
        return VStack(alignment: .leading, spacing: 5) {
            if let heading = section.heading, !heading.isEmpty {
                Text(heading.uppercased())
                    .font(.caption.weight(.heavy))
                    .tracking(0.8)
                    .foregroundStyle(tint.foreground.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(section.value ?? "")
                .font(.system(size: hero ? (isPhone ? 66 : 54) : (isPhone ? 48 : 40),
                              weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.35)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let label = section.label, !label.isEmpty {
                Text(label)
                    .font(isPhone ? .system(size: 16, weight: .medium) : .callout.weight(.medium))
                    .foregroundStyle(tint.foreground.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(tint.foreground)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(hero ? (isPhone ? 24 : 22) : (isPhone ? 20 : 18))
        .background(tint.background, in: RoundedRectangle(cornerRadius: isPhone ? 20 : 18))
    }

    /// Wrapped's top-five: medals up top, big rank numbers below — the same
    /// language as the All Time leaderboard.
    private static let medals = ["🥇", "🥈", "🥉"]

    private func rankedCard(_ section: AIReport.Section) -> some View {
        let items = section.items ?? []
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeading(section.heading)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Group {
                            if index < Self.medals.count {
                                Text(Self.medals[index])
                                    .font(.system(size: 19))
                            } else {
                                Text("\(index + 1)")
                                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                                    .foregroundStyle(Color.ink.opacity(0.35))
                            }
                        }
                        .frame(width: 30, alignment: .center)
                        Text(Self.inline(item))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8)
                    if index < items.count - 1 { Divider() }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.ink.opacity(0.08)))
    }

    /// The emoji top five, on the report's one ink-black tile: the faces read
    /// as a spread row, each with its count under it. An eyebrow over an empty
    /// black slab says nothing, so the tile goes when no item carries a face.
    @ViewBuilder
    private func emojiTile(_ section: AIReport.Section) -> some View {
        let items = (section.items ?? [])
            .map(Self.emojiEntry)
            .filter { !$0.emoji.isEmpty }
            .prefix(5)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                if let heading = section.heading, !heading.isEmpty {
                    Text(heading.uppercased())
                        .font(.caption.weight(.heavy))
                        .tracking(0.8)
                        .foregroundStyle(Color.paper.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, entry in
                        VStack(spacing: 6) {
                            Text(entry.emoji)
                                .font(.system(size: 42))
                            if !entry.count.isEmpty {
                                Text(entry.count)
                                    .font(.system(size: isPhone ? 13 : 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.paper.opacity(0.75))
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.ink, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    /// One-line verdict with a face on it: emoji left, title and caption right.
    /// Nothing but the caption is optional, so an empty value and an empty
    /// heading leave a band with no verdict in it — drop it instead.
    @ViewBuilder
    private func badgeBand(_ section: AIReport.Section) -> some View {
        let value = section.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let heading = section.heading?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !value.isEmpty || !heading.isEmpty {
            HStack(spacing: 14) {
                Text(value)
                    .font(.system(size: 46))
                VStack(alignment: .leading, spacing: 3) {
                    if !heading.isEmpty {
                        Text(heading)
                            .font(.system(size: isPhone ? 20 : 17, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let label = section.label, !label.isEmpty {
                        Text(label)
                            .font(isPhone ? .system(size: 14) : .caption)
                            .foregroundStyle(Color.ink.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.bubbleTan.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    /// A real photo out of the thread, framed like a polaroid. macOS prunes
    /// most attachment files while leaving the row in chat.db, so the model
    /// sends a run of candidates — `value` first, then `items` in preference
    /// order — and the first one that actually loads is the one framed. The
    /// section disappears only when none of them do: a hole where a memory
    /// should be is worse than a slightly shorter report.
    @ViewBuilder
    private func photoPolaroid(_ section: AIReport.Section, photoIndex: Int) -> some View {
        if let image = Self.polaroidImage(for: section) {
            let photoWidth: CGFloat = isPhone ? 330 : 300
            VStack(spacing: 8) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: photoWidth, height: Self.polaroidHeight(image, width: photoWidth))
                    .clipped()
                if let label = section.label, !label.isEmpty {
                    Text(label)
                        .font(.system(size: isPhone ? 14 : 12))
                        .foregroundStyle(Color.ink.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .frame(width: photoWidth)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(Color.white)
            .shadow(color: Color.ink.opacity(0.18), radius: 8, y: 4)
            .rotationEffect(.degrees(photoIndex.isMultiple(of: 2) ? -1.6 : 1.6))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    /// A head-to-head split bar — "Who texts first". Two names, two counts,
    /// one two-color bar with the percentages on their own sides. Needs both
    /// sides to be parseable and non-zero or it renders nothing.
    @ViewBuilder
    private func versusBar(_ section: AIReport.Section) -> some View {
        let sides = (section.items ?? []).compactMap(Self.bar).prefix(2)
        if sides.count == 2 {
            let left = sides[sides.startIndex]
            let right = sides[sides.index(after: sides.startIndex)]
            let total = left.value + right.value
            if total > 0, left.value > 0, right.value > 0 {
                let leftShare = Double(left.value) / Double(total)
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeading(section.heading)
                    HStack {
                        Text("\(left.label) · \(Int((leftShare * 100).rounded()))%")
                            .font(.system(size: isPhone ? 17 : 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.ink)
                        Spacer(minLength: 8)
                        Text("\(right.label) · \(100 - Int((leftShare * 100).rounded()))%")
                            .font(.system(size: isPhone ? 17 : 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.ink.opacity(0.65))
                    }
                    GeometryReader { geo in
                        HStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.sun)
                                .frame(width: max(14, (geo.size.width - 3) * leftShare))
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.brandBlue)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: isPhone ? 26 : 20)
                    if let label = section.label, !label.isEmpty {
                        Text(label)
                            .font(isPhone ? .system(size: 14) : .caption)
                            .foregroundStyle(Color.ink.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(isPhone ? 18 : 14)
                .background(Color.white, in: RoundedRectangle(cornerRadius: isPhone ? 20 : 12))
                .overlay(RoundedRectangle(cornerRadius: isPhone ? 20 : 12).strokeBorder(Color.ink.opacity(0.08)))
            }
        }
    }

    /// The eras, as bars. Heights are relative to the tallest one, and the
    /// tall bars carry the sun so the shape reads before the labels do. One or
    /// two bars aren't a shape — they render as a full-width slab that looks
    /// like a design mistake — so the card only appears from three bars up.
    @ViewBuilder
    private func chartCard(_ section: AIReport.Section) -> some View {
        let bars = (section.items ?? []).compactMap(Self.bar)
        let peak = bars.map(\.value).max() ?? 0
        if bars.count >= 3, peak > 0 {
            let ticks = Self.tickIndices(count: bars.count)
            VStack(alignment: .leading, spacing: 8) {
                sectionHeading(section.heading)
                let barHeight: CGFloat = isPhone ? 80 : 64
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                        UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                            .fill(bar.value >= peak * 0.55 ? Color.sun : Color.bubbleTan)
                            .frame(height: max(3, barHeight * bar.value / peak))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: barHeight, alignment: .bottom)
                // Tick labels get their natural width, spread across the axis —
                // pinning each to its bar's column truncates them all to "…"
                // once the bars get narrow.
                let tickList = ticks.sorted()
                HStack(spacing: 8) {
                    ForEach(Array(tickList.enumerated()), id: \.offset) { position, index in
                        Text(bars[index].label)
                            .font(isPhone ? .system(size: 13) : .caption2)
                            .foregroundStyle(Color.ink.opacity(0.45))
                            .lineLimit(1)
                            .fixedSize()
                        if position < tickList.count - 1 { Spacer(minLength: 4) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(isPhone ? 16 : 14)
            .background(Color.white, in: RoundedRectangle(cornerRadius: isPhone ? 20 : 12))
            .overlay(RoundedRectangle(cornerRadius: isPhone ? 20 : 12).strokeBorder(Color.ink.opacity(0.08)))
        }
    }

    private func statCard(_ section: AIReport.Section) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let heading = section.heading, !heading.isEmpty {
                Text(heading.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.ink.opacity(0.4))
                    .lineLimit(1)
            }
            Text(section.value ?? "")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.ink)
                .minimumScaleFactor(0.45)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let label = section.label, !label.isEmpty {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Color.ink.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.ink.opacity(0.08)))
    }

    private func storyCard(_ section: AIReport.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading(section.heading)
            MarkdownBody(text: section.body ?? "")
                .font(isPhone ? .system(size: 19, weight: .medium) : .body)
                .foregroundStyle(Color.ink)
                .lineSpacing(isPhone ? 4 : 2)
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.ink.opacity(0.08)))
    }

    private func listCard(_ section: AIReport.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading(section.heading)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array((section.items ?? []).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(Color.sun)
                            .font(.body.weight(.bold))
                        Text(Self.inline(item))
                            .font(isPhone ? .system(size: 17) : .body)
                            .lineSpacing(isPhone ? 3 : 0)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.ink.opacity(0.08)))
    }

    /// Real messages, in real bubbles — the part people screenshot. A quote with
    /// no sender or no date can't be traced back to a message in the archive, so
    /// it is dropped rather than shown looking exactly like a sourced one; the
    /// card disappears if that leaves nothing.
    @ViewBuilder
    private func quotesCard(_ section: AIReport.Section) -> some View {
        let quotes = (section.quotes ?? []).filter(Self.isSourced)
        if !quotes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading(section.heading)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(quotes.enumerated()), id: \.offset) { _, quote in
                        quoteBubble(quote)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.bubbleTan.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func quoteBubble(_ quote: AIReport.Quote) -> some View {
        let fromMe = Self.isMe(quote.from)
        let caption = [quote.from, quote.date].compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return HStack {
            if fromMe { Spacer(minLength: 40) }
            VStack(alignment: fromMe ? .trailing : .leading, spacing: 2) {
                Text(quote.text)
                    .font(isPhone ? .system(size: 17) : .body)
                    .lineSpacing(isPhone ? 2 : 0)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, isPhone ? 14 : 10)
                    .padding(.vertical, isPhone ? 10 : 7)
                    .background(fromMe ? Color.brandBlue : Color.white)
                    .foregroundStyle(fromMe ? Color.white : Color.ink)
                    .clipShape(RoundedRectangle(cornerRadius: isPhone ? 18 : 14))
                if !caption.isEmpty {
                    Text(caption)
                        .font(isPhone ? .system(size: 13) : .caption2)
                        .foregroundStyle(Color.ink.opacity(0.45))
                }
            }
            if !fromMe { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: fromMe ? .trailing : .leading)
    }

    /// Ready-to-send openers: each one is a sent-style bubble with the two
    /// actions that make it useful.
    private func draftsCard(_ section: AIReport.Section) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(section.heading)
            ForEach(Array((section.items ?? []).enumerated()), id: \.offset) { _, draft in
                VStack(alignment: .leading, spacing: 8) {
                    Text(draft)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.brandBlue, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Color.white)
                    HStack(spacing: 8) {
                        Button(copiedDraft == draft ? "Copied" : "Copy") { copy(draft) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        if messageTarget != nil {
                            Button("Open in Messages") { send(draft) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    }
                }
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.ink.opacity(0.08)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func sectionHeading(_ heading: String?) -> some View {
        if let heading, !heading.isEmpty {
            Text(heading)
                .font(isPhone ? .system(size: 23, weight: .heavy, design: .rounded) : .headline)
                .foregroundStyle(Color.ink)
        }
    }

    // MARK: - Actions

    private func copy(_ draft: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(draft, forType: .string)
        copiedDraft = draft
    }

    /// Copies the draft first — `imessage://` can't carry a body, so the user
    /// lands in the right thread with the text already on the clipboard.
    private func send(_ draft: String) {
        copy(draft)
        guard let target = messageTarget else { return }
        openInMessages(handle: target.handle, source: target.source)
    }

    // MARK: - Person

    private var personKey: String? {
        switch kind {
        case .wrapped: nil
        case .biography(let person): person
        case .reconnectDraft(let person): person
        }
    }

    /// The busiest conversation belonging to the report's person, for the
    /// display name and the message button.
    private var person: Conversation? {
        guard let personKey else { return nil }
        return appState.resolvedConversations
            .filter { $0.mergeKey == personKey || $0.resolvedName == personKey || $0.handle == personKey }
            .max { $0.totalMessages < $1.totalMessages }
    }

    /// Friendship Wrapped speaks in first names — "Jordan & Katya", never
    /// "Katya Jagirdar".
    private var personFirstName: String? {
        personName?.split(separator: " ").first.map(String.init)
    }

    private var personName: String? {
        person?.resolvedName ?? personKey
    }

    private var messageTarget: (handle: String, source: MessageSource)? {
        person.map { ($0.handle, $0.source) }
    }

    // MARK: - Run

    private func run() async {
        guard !isRunning else { return }
        isRunning = true
        failure = nil
        activity = nil
        narration = ""
        usage = AIUsage()
        startedAt = .now

        let engine = AIReportEngine(apiKey: SubscriptionManager.shared.activeKey ?? "", toolbox: AIToolbox(appState: appState))
        let finished = await engine.run(kind) { event in
            switch event {
            case .textDelta(let chunk):
                narration += chunk
            case .toolStarted(_, let summary):
                activity = summary
            case .toolFinished:
                break
            // The engine writes the turn line to ai-usage.jsonl itself; this is
            // only the footer.
            case .turnCompleted(_, let turnUsage, _):
                usage = turnUsage
            case .failed(let message):
                failure = message
            }
        }
        if let finished {
            report = finished
            failure = nil
            prepareShare()
        } else if failure == nil {
            failure = "The report came back empty. Try again."
        }
        isRunning = false
    }

    // MARK: - Sharing

    /// Draws the finished report to a retina image and stages a PNG for the
    /// share sheet. Runs once, when the report lands.
    private func renderImage() -> NSImage? {
        guard let report else { return nil }
        let renderer = ImageRenderer(content: exportView(report))
        renderer.scale = 2
        return renderer.nsImage
    }

    private func prepareShare() {
        guard let image = renderImage() else { return }
        shareImage = image
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let name = personName.map { "\(kind.label) — \($0)" } ?? kind.label
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).png")
        if (try? png.write(to: url, options: .atomic)) != nil {
            shareURL = url
        }
    }

    private func copyImage() {
        guard let image = shareImage ?? renderImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        copiedImage = true
    }

    /// iMessage people get a Messages compose window with the card attached
    /// and the recipient filled in. WhatsApp has no compose service, so the
    /// image rides the clipboard into the opened thread instead.
    private func sendToFriend() {
        guard let image = shareImage ?? renderImage(),
              let target = messageTarget else { return }
        if target.source == .iMessage, let service = NSSharingService(named: .composeMessage) {
            service.recipients = [target.handle]
            service.perform(withItems: [image])
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            openInMessages(handle: target.handle, source: target.source)
        }
    }

    // MARK: - Helpers

    /// A quote earns a bubble only if it says who sent it and when — that
    /// caption is the evidence, and the schema asks for both.
    private static func isSourced(_ quote: AIReport.Quote) -> Bool {
        func filled(_ value: String?) -> Bool {
            !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        return filled(quote.text) && filled(quote.from) && filled(quote.date)
    }

    private static func isMe(_ from: String?) -> Bool {
        guard let from = from?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return from == "me" || from == "you"
    }

    private static func lastLine(_ text: String) -> String? {
        let line = text.split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return (line?.isEmpty ?? true) ? nil : line
    }

    /// `"😂 1,204"` → the face and its count. No space means the whole item is
    /// the face and it stands on its own.
    private static func emojiEntry(_ item: String) -> (emoji: String, count: String) {
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = trimmed.firstIndex(of: " ") else { return (trimmed, "") }
        return (String(trimmed[trimmed.startIndex..<space]),
                trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces))
    }

    /// `"2017 1204"` → the label and its height. The count is the last
    /// whitespace-separated field, so a label can carry spaces of its own.
    private static func bar(_ item: String) -> (label: String, value: Double)? {
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = trimmed.lastIndex(of: " ") else { return nil }
        let digits = trimmed[trimmed.index(after: space)...].filter { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return nil }
        return (String(trimmed[..<space]).trimmingCharacters(in: .whitespaces), value)
    }

    /// Both ends always get a label, plus up to two evenly spaced inside —
    /// enough to read the axis without a wall of overlapping years.
    private static func tickIndices(count: Int) -> Set<Int> {
        guard count > 3 else { return Set(0..<count) }
        var ticks: Set<Int> = [0, count - 1]
        for step in 1...2 { ticks.insert(step * (count - 1) / 3) }
        return ticks
    }

    /// The only two places a report's photo may come from. Anything else — a
    /// path the model invented, a file that has moved, something outside the
    /// archives — returns nil and the section is dropped.
    private static let photoRoots = [
        NSHomeDirectory() + "/Library/Messages/Attachments",
        NSHomeDirectory() + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media",
    ]

    /// `value`, then each fallback in `items`, capped at the eight candidates
    /// the schema asks for so a stray list can't turn one card into a hundred
    /// disk reads.
    private static func polaroidImage(for section: AIReport.Section) -> NSImage? {
        let candidates = (section.value.map { [$0] } ?? []) + (section.items ?? [])
        for path in candidates.prefix(8) {
            if let image = polaroidImage(path) { return image }
        }
        return nil
    }

    private static func polaroidImage(_ path: String?) -> NSImage? {
        guard let path else { return nil }
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        // standardized resolves any "..", so a path can't climb back out of a root.
        let file = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard photoRoots.contains(where: { file.hasPrefix($0 + "/") }) else { return nil }
        return NSImage(contentsOfFile: file)
    }

    /// The polaroid is a fixed 300pt wide and lets the photo set its own
    /// height — most attachments are portrait, and a fixed landscape window
    /// would cut the subject's head off. Very tall photos stop at 380pt so one
    /// picture can't run past the card.
    private static func polaroidHeight(_ image: NSImage, width: CGFloat) -> CGFloat {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return 210 }
        return min(width * 1.3, width * size.height / size.width)
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

extension AIReportKind {
    var emoji: String {
        switch self {
        case .wrapped: "🎁"
        case .biography: "💛"
        case .reconnectDraft: "👋"
        }
    }

    /// Short chrome label — the report supplies its own title once it lands.
    var label: String {
        switch self {
        case .wrapped(let year): year.map { "Besties Wrapped \($0)" } ?? "Besties Wrapped — all time"
        case .biography: "Friendship Wrapped"
        case .reconnectDraft: "Reconnect draft"
        }
    }

    func runningTitle(person: String?) -> String {
        switch self {
        case .wrapped:
            return label
        case .biography:
            return person.map { "\(AIReportPrompt.userFirstName) & \($0)" } ?? "Friendship Wrapped"
        case .reconnectDraft:
            return person.map { "Reconnect ideas with \($0)" } ?? "Reconnect draft"
        }
    }
}

/// Picks the one argument a moment needs — a year for Wrapped, a person for
/// the other two — and hands the finished kind back to the caller.
struct AIMomentPicker: View {
    enum Moment: String, Identifiable {
        case wrapped, biography, reconnect

        var id: String { rawValue }

        var title: String {
            switch self {
            case .wrapped: "🎁  Besties Wrapped"
            case .biography: "💛  Friendship Wrapped"
            case .reconnect: "👋  Reconnect draft"
            }
        }

        var prompt: String {
            switch self {
            case .wrapped: "Pick a year."
            case .biography: "Whose story?"
            case .reconnect: "Who are you texting?"
            }
        }
    }

    let appState: AppState
    let moment: Moment
    let onPick: (AIReportKind) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(moment.title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text(moment.prompt)
                    .font(.caption)
                    .foregroundStyle(Color.ink.opacity(0.5))
            }
            if moment == .wrapped {
                years
            } else {
                peoplePicker
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 340, height: moment == .wrapped ? 380 : 420)
        .background(Color.paper)
    }

    // MARK: - Wrapped

    private var years: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                choice("All time", subtitle: "Everything you've ever sent") {
                    onPick(.wrapped(year: nil))
                }
                ForEach(availableYears, id: \.self) { year in
                    choice(String(year), subtitle: nil) { onPick(.wrapped(year: year)) }
                }
            }
        }
    }

    /// Years with messages in them, newest first. Falls back to the
    /// conversation date range when the timeline hasn't loaded yet.
    private var availableYears: [Int] {
        let fromTimeline = Set(appState.timelineMonths.compactMap { Int($0.prefix(4)) })
        if !fromTimeline.isEmpty { return fromTimeline.sorted(by: >) }
        let calendar = Calendar.current
        guard let first = appState.resolvedConversations.map(\.firstMessageDate).min(),
              let last = appState.resolvedConversations.map(\.lastMessageDate).max() else { return [] }
        let start = calendar.component(.year, from: first)
        let end = calendar.component(.year, from: last)
        guard start <= end else { return [] }
        return Array((start...end).reversed())
    }

    // MARK: - People

    private var peoplePicker: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
                TextField("Filter people…", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(people, id: \.mergeKey) { convo in
                        personRow(convo)
                    }
                }
            }
        }
    }

    private func personRow(_ convo: Conversation) -> some View {
        Button {
            onPick(moment == .biography
                   ? .biography(person: convo.mergeKey)
                   : .reconnectDraft(person: convo.mergeKey))
        } label: {
            HStack(spacing: 9) {
                AvatarView(
                    name: convo.resolvedName,
                    imageData: appState.avatar(forHandle: convo.handle),
                    color: leaderboardColor,
                    size: 26
                )
                Text(convo.resolvedName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(moment == .reconnect ? "\(convo.daysSinceLastMessage)d ago" : "\(convo.totalMessages)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.ink.opacity(0.4))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// One row per person (busiest conversation wins the label), filtered the
    /// same way the People filter elsewhere in the app is.
    private var people: [Conversation] {
        // Reconnect mirrors the Reconnect tab: dormant people, best score
        // first — not the people the user already talks to every day.
        if moment == .reconnect {
            var best: [String: Conversation] = [:]
            for convo in appState.reconnectConversations(maxDays: TimeRange.sixMonths.rawValue) {
                if let existing = best[convo.mergeKey], existing.score >= convo.score { continue }
                best[convo.mergeKey] = convo
            }
            return best.values
                .filter(matches)
                .sorted { $0.score > $1.score }
        }
        var busiest: [String: Conversation] = [:]
        for convo in appState.resolvedConversations {
            if let existing = busiest[convo.mergeKey], existing.totalMessages >= convo.totalMessages { continue }
            busiest[convo.mergeKey] = convo
        }
        return busiest.values
            .filter(matches)
            .sorted { $0.totalMessages > $1.totalMessages }
    }

    /// Matches by name or handle; digit-only comparison lets "555-1234"
    /// find "+15551234".
    private func matches(_ convo: Conversation) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        if convo.resolvedName.localizedCaseInsensitiveContains(trimmed) { return true }
        if convo.handle.localizedCaseInsensitiveContains(trimmed) { return true }
        let digits = trimmed.filter(\.isNumber)
        return !digits.isEmpty && convo.handle.filter(\.isNumber).contains(digits)
    }

    private func choice(_ title: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Color.ink.opacity(0.45))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.ink.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}
