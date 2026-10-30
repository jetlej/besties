import Foundation
import os

/// JSON lines appended to `~/Library/Application Support/Besties/ai-usage.jsonl`
/// — one `"kind": "request"` line per HTTP request and one `"kind": "turn"`
/// summary per question, tied together by `turnID`. This file is the
/// prototype's pricing evidence — cost and latency per question — so writing it
/// must never disturb a turn: every failure is swallowed into os_log.
enum AIUsageLog {
    private static let logger = Logger(subsystem: "com.besties.app", category: "AIUsageLog")
    private static let queue = DispatchQueue(label: "com.besties.app.ai-usage")

    private static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// One request inside a turn: `sequence` is 1-based within `turnID`, and
    /// `latencyMs` covers just this HTTP request's stream.
    static func recordRequest(turnID: UUID, sequence: Int, model: AIModel, usage: AIUsage, latencyMs: Int) {
        write([
            "model": model.label,
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
    /// `source` separates the two kinds of turn — a chat question ("chat") and a
    /// packaged report ("report", with `reportKind`) — because a 64k-token report
    /// would otherwise skew the per-question chat averages this file exists to
    /// measure.
    static func record(turnID: UUID, source: String, reportKind: String? = nil,
                       usage: AIUsage, stopReason: String, latencyMs: Int, toolCallCount: Int) {
        var fields: [String: Any] = [
            "kind": "turn",
            "model": usage.model.label,
            "turnID": turnID.uuidString,
            "source": source,
            "inputTokens": usage.inputTokens,
            "outputTokens": usage.outputTokens,
            "cacheReadTokens": usage.cacheReadTokens,
            "cacheCreationTokens": usage.cacheCreationTokens,
            "latencyMs": latencyMs,
            "toolCallCount": toolCallCount,
            "stopReason": stopReason,
        ]
        if let reportKind { fields["reportKind"] = reportKind }
        write(fields)
    }

    private static func write(_ fields: [String: Any]) {
        var line = fields
        line["timestamp"] = timestamps.string(from: .now)
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
    /// At the model's list prices. The API reports cache reads and writes
    /// separately from `input_tokens`, so the four counters add up rather
    /// than overlap.
    var costUSD: Double {
        let price = model.prices
        return (Double(inputTokens) * price.input + Double(outputTokens) * price.output
            + Double(cacheReadTokens) * price.cacheRead + Double(cacheCreationTokens) * price.cacheWrite) / 1_000_000
    }
}
