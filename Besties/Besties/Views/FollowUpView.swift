import SwiftUI

/// Someone you added to Contacts and then (nearly) never texted — Krish's
/// "you met, swapped numbers, nobody followed up".
struct FollowUp: Identifiable {
    /// "n:<name>", the same shape as a named conversation's mergeKey.
    let id: String
    let name: String
    /// What the Message button opens: their busiest conversation's handle,
    /// or the card's first number if you've never texted.
    let handle: String
    let source: MessageSource
    let added: Date
    let sent: Int
    let received: Int
    /// The first message between you, as a reminder of where you met.
    let firstMessage: String?
    let firstMessageIsFromMe: Bool
    let detail: String?
    /// Their conversation's mergeKey, when there is one — for the reader and
    /// the ✨ draft (which needs history to read).
    let conversationKey: String?

    var total: Int { sent + received }

    /// At most this many messages across every app still counts as "never
    /// followed up" — the "here's my number" text and a reply.
    static let maxMessages = 3
    /// Give a new contact two weeks before nagging about them.
    static let gracePeriod: TimeInterval = 14 * 86_400

    /// Matches cards to conversations by phone number (last 10 digits, so
    /// iMessage, SMS and WhatsApp all count).
    static func find(contacts: [AddedContact], conversations: [Conversation], store: MessageStore) -> [FollowUp] {
        var byDigits: [String: [Conversation]] = [:]
        for convo in conversations {
            let digits = convo.handle.filter(\.isNumber)
            guard digits.count >= 7 else { continue }
            byDigits[String(digits.suffix(10)), default: []].append(convo)
        }
        let cutoff = Date.now.addingTimeInterval(-gracePeriod)

        return contacts.compactMap { contact -> FollowUp? in
            guard contact.added < cutoff else { return nil }
            let digits = Set(contact.phones.map { String($0.filter(\.isNumber).suffix(10)) }.filter { $0.count >= 7 })
            guard let anyNumber = contact.phones.first, !digits.isEmpty else { return nil }
            var seen = Set<String>()
            let convos = digits.flatMap { byDigits[$0] ?? [] }.filter { seen.insert($0.id).inserted }
            let sent = convos.reduce(0) { $0 + $1.sentMessages }
            let received = convos.reduce(0) { $0 + $1.receivedMessages }
            guard sent + received <= maxMessages else { return nil }

            let busiest = convos.max { $0.totalMessages < $1.totalMessages }
            let iMessageHandles = convos.filter { $0.source == .iMessage }.map(\.rowID)
            let first = (try? store.fetchChatIDs(handleIDs: iMessageHandles))
                .flatMap { try? store.fetchMessages(chatIDs: $0, limit: 1).first }

            return FollowUp(
                id: "n:" + contact.name,
                name: contact.name,
                handle: busiest?.handle ?? anyNumber,
                source: busiest?.source ?? .iMessage,
                added: contact.added,
                sent: sent,
                received: received,
                firstMessage: first?.text,
                firstMessageIsFromMe: first?.isFromMe ?? false,
                detail: contact.detail,
                conversationKey: busiest?.mergeKey
            )
        }
        .sorted { $0.added > $1.added }
    }
}

/// Reconnect → "Never followed up": newest contacts first, each with the one
/// thing that might jog your memory.
struct FollowUpListView: View {
    let appState: AppState
    let query: String
    let onOpen: (String) -> Void

    private var rows: [FollowUp] {
        appState.followUps.filter {
            !appState.hiddenFollowUps.contains($0.id)
                && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        Group {
            if !appState.followUpsLoaded {
                ProgressView("Reading your contacts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                Text(query.isEmpty ? "You've followed up with everyone you added. 🎉" : "No matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        Text("People you added to Contacts but never really texted — newest first.")
                            .font(.callout)
                            .foregroundStyle(Color.ink.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 2)
                        ForEach(rows) { person in
                            FollowUpRow(person: person, appState: appState, onOpen: onOpen)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .task { appState.loadFollowUps() }
    }
}

private struct FollowUpRow: View {
    let person: FollowUp
    let appState: AppState
    let onOpen: (String) -> Void

    private var status: String {
        switch (person.sent, person.received) {
        case (0, 0): return "Never texted"
        case (let sent, 0): return sent == 1 ? "You sent 1 text, no reply" : "You sent \(sent) texts, no reply"
        case (0, let received): return received == 1 ? "They texted once, you never replied" : "They texted \(received) times, you never replied"
        default: return "\(person.total) texts total"
        }
    }

    /// The first message beats the card's note: it's usually "hey it's X
    /// from Y", which is exactly the reminder.
    private var reminder: String? {
        if let text = person.firstMessage, text != "[unsupported]" {
            return (person.firstMessageIsFromMe ? "You: " : "Them: ") + "“\(text)”"
        }
        return person.detail
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(
                name: person.name,
                imageData: appState.avatar(forHandle: person.handle),
                color: leaderboardColor,
                size: 40
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(person.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text("Added \(person.added.formatted(.dateTime.month(.abbreviated).year())) · \(status)")
                    .font(.caption)
                    .foregroundStyle(Color.ink.opacity(0.55))
                if let reminder {
                    Text(reminder)
                        .font(.caption.italic())
                        .foregroundStyle(Color.ink.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            Button {
                withAnimation { _ = appState.hiddenFollowUps.insert(person.id) }
            } label: {
                Image(systemName: "eye.slash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.ink.opacity(0.4))
            .help("Hide \(person.name) from this list")
            if let key = person.conversationKey {
                Button {
                    appState.aiReportRequest = .reconnectDraft(person: key)
                    appState.requestedTab = .ai
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Draft a text to \(person.name)")
            }
            Button {
                openInMessages(handle: person.handle, source: person.source)
            } label: {
                Image(systemName: "bubble.left.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Text \(person.name)")
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.ink.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture { if let key = person.conversationKey { onOpen(key) } }
    }
}
