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

/// One in-memory conversation with the Anthropic Messages API, streaming over
/// SSE and running the tool loop against `AIToolbox`. The session owns the raw
/// API `messages` array; the system prompt is the top-level `system` field (a
/// cached, frozen prefix), so today's date rides on the user turn instead.
@MainActor
final class AIChatSession {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-opus-5"
    private static let maxTokens = 16_000
    /// Runaway guard: a well-behaved answer needs a handful of tool rounds.
    private static let maxToolRounds = 25

    private let apiKey: String
    private let toolbox: AIToolbox
    private var messages: [[String: Any]] = []

    private(set) var isRunning = false

    init(apiKey: String, toolbox: AIToolbox) {
        self.apiKey = apiKey
        self.toolbox = toolbox
    }

    func reset() {
        messages.removeAll()
    }

    /// The raw API history, for persistence — JSON-serializable by construction.
    var history: [[String: Any]] { messages }

    /// Swaps in a previously saved history so a reopened chat keeps its context.
    func restore(history: [[String: Any]]) {
        guard !isRunning else { return }
        messages = history
    }

    /// Asks one question and runs the whole tool loop, emitting events as they
    /// stream. Never throws: every failure arrives as `.failed`. On failure the
    /// history is rolled back to before the question, so a retry starts clean.
    func ask(_ text: String, onEvent: @escaping (AIStreamEvent) -> Void) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let snapshot = messages
        messages.append([
            "role": "user",
            "content": [["type": "text", "text": "(Today is \(Self.today()).) " + text]],
        ])

        let turnID = UUID()
        var usage = AIUsage()
        var rounds = 0
        var requests = 0

        // Any exit that isn't a finished answer leaves the history unusable — an
        // assistant turn holding tool_use blocks with no tool_result after it, or
        // a block the stream cut in half — and the API rejects every later turn.
        // Roll back to before the question instead.
        func bail(_ message: String, stopReason: String) {
            messages = snapshot
            onEvent(.failed(message: message))
            onEvent(.turnCompleted(turnID: turnID, usage: usage, stopReason: stopReason))
        }

        while true {
            let turn: Turn
            let requestStart = Date()
            do {
                turn = try await streamTurn(onEvent: onEvent)
            } catch {
                bail(Self.describe(error), stopReason: "error")
                return
            }

            requests += 1
            AIUsageLog.recordRequest(
                turnID: turnID, sequence: requests, usage: turn.usage,
                latencyMs: Int(Date().timeIntervalSince(requestStart) * 1000))

            usage.inputTokens += turn.usage.inputTokens
            usage.outputTokens += turn.usage.outputTokens
            usage.cacheReadTokens += turn.usage.cacheReadTokens
            usage.cacheCreationTokens += turn.usage.cacheCreationTokens
            messages.append(["role": "assistant", "content": turn.content])

            switch turn.stopReason {
            case "tool_use":
                rounds += 1
                if rounds > Self.maxToolRounds {
                    bail("Stopped after \(Self.maxToolRounds) rounds of tool calls without an answer.", stopReason: "tool_limit")
                    return
                }
                var results: [[String: Any]] = []
                for call in turn.toolCalls {
                    onEvent(.toolStarted(name: call.name, summary: Self.summary(name: call.name, input: call.input)))
                    var output = await toolbox.execute(name: call.name, input: call.input)
                    onEvent(.toolFinished(name: call.name))
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
                bail("The answer was cut off — it hit the length limit. Ask for a narrower slice and it'll fit.", stopReason: "max_tokens")
                return

            case "refusal":
                let why = turn.refusalExplanation.map { " (\($0))" } ?? ""
                bail("Claude couldn't answer that one\(why). Try rephrasing it.", stopReason: "refusal")
                return

            default:
                onEvent(.turnCompleted(turnID: turnID, usage: usage, stopReason: turn.stopReason))
                return
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
            "model": Self.model,
            "max_tokens": Self.maxTokens,
            "stream": true,
            "system": [[
                "type": "text",
                "text": AIPrompt.systemPrompt,
                "cache_control": ["type": "ephemeral"],
            ]],
            "messages": requestMessages,
        ]
        let tools = toolbox.toolDefinitions
        if !tools.isEmpty { body["tools"] = tools }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (stream, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw AIClientError.http(status: http.statusCode, message: try await Self.errorMessage(from: stream))
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
    private static func absorbUsage(_ usage: [String: Any]?, into turn: inout AIUsage) {
        guard let usage else { return }
        if let input = usage["input_tokens"] as? Int { turn.inputTokens = input }
        if let output = usage["output_tokens"] as? Int { turn.outputTokens = output }
        if let cached = usage["cache_read_input_tokens"] as? Int { turn.cacheReadTokens = cached }
        if let written = usage["cache_creation_input_tokens"] as? Int { turn.cacheCreationTokens = written }
    }

    /// A failed request's body, for the error message.
    private static func errorMessage(from stream: URLSession.AsyncBytes) async throws -> String? {
        var data = Data()
        for try await byte in stream {
            data.append(byte)
            if data.count > 8_192 { break }
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
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

    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
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

private enum AIClientError: Error {
    case http(status: Int, message: String?)
    case api(String)

    var message: String {
        switch self {
        case .http(let status, let message):
            let detail = message.map { ": \($0)" } ?? ""
            switch status {
            case 401, 403: return "The API key was rejected\(detail)."
            case 429: return "Rate limited — wait a moment and try again\(detail)."
            case 500...599: return "Anthropic's API is having trouble (\(status))\(detail)."
            default: return "The request failed (\(status))\(detail)."
            }
        case .api(let message):
            return message
        }
    }
}
