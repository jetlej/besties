import Foundation
import os

/// JSON lines appended to `~/Library/Application Support/Besties/ai-usage.jsonl`
/// — one `"kind": "request"` line per HTTP request and one `"kind": "turn"`
/// summary per question, tied together by `turnID`. This file is the
/// prototype's pricing evidence — cost and latency per question — so writing it
/// must never disturb a turn: every failure is swallowed into os_log.
enum AIUsageLog {
    /// The only model the prototype uses; recorded so the file stays readable
    /// if that ever changes.
    static let model = "claude-opus-5"

    private static let logger = Logger(subsystem: "com.besties.app", category: "AIUsageLog")
    private static let queue = DispatchQueue(label: "com.besties.app.ai-usage")

    private static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// One request inside a turn: `sequence` is 1-based within `turnID`, and
    /// `latencyMs` covers just this HTTP request's stream.
    static func recordRequest(turnID: UUID, sequence: Int, usage: AIUsage, latencyMs: Int) {
        write([
            "kind": "request",
            "turnID": turnID.uuidString,
            "sequence": sequence,
            "inputTokens": usage.inputTokens,
            "outputTokens": usage.outputTokens,
            "cacheReadTokens": usage.cacheReadTokens,
            "cacheCreationTokens": usage.cacheCreationTokens,
            "latencyMs": latencyMs,
        ])
    }

    /// The turn summary. `latencyMs` is measured around the whole `ask()`, tool
    /// rounds included, and the token counts are the sum of its requests.
    static func record(turnID: UUID, usage: AIUsage, stopReason: String, latencyMs: Int, toolCallCount: Int) {
        write([
            "kind": "turn",
            "turnID": turnID.uuidString,
            "inputTokens": usage.inputTokens,
            "outputTokens": usage.outputTokens,
            "cacheReadTokens": usage.cacheReadTokens,
            "cacheCreationTokens": usage.cacheCreationTokens,
            "latencyMs": latencyMs,
            "toolCallCount": toolCallCount,
            "stopReason": stopReason,
        ])
    }

    private static func write(_ fields: [String: Any]) {
        var line = fields
        line["timestamp"] = timestamps.string(from: .now)
        line["model"] = model
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else {
            logger.error("ai-usage line could not be encoded")
            return
        }
        data.append(0x0A)
        queue.async { append(data) }
    }

    private static func append(_ data: Data) {
        let dir = NSHomeDirectory() + "/Library/Application Support/Besties"
        let path = dir + "/ai-usage.jsonl"
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            logger.error("ai-usage write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension AIUsage {
    /// Opus 5 list price: $5 / Mtok input, $25 / Mtok output, $0.50 / Mtok on
    /// cache reads and $6.25 / Mtok (1.25× input) on cache writes. The API
    /// reports cache reads and writes separately from `input_tokens`, so the
    /// four counters add up rather than overlap.
    var costUSD: Double {
        (Double(inputTokens) * 5 + Double(outputTokens) * 25
            + Double(cacheReadTokens) * 0.5 + Double(cacheCreationTokens) * 6.25) / 1_000_000
    }
}
