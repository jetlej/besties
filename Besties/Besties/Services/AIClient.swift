import Foundation

/// Token counts for one `ask()` — summed across every request the tool loop
/// made, so the UI can show a single cost per answer.
struct AIUsage {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
}

enum AIStreamEvent {
    case textDelta(String)
    /// `summary` is human-readable, e.g. `searched "ramen"`.
    case toolStarted(name: String, summary: String)
    case toolFinished(name: String)
    case turnCompleted(turnID: UUID, usage: AIUsage, stopReason: String)
    case failed(message: String)
}

/// The SSE streaming client and the tool loop, shared by the chat and by the
/// packaged reports. One instance owns one raw API `messages` array; what the
/// two callers differ on lives in `Config` — the system prompt (the top-level
/// `system` field: a cached, frozen prefix, so today's date rides on the user
/// turn instead), the token ceiling, and whether one tool ends the run rather
/// than being executed.
@MainActor
final class AIToolLoop {
    struct Config {
        var systemPrompt: String
        var maxTokens: Int
        /// Definitions appended to the toolbox's own — tools this loop answers
        /// itself rather than dispatching to `AIToolbox`.
        var extraTools: [[String: Any]] = []
        /// A tool_use for this name ends the run: the caller gets its input and
        /// no tool_result goes back, so the model's last word can be structured.
        var terminalTool: String?
        /// Runaway guard: a well-behaved answer needs a handful of tool rounds.
        var maxToolRounds = 25
    }

    /// The terminal tool's call. `id` is what a continuation has to answer with
    /// a tool_result, since the assistant turn holding it is already in history.
    struct TerminalCall {
        let id: String
        let input: [String: Any]
    }

    struct Outcome {
        var stopReason = "end_turn"
        var usage = AIUsage()
        var toolCallCount = 0
        var terminal: TerminalCall?
        /// Every tool_use id in the assistant turn that ended the run: the
        /// terminal call's own, plus anything the model asked for alongside it.
        /// None were executed, and the API needs a tool_result for *every* one of
        /// them in the next user message — answering only the terminal call makes
        /// the continuation invalid.
        var unansweredToolIDs: [String] = []
        /// True when `.failed` was emitted. The history is unusable past this
        /// point; the caller owns what to roll back to.
        var failed = false
    }

    private let apiKey: String
    private let backend: AIBackend
    private let toolbox: AIToolbox
    private let config: Config

    /// OpenRouter's sticky-routing key: pins every request from this loop to
    /// the provider (Anthropic / Bedrock / Vertex / …) that holds its prompt
    /// cache, from the first request on. Without it OpenRouter only sticks
    /// after it has already seen a cache hit, so round two can land on another
    /// provider and pay to write the whole prefix again. Random, so it carries
    /// nothing about the user.
    private let sessionID = UUID().uuidString

    /// The raw API history — JSON-serializable by construction. The caller
    /// appends the user turn before `run` and decides what to keep after it.
    var messages: [[String: Any]] = []

    /// `AIUsageLog` numbers requests within a turn, and one turn can span more
    /// than one `run` (a report that needs a nudge), so the counters follow the
    /// turn id rather than the call — including the runaway guard, or a nudged
    /// report would get `maxToolRounds` all over again.
    private var sequenceTurnID: UUID?
    private var sequence = 0
    private var rounds = 0

    init(apiKey: String, toolbox: AIToolbox, config: Config) {
        self.apiKey = apiKey
        self.backend = AIBackend(apiKey: apiKey)
        self.toolbox = toolbox
        self.config = config
    }

    /// Streams turns and runs tools until the model stops asking for them.
    /// Never throws: every failure arrives as `.failed` and sets `failed`.
    /// `.turnCompleted` is the caller's to emit — it owns the turn.
    func run(turnID: UUID, onEvent: @escaping (AIStreamEvent) -> Void) async -> Outcome {
        if sequenceTurnID != turnID {
            sequenceTurnID = turnID
            sequence = 0
            rounds = 0
        }

        var outcome = Outcome()

        func fail(_ message: String, _ stopReason: String) -> Outcome {
            onEvent(.failed(message: message))
            outcome.stopReason = stopReason
            outcome.failed = true
            return outcome
        }

        while true {
            let turn: Turn
            let requestStart = Date()
            do {
                turn = try await streamTurn(onEvent: onEvent)
            } catch {
                return fail(Self.describe(error), (error as? AIClientError)?.stopReason ?? "error")
            }

            sequence += 1
            AIUsageLog.recordRequest(
                turnID: turnID, sequence: sequence, usage: turn.usage,
                latencyMs: Int(Date().timeIntervalSince(requestStart) * 1000))

            outcome.usage.inputTokens += turn.usage.inputTokens
            outcome.usage.outputTokens += turn.usage.outputTokens
            outcome.usage.cacheReadTokens += turn.usage.cacheReadTokens
            outcome.usage.cacheCreationTokens += turn.usage.cacheCreationTokens
            messages.append(["role": "assistant", "content": turn.content])

            switch turn.stopReason {
            case "tool_use":
                // The terminal tool is the answer, not a step: stop here and
                // leave it unanswered so nothing follows it.
                if let terminal = config.terminalTool,
                   let call = turn.toolCalls.first(where: { $0.name == terminal }) {
                    outcome.terminal = TerminalCall(id: call.id, input: call.input)
                    // Anything called alongside it goes unanswered too, so the
                    // caller knows the full set a continuation has to answer.
                    outcome.unansweredToolIDs = turn.toolCalls.map(\.id)
                    outcome.stopReason = turn.stopReason
                    return outcome
                }

                rounds += 1
                if rounds > config.maxToolRounds {
                    return fail("Stopped after \(config.maxToolRounds) rounds of tool calls without an answer.", "tool_limit")
                }
                var results: [[String: Any]] = []
                for call in turn.toolCalls {
                    onEvent(.toolStarted(name: call.name, summary: Self.summary(name: call.name, input: call.input)))
                    var output = await toolbox.execute(name: call.name, input: call.input)
                    onEvent(.toolFinished(name: call.name))
                    outcome.toolCallCount += 1
                    // Oversized results stay in the conversation for every later
                    // round, so cap them — the model can always re-query narrower.
                    if output.count > 30_000 {
                        output = String(output.prefix(30_000))
                            + "\n…[truncated — the full result was \(output.count) characters; run a narrower query]"
                    }
                    results.append(["type": "tool_result", "tool_use_id": call.id, "content": output])
                }
                // Every tool_result for one assistant turn goes back in a single
                // user message, or the model stops making parallel calls.
                messages.append(["role": "user", "content": results])

            case "max_tokens":
                return fail("The answer was cut off — it hit the length limit. Ask for a narrower slice and it'll fit.", "max_tokens")

            case "refusal":
                return fail(AIClientError.refusal(turn.refusalExplanation).message, "refusal")

            default:
                outcome.stopReason = turn.stopReason
                return outcome
            }
        }
    }

    // MARK: - One request

    private struct ToolCall {
        let id: String
        let name: String
        let input: [String: Any]
    }

    private struct Turn {
        /// The assistant content blocks, verbatim, to append to the history —
        /// thinking blocks included, since they have to be echoed back
        /// unchanged when the turn continues with tool results.
        var content: [[String: Any]] = []
        var toolCalls: [ToolCall] = []
        var stopReason = "end_turn"
        var refusalExplanation: String?
        var usage = AIUsage()
    }

    private func streamTurn(onEvent: @escaping (AIStreamEvent) -> Void) async throws -> Turn {
        // Moving cache breakpoint on the last content block: each round then
        // re-reads the whole prior conversation at the cached rate instead of
        // full input price — on long tool loops that is most of the bill.
        // (Value semantics: this never mutates the stored history.)
        var requestMessages = messages
        if var last = requestMessages.last,
           var content = last["content"] as? [[String: Any]],
           var block = content.last {
            block["cache_control"] = ["type": "ephemeral"]
            content[content.count - 1] = block
            last["content"] = content
            requestMessages[requestMessages.count - 1] = last
        }

        var body: [String: Any] = [
            "model": backend.model,
            "max_tokens": config.maxTokens,
            "stream": true,
            "system": [[
                "type": "text",
                "text": config.systemPrompt,
                "cache_control": ["type": "ephemeral"],
            ]],
            "messages": requestMessages,
        ]
        let tools = toolbox.toolDefinitions + config.extraTools
        if !tools.isEmpty { body["tools"] = tools }

        var request = URLRequest(url: backend.endpoint)
        request.httpMethod = "POST"
        switch backend {
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openRouter:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
            body["session_id"] = sessionID
        }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (stream, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let error = try await Self.errorBody(from: stream)
            // OpenRouter reports a provider-side refusal as an HTTP error rather
            // than as stop_reason "refusal"; treat it the same.
            if error?["error_type"] as? String == "refusal" {
                throw AIClientError.refusal(error?["message"] as? String)
            }
            throw AIClientError.http(status: http.statusCode, message: error?["message"] as? String, backend: backend)
        }

        var turn = Turn()
        var builders: [Int: BlockBuilder] = [:]

        for try await line in stream.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "message_start":
                if let message = event["message"] as? [String: Any] {
                    Self.absorbUsage(message["usage"] as? [String: Any], into: &turn.usage)
                }

            case "content_block_start":
                if let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] {
                    builders[index] = BlockBuilder(block: block)
                }

            case "content_block_delta":
                guard let index = event["index"] as? Int,
                      let delta = event["delta"] as? [String: Any],
                      var builder = builders[index] else { continue }
                switch delta["type"] as? String {
                case "text_delta":
                    let chunk = delta["text"] as? String ?? ""
                    builder.text += chunk
                    if !chunk.isEmpty { onEvent(.textDelta(chunk)) }
                case "input_json_delta":
                    builder.partialJSON += delta["partial_json"] as? String ?? ""
                case "thinking_delta":
                    builder.thinking += delta["thinking"] as? String ?? ""
                case "signature_delta":
                    builder.signature += delta["signature"] as? String ?? ""
                default:
                    break
                }
                builders[index] = builder

            case "message_delta":
                if let delta = event["delta"] as? [String: Any] {
                    if let stop = delta["stop_reason"] as? String { turn.stopReason = stop }
                    if let details = delta["stop_details"] as? [String: Any] {
                        turn.refusalExplanation = details["explanation"] as? String
                    }
                }
                Self.absorbUsage(event["usage"] as? [String: Any], into: &turn.usage)

            case "error":
                let error = event["error"] as? [String: Any]
                if error?["error_type"] as? String == "refusal" {
                    throw AIClientError.refusal(error?["message"] as? String)
                }
                throw AIClientError.api(error?["message"] as? String ?? "The stream failed.")

            default:
                break
            }
        }

        for index in builders.keys.sorted() {
            guard let block = builders[index]?.finished() else { continue }
            turn.content.append(block)
            if block["type"] as? String == "tool_use",
               let id = block["id"] as? String, let name = block["name"] as? String {
                turn.toolCalls.append(ToolCall(id: id, name: name, input: block["input"] as? [String: Any] ?? [:]))
            }
        }
        return turn
    }

    /// Accumulates one streamed content block. Tool inputs arrive as JSON text
    /// fragments and are parsed once complete — never string-matched.
    private struct BlockBuilder {
        var block: [String: Any]
        var text = ""
        var partialJSON = ""
        var thinking = ""
        var signature = ""

        func finished() -> [String: Any] {
            var out = block
            switch block["type"] as? String {
            case "text":
                out["text"] = text
            case "tool_use":
                let data = partialJSON.data(using: .utf8) ?? Data()
                out["input"] = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            case "thinking":
                out["thinking"] = thinking
                if !signature.isEmpty { out["signature"] = signature }
            default:
                break
            }
            return out
        }
    }

    // MARK: - Plumbing

    /// message_start and message_delta both report the running totals for the
    /// same message, so the later report wins rather than adding to the earlier.
    /// A null field (OpenRouter's message_delta sends `input_tokens: null`)
    /// fails the `as? Int` and keeps the earlier value.
    private static func absorbUsage(_ usage: [String: Any]?, into turn: inout AIUsage) {
        guard let usage else { return }
        if let input = usage["input_tokens"] as? Int { turn.inputTokens = input }
        if let output = usage["output_tokens"] as? Int { turn.outputTokens = output }
        if let cached = usage["cache_read_input_tokens"] as? Int { turn.cacheReadTokens = cached }
        if let written = usage["cache_creation_input_tokens"] as? Int { turn.cacheCreationTokens = written }
    }

    /// A failed request's `error` object — `message`, plus OpenRouter's
    /// canonical `error_type` when it came through OpenRouter.
    private static func errorBody(from stream: URLSession.AsyncBytes) async throws -> [String: Any]? {
        var data = Data()
        for try await byte in stream {
            data.append(byte)
            if data.count > 8_192 { break }
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["error"] as? [String: Any]
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let error as AIClientError:
            return error.message
        case let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost:
            return "No internet connection."
        case let error as URLError where error.code == .timedOut:
            return "The request timed out."
        case let error as URLError:
            return "Network error: \(error.localizedDescription)"
        default:
            return error.localizedDescription
        }
    }

    /// Human-readable one-liner for the tool-activity row.
    private static func summary(name: String, input: [String: Any]) -> String {
        func arg(_ key: String) -> String? {
            guard let value = input[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        switch name {
        case "search_messages":
            let query = arg("query") ?? ""
            return arg("person").map { "searched \"\(query)\" with \($0)" } ?? "searched \"\(query)\""
        case "semantic_search":
            let query = arg("query") ?? ""
            return arg("person").map { "recalled \"\(query)\" with \($0)" } ?? "recalled \"\(query)\""
        case "read_transcript":
            return "read messages with \(arg("person") ?? "someone")"
        case "person_summary":
            return "looked up \(arg("person") ?? "someone")"
        case "list_people":
            return arg("filter").map { "listed people matching \"\($0)\"" } ?? "listed people"
        case "run_sql":
            return "queried the \(arg("db") ?? "message") database"
        default:
            let action = name.replacingOccurrences(of: "_", with: " ")
            let first = input.values.compactMap { $0 as? String }.first
            return first.map { "\(action): \($0)" } ?? action
        }
    }
}

/// One in-memory conversation with the Anthropic Messages API: the chat's
/// wrapper around `AIToolLoop`, holding the history between questions.
@MainActor
final class AIChatSession {
    private static let maxTokens = 16_000

    private let loop: AIToolLoop

    private(set) var isRunning = false

    init(apiKey: String, toolbox: AIToolbox) {
        loop = AIToolLoop(apiKey: apiKey, toolbox: toolbox,
                          config: .init(systemPrompt: AIPrompt.systemPrompt, maxTokens: Self.maxTokens))
    }

    func reset() {
        loop.messages.removeAll()
    }

    /// The raw API history, for persistence — JSON-serializable by construction.
    var history: [[String: Any]] { loop.messages }

    /// Swaps in a previously saved history so a reopened chat keeps its context.
    func restore(history: [[String: Any]]) {
        guard !isRunning else { return }
        loop.messages = history
    }

    /// Asks one question and runs the whole tool loop, emitting events as they
    /// stream. Never throws: every failure arrives as `.failed`. On failure the
    /// history is rolled back to before the question, so a retry starts clean.
    func ask(_ text: String, onEvent: @escaping (AIStreamEvent) -> Void) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let snapshot = loop.messages
        loop.messages.append([
            "role": "user",
            "content": [["type": "text", "text": "(Today is \(Self.today()).) " + text]],
        ])

        let turnID = UUID()
        let outcome = await loop.run(turnID: turnID, onEvent: onEvent)

        // Any exit that isn't a finished answer leaves the history unusable — an
        // assistant turn holding tool_use blocks with no tool_result after it, or
        // a block the stream cut in half — and the API rejects every later turn.
        // Roll back to before the question instead.
        if outcome.failed { loop.messages = snapshot }
        onEvent(.turnCompleted(turnID: turnID, usage: outcome.usage, stopReason: outcome.stopReason))
    }

    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }
}

/// Where requests go, picked by key prefix. An OpenRouter key (`sk-or-…`)
/// goes to OpenRouter's Anthropic-compatible `/messages` endpoint; anything
/// else (`sk-ant-…`) goes to Anthropic directly. The wire format is the same
/// Messages API either way — body, cache_control breakpoints, SSE events,
/// usage fields — so only the URL, auth header and model slug differ.
private enum AIBackend {
    case anthropic
    case openRouter

    init(apiKey: String) {
        self = apiKey.hasPrefix("sk-or-") ? .openRouter : .anthropic
    }

    var endpoint: URL {
        switch self {
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/messages")!
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1/messages")!
        }
    }

    var model: String {
        switch self {
        case .anthropic: return "claude-opus-5"
        case .openRouter: return "anthropic/claude-opus-5"
        }
    }

    var name: String {
        switch self {
        case .anthropic: return "Anthropic's API"
        case .openRouter: return "OpenRouter"
        }
    }
}

private enum AIClientError: Error {
    case http(status: Int, message: String?, backend: AIBackend)
    case api(String)
    case refusal(String?)

    var message: String {
        switch self {
        case .http(let status, let message, let backend):
            let detail = message.map { ": \($0)" } ?? ""
            switch (status, backend) {
            case (401, _), (403, .anthropic): return "The API key was rejected\(detail)."
            // OpenRouter: the key's spend limit (or the account's credit) is used up.
            case (402, _): return "Out of AI credit\(detail)."
            // OpenRouter: a guardrail or content filter blocked it — not the key.
            case (403, .openRouter): return "The request was blocked\(detail)."
            case (429, _): return "Rate limited — wait a moment and try again\(detail)."
            case (500...599, _): return "\(backend.name) is having trouble (\(status))\(detail)."
            default: return "The request failed (\(status))\(detail)."
            }
        case .api(let message):
            return message
        case .refusal(let explanation):
            let why = explanation.map { " (\($0))" } ?? ""
            return "Claude couldn't answer that one\(why). Try rephrasing it."
        }
    }

    /// The `Outcome.stopReason` a thrown error ends the run with.
    var stopReason: String {
        if case .refusal = self { return "refusal" }
        return "error"
    }
}
