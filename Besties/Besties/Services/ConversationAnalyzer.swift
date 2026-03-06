import Foundation

struct ConversationAnalyzer {
    struct Weights {
        var totalMessages: Double = 0.20
        var daysSinceLastMessage: Double = 0.30
        var historicalFrequency: Double = 0.20
        var reciprocity: Double = 0.15
        var lastMessageDirection: Double = 0.15
    }

    var weights = Weights()
    var minimumMessages = 10
    var minimumDormantDays = 7
    var maximumDormantDays = 274

    func score(_ conversations: [Conversation]) -> [Conversation] {
        let filtered = conversations.filter {
            $0.totalMessages >= minimumMessages
            && $0.daysSinceLastMessage >= minimumDormantDays
            && $0.daysSinceLastMessage <= maximumDormantDays
        }

        guard !filtered.isEmpty else { return [] }

        let maxDays = Double(filtered.map(\.daysSinceLastMessage).max() ?? 1)
        let maxLogMessages = log(Double(filtered.map(\.totalMessages).max() ?? 1) + 1)
        let maxFrequency = filtered.map { historicalFrequency(for: $0) }.max() ?? 1

        var scored = filtered.map { convo -> Conversation in
            var c = convo

            let normTotal = log(Double(c.totalMessages) + 1) / max(maxLogMessages, 1)
            let normDays = Double(c.daysSinceLastMessage) / max(maxDays, 1)
            let normFreq = historicalFrequency(for: c) / max(maxFrequency, 1)
            let normReciprocity = reciprocityScore(sent: c.sentMessages, received: c.receivedMessages)
            let directionBonus: Double = c.lastMessageIsFromMe ? 0.5 : 1.0

            let wTotal = normTotal * weights.totalMessages * 100
            let wDays = normDays * weights.daysSinceLastMessage * 100
            let wFreq = normFreq * weights.historicalFrequency * 100
            let wRecip = normReciprocity * weights.reciprocity * 100
            let wDir = directionBonus * weights.lastMessageDirection * 100

            c.score = wTotal + wDays + wFreq + wRecip + wDir
            c.scoreBreakdown = ScoreBreakdown(
                totalMessages: wTotal,
                dormancy: wDays,
                frequency: wFreq,
                reciprocity: wRecip,
                direction: wDir
            )

            return c
        }

        scored.sort { $0.score > $1.score }
        return scored
    }

    private func historicalFrequency(for c: Conversation) -> Double {
        let weeks = max(c.lastMessageDate.timeIntervalSince(c.firstMessageDate) / 604_800, 1)
        return Double(c.totalMessages) / weeks
    }

    private func reciprocityScore(sent: Int, received: Int) -> Double {
        let total = Double(sent + received)
        guard total > 0 else { return 0 }
        let ratio = Double(min(sent, received)) / Double(max(sent, received))
        return ratio
    }
}
