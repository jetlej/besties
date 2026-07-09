import Foundation

struct ScoreBreakdown {
    let totalMessages: Double
    let dormancy: Double
    let frequency: Double
    let reciprocity: Double
    let direction: Double

    var description: String {
        let lines = [
            "Messages:  \(fmt(totalMessages))",
            "Dormancy:  \(fmt(dormancy))",
            "Frequency: \(fmt(frequency))",
            "Reciprocity: \(fmt(reciprocity))",
            "Direction: \(fmt(direction))",
        ]
        return lines.joined(separator: "\n")
    }

    private func fmt(_ v: Double) -> String {
        String(format: "%.1f", v)
    }
}

struct Conversation: Identifiable {
    let id: Int64
    let handle: String
    var displayName: String?
    /// Apple's `handle.person_centric_id` — links handles (phone/email, across
    /// services) that Messages considers the same person. nil when unset.
    var personID: String?

    let totalMessages: Int
    let sentMessages: Int
    let receivedMessages: Int
    let firstMessageDate: Date
    let lastMessageDate: Date
    let lastMessageIsFromMe: Bool

    var score: Double = 0
    var scoreBreakdown: ScoreBreakdown?

    var daysSinceLastMessage: Int {
        Calendar.current.dateComponents([.day], from: lastMessageDate, to: .now).day ?? 0
    }

    var resolvedName: String {
        displayName ?? handle
    }
}
