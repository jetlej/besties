import Foundation

/// The three packaged moments. Each one is a single agent run over the same
/// toolbox as the chat, with its own system prompt and a structured ending.
enum AIReportKind: Equatable {
    /// `nil` = all time.
    case wrapped(year: Int?)
    case biography(person: String)
    case reconnectDraft(person: String)

    /// Stable, person-free name for the usage log.
    var logName: String {
        switch self {
        case .wrapped: "wrapped"
        case .biography: "biography"
        case .reconnectDraft: "reconnectDraft"
        }
    }
}

/// What the model hands back, and what the SwiftUI cards render. The shape
/// mirrors the `render_report` tool's input_schema exactly — a section fills in
/// only the fields its `kind` uses, so everything but `kind` is optional.
struct AIReport: Codable {
    var title: String
    var subtitle: String?
    var sections: [Section]

    struct Section: Codable {
        /// "stat" | "story" | "quotes" | "list" | "drafts" | "emoji" | "badge"
        /// | "photo" | "chart" | "versus"
        var kind: String
        /// For emoji this is the uppercase eyebrow; for chart, the card title.
        var heading: String?
        /// Markdown prose, for story.
        var body: String?
        /// The big number or phrase, for stat; one emoji for badge; the
        /// best-guess absolute image path for photo.
        var value: String?
        /// The caption under the value, for stat and badge; the caption under
        /// the polaroid, for photo.
        var label: String?
        /// For list; for drafts these are the ready-to-send message options.
        /// For emoji, "<emoji> <count>" lines; for chart, "<label> <count>".
        /// For photo, the remaining candidate image paths in preference order:
        /// macOS prunes most attachment files while leaving the row behind, so
        /// the view tries `value` and then each of these until one loads.
        var items: [String]?
        var quotes: [Quote]?
    }

    struct Quote: Codable {
        var text: String
        var from: String?
        var date: String?
    }
}

/// Runs one report to completion. The run ends when the model calls
/// `render_report`: `AIToolLoop` treats that tool_use as terminal — it hands
/// back the input and never answers it — so the last thing the model says is
/// structured rather than prose that would have to be parsed.
@MainActor
final class AIReportEngine {
    private static let maxTokens = 64_000
    /// A report digs harder than a chat answer — totals, a transcript read, a
    /// phrase hunt — so the same runaway guard sits further out.
    private static let maxToolRounds = 40
    private static let renderReportName = "render_report"

    private let apiKey: String
    private let toolbox: AIToolbox

    private(set) var isRunning = false

    init(apiKey: String, toolbox: AIToolbox) {
        self.apiKey = apiKey
        self.toolbox = toolbox
    }

    /// Generates one report, emitting the same events the chat does: tool
    /// activity, interim text (progress narration, not the report), and one
    /// `.turnCompleted` carrying the whole run's usage. Never throws — a
    /// failure arrives as `.failed` and returns nil.
    func run(_ kind: AIReportKind, onEvent: @escaping (AIStreamEvent) -> Void) async -> AIReport? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }

        let loop = AIToolLoop(
            apiKey: apiKey, toolbox: toolbox,
            config: .init(systemPrompt: AIReportPrompt.system(for: kind),
                          maxTokens: Self.maxTokens,
                          extraTools: [Self.renderReportTool],
                          terminalTool: Self.renderReportName,
                          maxToolRounds: Self.maxToolRounds))
        loop.messages = [[
            "role": "user",
            "content": [["type": "text", "text": AIReportPrompt.request(for: kind)]],
        ]]

        let turnID = UUID()
        let startedAt = Date()
        var usage = AIUsage()
        var toolCalls = 0
        var stopReason = "end_turn"
        var report: AIReport?
        // Two passes at most: the run itself, then one nudge if it ended in
        // prose or in a report the app can't read.
        var attemptsLeft = 2

        while attemptsLeft > 0 {
            attemptsLeft -= 1
            let outcome = await loop.run(turnID: turnID, onEvent: onEvent)
            usage.inputTokens += outcome.usage.inputTokens
            usage.outputTokens += outcome.usage.outputTokens
            usage.cacheReadTokens += outcome.usage.cacheReadTokens
            usage.cacheCreationTokens += outcome.usage.cacheCreationTokens
            toolCalls += outcome.toolCallCount
            stopReason = outcome.stopReason

            // The loop already emitted .failed and its history is unusable.
            if outcome.failed { break }

            if let terminal = outcome.terminal, let decoded = Self.decode(terminal.input) {
                report = decoded
                stopReason = "report"
                break
            }
            guard attemptsLeft > 0 else {
                onEvent(.failed(message: "The report didn't come back in a shape the app can show. Try generating it again."))
                stopReason = "no_report"
                break
            }
            loop.messages.append(Self.nudge(answering: outcome))
        }

        AIUsageLog.record(turnID: turnID, source: "report", reportKind: kind.logName,
                          usage: usage, stopReason: stopReason,
                          latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                          toolCallCount: toolCalls)
        onEvent(.turnCompleted(turnID: turnID, usage: usage, stopReason: stopReason))
        return report
    }

    /// Reads the tool input by hand rather than through `Codable`, because
    /// `Codable` is all-or-nothing: one section with a numeric `value` or an
    /// object in `items` would throw away a report that took two minutes and 64k
    /// tokens to gather. A malformed section is dropped on its own, obvious
    /// mistypings are coerced, and the report only fails when there is no usable
    /// title or no usable section left — which is what the caller nudges on.
    private static func decode(_ input: [String: Any]) -> AIReport? {
        guard let title = string(input["title"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        let sections = (input["sections"] as? [Any] ?? []).compactMap(section)
        guard !sections.isEmpty else { return nil }
        return AIReport(title: title, subtitle: string(input["subtitle"]), sections: sections)
    }

    /// A section is usable if it says what kind it is; every other field is
    /// taken when it reads as the right type and left out when it doesn't.
    private static func section(_ value: Any) -> AIReport.Section? {
        guard let object = value as? [String: Any],
              let kind = string(object["kind"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !kind.isEmpty else { return nil }
        return AIReport.Section(
            kind: kind,
            heading: string(object["heading"]),
            body: string(object["body"]),
            value: string(object["value"]),
            label: string(object["label"]),
            items: (object["items"] as? [Any])?.compactMap(item),
            quotes: (object["quotes"] as? [Any])?.compactMap(quote))
    }

    /// An item is a line of text. The emoji and chart kinds ask for
    /// "<thing> <count>" pairs, which the model sometimes sends as an object
    /// instead — flatten those back into the line the view parses rather than
    /// dropping the section's whole list.
    private static func item(_ value: Any) -> String? {
        if let text = string(value) { return text }
        guard let object = value as? [String: Any] else { return nil }
        let left = ["emoji", "label", "name", "text", "key"].lazy.compactMap { string(object[$0]) }.first
        let right = ["count", "value", "n", "total"].lazy.compactMap { string(object[$0]) }.first
        let line = [left, right].compactMap { $0 }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }

    private static func quote(_ value: Any) -> AIReport.Quote? {
        guard let object = value as? [String: Any],
              let text = string(object["text"]), !text.isEmpty else { return nil }
        return AIReport.Quote(text: text, from: string(object["from"]), date: string(object["date"]))
    }

    /// A stat's `value` is the field the model most often sends as a bare
    /// number, so numbers become their own text rather than nothing.
    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    /// The one nudge. The assistant turn that ended the run left every tool_use
    /// in it unanswered — `render_report` itself, and anything the model called
    /// alongside it — and the API needs a tool_result for each one or it rejects
    /// the request, so the follow-up opens with the whole set.
    private static func nudge(answering outcome: AIToolLoop.Outcome) -> [String: Any] {
        var content: [[String: Any]] = []
        for id in outcome.unansweredToolIDs {
            let why = id == outcome.terminal?.id
                ? "That didn't match render_report's schema, so nothing was rendered. Required: title (a string) and sections (an array); every section needs kind — one of stat, story, quotes, list, drafts, emoji, badge, photo, chart — and only the fields that kind uses."
                : "Not run — render_report was called in the same turn, and that ends the run."
            content.append([
                "type": "tool_result",
                "tool_use_id": id,
                "is_error": true,
                "content": why,
            ])
        }
        content.append([
            "type": "text",
            "text": "Call render_report now with the finished report, using what you already gathered. Nothing outside that call is shown.",
        ])
        return ["role": "user", "content": content]
    }

    /// Mirrors `AIReport` field for field. The loop never executes this one —
    /// calling it is how the model finishes.
    private static var renderReportTool: [String: Any] { [
        "name": AIReportEngine.renderReportName,
        "description": "Deliver the finished report. This ends the run: call it exactly once, as the very last thing you do, with every section filled in. What you pass here is the entire report the user sees — nothing you write outside it is shown.",
        "input_schema": [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "Short and specific, a few words."],
                "subtitle": ["type": "string", "description": "The scope: the year, the person, the date range."],
                "sections": [
                    "type": "array",
                    "description": "The report, in order. Six to nine sections.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "kind": [
                                "type": "string",
                                "enum": ["stat", "story", "quotes", "list", "drafts", "emoji", "badge", "photo", "chart", "versus"],
                                "description": "Which fields this section uses: stat = value + label, story = body, quotes = quotes, list = items, drafts = items, emoji = heading + items, badge = value + heading + label, photo = value + label + items (fallback paths), chart = heading + items, versus = heading + items + label.",
                            ],
                            "heading": [
                                "type": "string",
                                "description": "Short section heading. For emoji: an uppercase eyebrow, e.g. \"YOUR EMOJI TOP FIVE\". For badge: the title line, e.g. \"Your texting personality: Night Owl\". For chart: the card title, e.g. \"Your eras\".",
                            ],
                            "body": ["type": "string", "description": "For story: one or two short paragraphs of markdown prose."],
                            "value": [
                                "type": "string",
                                "description": "For stat: the number or short phrase shown big. For badge: exactly one emoji. For photo: the best candidate's absolute POSIX path, copied verbatim from attachment.filename (it usually starts with ~/ — pass it through unchanged, don't rewrite or invent it), with the other candidates in items.",
                            ],
                            "label": [
                                "type": "string",
                                "description": "For stat and badge: the one-line caption under the value. For photo: the caption under the picture, e.g. \"14 Sept — pulled straight from the thread\".",
                            ],
                            "items": [
                                "type": "array",
                                "items": ["type": "string"],
                                "description": "For list: one short line each. For drafts: each item is a complete message, ready to send unedited. For emoji: up to five lines, each one emoji then one space then its count (\"😂 1,204\"), most-used first. For chart: one line per bar in order, each a short label then one space then a plain integer count (\"2017 1204\") — at least three bars or the chart is dropped. For photo: the remaining candidate image paths after value, up to eight in all, best first, each copied verbatim from attachment.filename. Most attachment files have been deleted off this Mac even though the row survives, so always send several candidates: the app tries value, then each item in order, and shows the first that still exists. For versus: exactly two lines, each a first name then one space then a plain integer count (\"Katya 132\") — the app turns the counts into a two-color split bar with percentages.",
                            ],
                            "quotes": [
                                "type": "array",
                                "description": "For quotes: real messages only, copied as they were written.",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "text": ["type": "string", "description": "The message, verbatim."],
                                        "from": ["type": "string", "description": "\"Me\" or the person's name."],
                                        "date": ["type": "string", "description": "Readable, e.g. \"14 March 2019\"."],
                                    ],
                                    "required": ["text", "from", "date"],
                                ],
                            ],
                        ],
                        "required": ["kind"],
                    ],
                ],
            ],
            "required": ["title", "sections"],
        ],
    ] }
}

// MARK: - Prompts

/// One system prompt per report kind. The parts the chat and the reports share
/// — who the app is, the SQL cheatsheet, the care rules — come from `AIPrompt`
/// rather than being restated here. What varies per run (the year, the person)
/// rides on the user turn so the cached system prefix stays stable.
enum AIReportPrompt {
    /// The user's first name, for titles like "Jordan & Dalia" — the design
    /// uses real names because "you" reads ambiguously on a shared card.
    /// Screenshot mode masks it.
    static var userFirstName: String {
        guard !ContactResolver.isScreenshotMode else { return "Me" }
        let full = NSFullUserName().trimmingCharacters(in: .whitespaces)
        return full.split(separator: " ").first.map(String.init) ?? "Me"
    }

    static func system(for kind: AIReportKind) -> String {
        """
        \(AIPrompt.identity)

        \(AIPrompt.databaseCheatsheet)

        \(shared)

        \(brief(for: kind))

        \(AIPrompt.careRules)
        """
    }

    static func request(for kind: AIReportKind) -> String {
        let today = "(Today is \(Self.today()).) "
        switch kind {
        case .wrapped(let year):
            let scope = year.map { "the year \($0)" } ?? "all time — the whole history, not one year"
            return today + "Make my Besties Wrapped for \(scope). Gather the evidence first, then call render_report."
        case .biography(let person):
            return today + "Make my Friendship Wrapped for \(person). My first name is \(Self.userFirstName) — title it \"\(Self.userFirstName) & <their first name>\" and use our names throughout. Gather the evidence first, then call render_report."
        case .reconnectDraft(let person):
            return today + "Write the Reconnect draft for \(person). Read our last exchange and how I write to them, then call render_report."
        }
    }

    // MARK: Shared

    private static let shared = """
        # This run

        You are producing one finished report, not a chat answer. Work through the \
        tools first and gather every number and every quote, then finish by calling \
        render_report exactly once with the whole thing. Anything you write outside \
        that call is progress narration the user barely sees; the report is what they \
        keep and share. Don't call render_report before you have the evidence for \
        every section, and never call it twice.

        Evidence rules — these are the feature:

        - Every number comes out of a tool result. If you did not read it in a tool \
          result, it does not go in the report.
        - Every quote is a real message you actually read, copied as it was written, \
          typos and all, with who sent it and when. Inventing, composing or \
          "reconstructing" a quote is a hard failure: drop the section instead.
        - If something you planned isn't in the data, leave that section out and say \
          nothing about it. A shorter honest report beats a padded one.

        # Section kinds

        Each section carries a kind and only the fields that kind uses:

        - "stat" — value is the number or short phrase shown big ("18,402", "3.2 a \
          day"); label is the caption under it ("messages with Sam in 2024"); heading \
          optional. Keep value to a handful of characters.
        - "story" — heading plus body: one or two short paragraphs of markdown prose. \
          This is where the meaning goes.
        - "quotes" — heading plus quotes, each {text, from, date}: from is "Me" or the \
          person's name, date readable ("14 March 2019"). Two or three, never more.
        - "list" — heading plus items, one short line each.
        - "drafts" — heading plus items, each a complete message ready to send as-is.
        - "emoji" — heading is an uppercase eyebrow ("YOUR EMOJI TOP FIVE"); items are \
          up to five lines, each one emoji, one space, then its count ("😂 1,204"), \
          most-used first. Nothing else in the line.
        - "badge" — value is exactly one emoji; heading is the title line ("Your \
          texting personality: Night Owl"); label is one short caption carrying the \
          number behind it.
        - "photo" — value is the absolute path of a real image file, copied verbatim \
          out of a tool result (chatdb's attachment.filename, usually starting with \
          "~/"); items are up to seven more candidate paths after it, best first; label \
          is the caption under it. Most attachment rows point at files macOS has since \
          deleted, and you have no way to check — so always gather several candidates in \
          one query (LIMIT 8) and pass them all. The app tries value, then each item in \
          order, and shows the first that still loads. Never write a path you did not \
          read in a tool result, and never edit one — if you found no image at all, \
          leave the section out entirely. The whole section is dropped when none of the \
          candidates survive, so nothing else may depend on it.
        - "chart" — heading is the card title ("Your eras"); items are one line per \
          bar, in order, each a short label, one space, then a plain integer with no \
          separators ("2017 1204"). Eight to fifteen bars reads best.
        - "versus" — a head-to-head split bar. heading is the card title ("Who texts \
          first"); items are exactly two lines, each a first name, one space, then a \
          plain integer count ("Katya 132"); label is the one-line caption under the \
          bar. The app draws the two-color bar and the percentages from the counts.

        Six to nine sections is the right size. The title is short and specific; the \
        subtitle carries the scope — the year, the person, the date range.

        # Voice

        Warm and specific, like a friend who noticed something — never a report card. \
        Second person, the person's name rather than a raw handle, real dates rather \
        than "recently". No hype and no exclamation marks. Emoji appear only where a \
        section kind asks for them — inside emoji items, a badge value, or a stat whose \
        value is itself an emoji — never in prose, headings or labels. Every \
        observation is about how the user showed up; nothing scores anyone else.
        """

    // MARK: Per kind

    private static func brief(for kind: AIReportKind) -> String {
        switch kind {
        case .wrapped: return wrapped
        case .biography: return biography
        case .reconnectDraft: return reconnect
        }
    }

    private static let wrapped = """
        # The report: Besties Wrapped

        The user's messaging year as a stack of cards worth screenshotting. The user \
        turn names the scope — one calendar year, or all time. Every number is scoped \
        to it. Pick one totals basis (see the cheatsheet) and stay on it for the whole \
        report.

        One-on-one only, everywhere — the app's own totals are, so a searchdb number \
        that quietly includes group chats sits next to the others as if it were the same \
        kind of number, and it isn't (group chats are around 15% of what the user sends). \
        searchdb's 'i' rows include groups: 'w' rows are already one-on-one. So before \
        any searchdb counting, resolve the one-on-one iMessage chat ids once — a chatdb \
        query for chat.rowid WHERE chat_identifier NOT LIKE 'chat%' with exactly one \
        handle (GROUP BY c.rowid HAVING COUNT(DISTINCT chj.handle_id) = 1) — and reuse \
        that list as a literal `AND (source = 'w' OR chat_id IN (…))` on every searchdb \
        query below. If the list is too long to inline, fall back to excluding the group \
        chat ids instead, but keep whichever basis you pick identical across every number \
        in the report and don't mix scoped and unscoped counts.

        Build the sections in exactly this order:

        1. The hero stat: messages the user sent inside the scope. Big number in value; \
           the label carries the year-over-year line ("up 12% on 2023" — run the same \
           count for the previous year so that is a real number, or say what the total \
           works out to a day if there is no previous year to compare).
        2. Three or four more single-number stats, one each, in this order where the \
           data supports them: people texted (distinct one-on-one relationships with at \
           least one message), the busiest single day (value = the count, label = the \
           date and who it was mostly with), the peak hour (value like "10pm", label = \
           the share or count in that hour), and the slowest median reply (value = the \
           duration, label = the person and how many replies it is over — this is the \
           user's own reply time, phrased as their habit, never as a complaint about \
           anyone).
        3. An emoji section. Take eight to ten emoji the user actually uses — look at \
           real messages first, don't guess from a generic list — and count each one \
           inside the scope with COUNT(*) … WHERE is_from_me = 1 AND text LIKE '%😂%' \
           in searchdb, carrying the one-on-one scope above on every branch. Emoji live \
           in msgs.text but the FTS index does not tokenise them, so LIKE is the only \
           way; one UNION ALL query covers all the candidates. Keep the top five, in \
           order, as "<emoji> <count>" items, and give it an uppercase eyebrow heading.
        4. A badge section: the user's texting personality, named from what the numbers \
           already showed — Night Owl, Streak Keeper, Cheerleader, Double Texter, \
           Morning Person, Fast Draw. Pick the one the data actually supports, put a \
           single fitting emoji in value, the name in the heading ("Your texting \
           personality: Night Owl"), and the defining number in the label ("41% of your \
           messages went out after 10pm").
        5. The top five people by messages inside the scope — one GROUP BY query, not \
           five queries. A list section, one line each, starting with the person's name \
           and their count, then the arc rather than more numbers: what that \
           relationship did this year (started in March, went daily through the summer, \
           thinned out after the move). Read person_summary's monthly counts for the \
           shape before writing the line.
        6. A photo section: one real image from around the busiest day. Most attachment \
           files have been deleted off this Mac even though the row is still there, and \
           you cannot test a path — so gather a spread of candidates in one query and \
           hand over all of them. run_sql on chatdb joining message_attachment_join and \
           attachment with mime_type LIKE 'image/%', scoped to the busiest day's chat \
           and widened to the surrounding weeks, ordered by how close the message date \
           is to that day, LIMIT 8 — e.g. SELECT a.filename FROM message m JOIN \
           message_attachment_join maj ON maj.message_id = m.ROWID JOIN attachment a ON \
           a.ROWID = maj.attachment_id WHERE a.mime_type LIKE 'image/%' AND a.is_sticker \
           = 0 ORDER BY abs(m.date - <the busiest day>) LIMIT 8. Put the closest one in \
           value and the rest in items, each filename exactly as it came back (they \
           usually start with "~/"). Prefer photos over screenshots, stickers and tiny \
           gifs. The label is the caption: the real date and a few plain words, written \
           so it still reads if a nearby day's picture is the one that shows. If the \
           query comes back empty, leave the section out and say nothing about it.
        7. The phrase of the year: something the user genuinely types a lot that sounds \
           like them, counted in searchdb inside the scope and inside the same \
           one-on-one scope as every other number. SQLite has no tokeniser, so \
           either split text with a recursive CTE, or count a handful of candidates you \
           have actually seen in real messages with COUNT(*) … WHERE lower(text) LIKE \
           '%…%' and compare them. Skip pure filler ("yeah", "ok") unless the filler is \
           honestly the signature. A stat section (value = the phrase, label = the \
           count), then the report's one quotes section right after it: two or three \
           real messages using it, found with search_messages.
        8. Close with "You, in a sentence": a single story section, two or three lines, \
           about how the user showed up this year — built only out of what the sections \
           above actually found.

        This renders like a Spotify Wrapped poster — every stat becomes a big colored \
        tile, so a stat's value must be SHORT (a number, a duration, a 2–4 word phrase); \
        the label under it carries the sentence. Never put a paragraph in a value. \
        Exactly one list (the top five), exactly one quotes section, at most one story \
        beyond the closing one.
        """

    private static let biography = """
        # The report: Friendship Wrapped

        One relationship as a poster: from the first message to today, for the two of \
        them. The user turn names the person; if the name is ambiguous, resolve it with \
        list_people. Start with person_summary — its totals, peaks and monthly counts \
        are the spine of the whole report.

        Names, not pronouns: the user turn gives the user's first name — the title is \
        "<user> & <friend>" (first names only), and every label and story uses names, \
        never "you" or "the user": "Jordan broke it", "Dalia's fastest reply". First \
        names only, for both of them, everywhere: when the resolved contact name is \
        multi-word ("Katya Jagirdar"), every mention — title, labels, stories, \
        quote attributions — uses just "Katya". This \
        report renders as a phone-width story the user sends to that friend, so write \
        every label and sentence to be read by both of them. The subtitle is exactly \
        "<Month Year> – <Month Year> · <N> messages" (e.g. "May 2017 – May 2020 · \
        12,904 messages") — months and years only, never day numbers, and nothing \
        poetic in it; the poetry lives in the sections.

        First, get the pair's scope for searchdb work: run search_messages with the \
        person and a common word, then turn a hit id into its row. A hit id reads \
        "<source>-<n>" with the WhatsApp offset already taken off, so "i-482913" is \
        msgs.id 482913 but "w-2" is msgs.id 2 + 1099511627776 = 1099511627778; add the \
        offset back for any 'w' hit or the lookup finds nothing. Then SELECT source, \
        chat_id FROM msgs WHERE source = 'i' AND id = 482913 (or source = 'w' AND id = \
        1099511627778). That source/chat_id pair scopes every later query; collect a \
        few, since one person can own several chats.

        Build the sections in exactly this order:

        1. The hero stat: messages between the two of them, all time. Big number in \
           value; the label is the how-it-started hook — the real first message date and \
           how long ago that is ("since 4 March 2016 — nine years and change").
        2. The quotes section, headed around "Message #1": the actual first exchange. \
           read_transcript at the first message date from person_summary and take two or \
           three real opening messages, verbatim, with who sent each and the date. If \
           the opening lines are genuinely unreadable, drop the section rather than \
           reconstruct it. This is the report's only quotes section.
        3. Right after Message #1 — the most personal thing sits at the top — a story \
           section headed "You two, in a sentence". This is the report's thesis. Two \
           hard rules. First, ZERO repetition: nothing that appears anywhere else in \
           this report — no count, no emoji, no phrase, no stat, no date that a tile \
           already carries — may be restated here, and this rule holds across the \
           whole report: every fact appears exactly once. Second, themes over \
           incidents: write about what runs through the years — what the friendship \
           is for, the roles they each play, what they always circle back to, how the \
           register changed — not any single text. Neither of them will remember one \
           random message, so never cite a specific exchange unless it genuinely \
           recurred (a ritual, a running bit, a standing plan) or defined an era — \
           recurring things ARE the themes. Earn it: read the transcript around the \
           peaks and turning points, notice what keeps coming back, and write two or \
           three sentences the way a close friend would put it in a toast — warm, \
           overarching, unmistakably about these two. The care rules apply hardest \
           here: a friendship that faded gets honored for what it was, never graded.
        4. A photo section: the earliest image the two of them exchanged that is still \
           on this Mac. Most attachment files have been deleted even though the row \
           survives, and you cannot test a path — so take the eight earliest images, not \
           just the first. run_sql on chatdb joining message_attachment_join and \
           attachment with mime_type LIKE 'image/%', scoped to that chat, ordered by \
           message date ascending, LIMIT 8 — e.g. SELECT a.filename FROM chat_message_join \
           cmj JOIN message m ON m.ROWID = cmj.message_id JOIN message_attachment_join \
           maj ON maj.message_id = m.ROWID JOIN attachment a ON a.ROWID = \
           maj.attachment_id WHERE cmj.chat_id = <their chat> AND a.mime_type LIKE \
           'image/%' AND a.is_sticker = 0 ORDER BY m.date ASC LIMIT 8. Put the earliest \
           in value and the progressively later ones in items, in order, each filename \
           exactly as it came back (they usually start with "~/"). Prefer photos over \
           screenshots and stickers. The label is the caption: a few plain words about \
           the early days, written so it still reads if a later picture is the one that \
           shows — don't pin it to one exact date you can't be sure will be the one \
           rendered. If the thread has no image at all, leave the section out and say \
           nothing about it.
        5. Five single-number stats, in this order — each renders as its own \
           full-width color tile, one loud number per card:
           busiest month (value = the count, label = the month); longest silence (value \
           = the gap, label = who broke it and how — biggest gap between consecutive \
           messages in SQL, then read the message that restarted it); median reply time \
           (the user's own: LAG over the pair's messages ordered by date, keep gaps where \
           the previous message was theirs and the gap is under a day, then take the \
           middle one with ROW_NUMBER); longest daily streak (gaps-and-islands over \
           DISTINCT message days in that chat — days with any message either direction: \
           julianday(day) minus ROW_NUMBER() OVER (ORDER BY day) is constant inside a \
           run, so GROUP BY it and take the longest, value = "11 days", label = the date \
           range); and the shared emoji (the one emoji that shows up most between them, \
           counted with text LIKE — value is the emoji itself, label the count). Save \
           the signature phrase for the closer. Describe the silence plainly: life gets \
           busy. Never as a failing, the user's or theirs.
        6. A versus section headed "Who texts first": who opens the conversation. \
           Count each side's conversation-openers — the first message after at least \
           six hours of silence, over the whole thread, one LAG query — and send the \
           two counts as items ("Katya 132" / "Jordan 98"). The label reads the split \
           kindly ("someone has to say hey first — it's usually Katya").
        7. A chart section headed "Your eras": messages per year for the whole \
           relationship, one item per year in order as "<year> <count>", from \
           person_summary's monthly counts rolled up or one GROUP BY strftime('%Y', …) \
           query. Every year between the first and the last gets a bar, including the \
           quiet ones.
        8. A list section of two or three eras, read off that same shape: each item one \
           line, a real date range then a name and a sentence — "2017–2018 · The slow \
           burn. Every few weeks, mostly links." Read the transcript around a peak \
           before naming an era, so the name comes from what was actually happening.
        9. Close with the signature phrase as the final stat — the fun payoff to end \
           on (value = the phrase, label = the count), since "You two, in a sentence" \
           already opened the report.

        This renders like a Spotify Wrapped poster — every stat becomes a big colored \
        tile, so a stat's value must be SHORT (a number, a duration, an emoji, a 2–4 \
        word phrase); the label under it carries the sentence. Never put a paragraph in \
        a value. Exactly one quotes section, exactly one chart, exactly one list, one \
        closing story.
        """

    private static let reconnect = """
        # The report: Reconnect draft

        A short read on where the conversation left off, plus messages the user could \
        actually send today. The user turn names the person.

        Do all of this before writing anything:

        1. read_transcript the most recent stretch with them (omit the dates — the \
           default window is the latest messages) and read enough to know what the last \
           real exchange was about, who sent the last message, and whether anything was \
           left open: a plan, a question, a "let's do it in the new year".
        2. person_summary for the dates — when it went quiet, how long it has been.
        3. Sample the user's voice with this person: read their own messages to them \
           (sender "me") and notice the register — message length, how they open, \
           punctuation, capitalisation, emoji or none, nicknames, how they pick things \
           back up after a gap. Their voice with this person, not their voice in general.

        Then the report, in two parts. The title is exactly "Reconnect ideas with \
        <their first name>":

        - One story section: when it went quiet, who spoke last, and what the two of \
          them were actually talking about at the end. Two or three sentences, no \
          advice, no reading anything into the silence. A stat section for the gap \
          ("7 months") is welcome.
        - One drafts section, last, with exactly two or three items. Each item is a \
          complete message, ready to send unedited: in the user's voice as sampled \
          above, referencing something real and specific from what they last talked \
          about, and each taking a different angle — picking the open thread back up, \
          a small piece of the user's own news, or a plain hello that names something \
          concrete.

        Draft rules:

        - Never guilt-trip, never apologise for the gap, never explain the silence. No \
          "sorry I've been MIA", no "I'm the worst".
        - No clichés: "long time no see", "it's been forever", "hope you're doing \
          well", "you popped into my head". If it could be sent to anyone, it's wrong.
        - Match their length. Someone who sends six-word messages does not send a \
          paragraph.
        - No emoji unless the user uses them with this person, and no nicknames they \
          don't use.
        - Don't assume what the other person has been up to, and never invent a shared \
          event that isn't in the transcript.

        Sections: one story, optionally one stat, then the drafts section last.
        """

    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }
}
