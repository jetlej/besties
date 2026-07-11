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

enum MessageSource: String {
    case iMessage = "i"
    case whatsApp = "w"
}

struct Conversation: Identifiable {
    /// handle rowid (iMessage) or ZWACHATSESSION Z_PK (WhatsApp).
    let rowID: Int64
    let source: MessageSource
    let handle: String
    var displayName: String?
    /// Apple's `handle.person_centric_id` — links handles (phone/email, across
    /// services) that Messages considers the same person. nil when unset.
    var personID: String?

    var id: String { "\(source.rawValue)-\(rowID)" }

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

    /// Groups conversations that belong to the same person across sources:
    /// by contact name when resolved, otherwise by the phone number itself
    /// (last 10 digits, so "+1 (323) 745-9802" and "13237459802@s.whatsapp.net"
    /// normalized to "+13237459802" all land in the same bucket), otherwise
    /// by the raw handle (emails).
    var mergeKey: String {
        if let displayName { return "n:" + displayName }
        let digits = handle.filter(\.isNumber)
        if digits.count >= 7 { return "p:" + String(digits.suffix(10)) }
        return "h:" + handle.lowercased()
    }
}
