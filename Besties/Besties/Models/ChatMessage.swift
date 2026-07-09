import Foundation

struct ChatMessage: Identifiable {
    let id: Int64          // message.rowid
    let dateNano: Int64    // raw message_date, for exact keyset cursors
    let date: Date
    let isFromMe: Bool
    let text: String       // decoded body, or "[attachment]" / "[unsupported]"
}

/// What the person sheet opens: a person, their relationship totals, and where
/// to land in time. Totals come straight from the already-loaded conversation
/// aggregates so the headline KPIs match the numbers shown elsewhere in the app.
struct ReaderTarget: Identifiable {
    var id: String { name }
    let name: String
    let handle: String          // busiest handle, for the avatar
    let handleIDs: [Int64]      // every handle rowid for this person (SMS + iMessage + email)
    let anchorDate: Date        // where the scrubber lands on open
    let firstDate: Date         // scrubber min / conversation start
    let lastDate: Date          // scrubber max / most recent message
    let totalMessages: Int
    let sentMessages: Int
    let receivedMessages: Int
}

/// Peak-activity stats for a relationship, computed from per-day message counts.
struct RelationshipPeaks {
    var busiestDay: (date: Date, count: Int)?
    var busiestMonth: (date: Date, count: Int)?   // date = first of that month
    var busiestYear: (year: Int, count: Int)?
}
