import Foundation

struct ChatMessage: Identifiable {
    let rowID: Int64       // message.rowid (iMessage) or ZWAMESSAGE Z_PK (WhatsApp)
    let source: MessageSource
    let dateNano: Int64    // nanoseconds since 2001, for exact keyset cursors
    let date: Date
    let isFromMe: Bool
    let text: String       // decoded body, or "[attachment]" / "[unsupported]"

    var id: String { "\(source.rawValue)-\(rowID)" }
}

/// What the person sheet opens: a person, their relationship totals, and where
/// to land in time. Totals come straight from the already-loaded conversation
/// aggregates so the headline KPIs match the numbers shown elsewhere in the app.
struct ReaderTarget: Identifiable {
    var id: String { key }
    let key: String                   // the person's mergeKey
    let name: String
    let handle: String                // busiest handle, for the avatar
    let imessageHandleIDs: [Int64]    // handle rowids (SMS + iMessage + email)
    let whatsAppChatIDs: [Int64]      // ZWACHATSESSION Z_PKs
    let anchorDate: Date              // where the scrubber lands on open
    let firstDate: Date               // scrubber min / conversation start
    let lastDate: Date                // scrubber max / most recent message
    let totalMessages: Int
    let sentMessages: Int
    let receivedMessages: Int
}

/// Peak-activity stats for a relationship, computed from per-day message counts.
struct RelationshipPeaks {
    var busiestDay: (date: Date, count: Int)?
    var busiestMonth: (date: Date, count: Int)?   // date = first of that month
    var busiestYear: (year: Int, count: Int)?

    init() {}

    /// Rolls "yyyy-MM-dd" day counts (already merged across sources) up into
    /// the busiest day / month / year.
    init(dayCounts: [String: Int]) {
        var byMonth: [String: Int] = [:]
        var byYear: [Int: Int] = [:]
        for (day, count) in dayCounts {
            byMonth[String(day.prefix(7)), default: 0] += count
            if let year = Int(day.prefix(4)) { byYear[year, default: 0] += count }
        }
        if let top = dayCounts.max(by: { $0.value < $1.value }),
           let date = Self.dayFormatter.date(from: top.key) {
            busiestDay = (date, top.value)
        }
        if let top = byMonth.max(by: { $0.value < $1.value }),
           let date = Self.monthFormatter.date(from: top.key) {
            busiestMonth = (date, top.value)
        }
        if let top = byYear.max(by: { $0.value < $1.value }) {
            busiestYear = (top.key, top.value)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f
    }()
}
