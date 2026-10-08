import AppKit
import SwiftUI

// MARK: - Paywall

/// The AI tab without an active subscription: what it does, shown as a real
/// chat (fictional people and numbers), then the one thing to do about it.
struct AIPaywallView: View {
    private let subscription = SubscriptionManager.shared
    @State private var showSignIn = false
    @State private var notice: SubscriptionManager.SignInError?
    @State private var checking = false

    /// "anything" gets the site's sun-highlight treatment, as in the chat.
    private static let title: AttributedString = {
        var title = AttributedString("Ask anything about your messages.")
        if let range = title.range(of: "anything") {
            title[range].backgroundColor = .sun
        }
        return title
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Text(Self.title)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                examples

                VStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.open(SubscriptionManager.subscribeURL)
                    } label: {
                        Text("Subscribe — $10/mo")
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.ink)
                            .frame(maxWidth: 320)
                            .padding(.vertical, 12)
                            .background(Color.sun, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    Text("Includes $9 of AI credit every month. Cancel anytime.")
                        .font(.caption)
                        .foregroundStyle(Color.ink.opacity(0.5))
                }

                secondaryAction

                // Reserved so a message appearing never moves the layout.
                Text(notice?.message ?? " ")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.orange)
                    .multilineTextAlignment(.center)
                    .frame(height: 36, alignment: .top)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showSignIn) {
            AISignInSheet { error in notice = error }
        }
    }

    @ViewBuilder
    private var secondaryAction: some View {
        if case .needsSignIn = subscription.state {
            linkButton("Enter your sign-in code") { notice = nil; showSignIn = true }
        } else if subscription.isSignedIn {
            // Signed in but not active: lapsed, the key didn't load yet, or the
            // subscription lives under another email / a new Stripe customer.
            HStack(spacing: 6) {
                Text("Signed in as \(subscription.email ?? "you").")
                    .foregroundStyle(Color.ink.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
                linkButton(checking ? "Checking…" : "Check again") {
                    Task {
                        checking = true
                        notice = nil
                        do { try await subscription.checkAgain() } catch let error as SubscriptionManager.SignInError {
                            notice = error
                        } catch {}
                        checking = false
                    }
                }
                .disabled(checking)
                linkButton("Use a different email") {
                    notice = nil
                    subscription.signOut()
                    showSignIn = true
                }
                .disabled(checking)
            }
            .font(.callout)
        } else {
            linkButton("Already subscribed? Sign in") { notice = nil; showSignIn = true }
        }
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.brandBlue)
        }
        .buttonStyle(.plain)
    }

    // MARK: Examples

    private var examples: some View {
        VStack(spacing: 10) {
            question("Who have I said I love you to the most?")
            answer { loveLeaderboard }
            question("When did Sam and I start talking every day?")
            answer {
                Text("**March 2019.** You went from a few texts a month to 40+ a day right after the Lisbon trip — and never really stopped. ✈️")
            }
            question("What was my first ever message?")
            answer {
                Text("**“are we still on for tacos??”** — to Jamie, September 14, 2011. You were.")
            }
        }
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.ink.opacity(0.08)))
        .shadow(color: Color.ink.opacity(0.06), radius: 8, y: 3)
        // Examples, not controls.
        .allowsHitTesting(false)
    }

    private static let loveRows: [(medal: String, name: String, count: Int)] = [
        ("🥇", "Mom", 412),
        ("🥈", "Sam", 287),
        ("🥉", "Priya", 154),
        ("4", "Jake", 61),
    ]

    private var loveLeaderboard: some View {
        let top = Double(Self.loveRows.first?.count ?? 1)
        return VStack(alignment: .leading, spacing: 7) {
            Text("❤️ Your “I love you” leaderboard")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
            ForEach(Self.loveRows, id: \.name) { row in
                HStack(spacing: 8) {
                    Text(row.medal)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .frame(width: 20)
                    Text(row.name)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 44, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.brandBlue)
                            .frame(width: max(geo.size.width * Double(row.count) / top, 4))
                    }
                    .frame(height: 12)
                    Text("\(row.count)")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink.opacity(0.6))
                        .frame(width: 30, alignment: .trailing)
                }
            }
            Text("Mom wins by a mile. Sam's climbing fast. 📈")
                .font(.system(size: 13))
        }
        .frame(width: 280)
    }

    /// Same shapes and colors as the real chat's bubbles.
    private func question(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 60)
            Text(text)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.brandBlue)
                .foregroundStyle(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func answer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            content()
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.bubbleTan)
                .foregroundStyle(Color.ink)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            Spacer(minLength: 60)
        }
    }
}

// MARK: - Sign-in

/// Email → 6-digit code. The step follows the manager's state, so closing
/// the sheet mid-way and reopening lands back on the code field.
struct AISignInSheet: View {
    /// Called on dismissal with anything the paywall should keep showing —
    /// "no active subscription" after a valid code, or a key that didn't load.
    let onFinish: (SubscriptionManager.SignInError?) -> Void

    @Environment(\.dismiss) private var dismiss
    private let subscription = SubscriptionManager.shared
    @State private var email = ""
    @State private var code = ""
    @State private var error: SubscriptionManager.SignInError?
    @State private var working = false
    @FocusState private var focused: Bool

    private var pendingEmail: String? {
        if case .needsSignIn(let email) = subscription.state { return email }
        return nil
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("✨")
                .font(.system(size: 34))
            if let pendingEmail {
                codeStep(pendingEmail)
            } else {
                emailStep
            }
            // Reserved so an error never shifts the buttons.
            Text(error?.message ?? " ")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.orange)
                .multilineTextAlignment(.center)
                .frame(height: 36, alignment: .top)
            Button("Cancel") { close(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.ink.opacity(0.5))
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 360)
        .background(Color.paper)
        .onAppear { focused = true }
    }

    private var emailStep: some View {
        VStack(spacing: 14) {
            Text("Sign in to Besties AI")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.ink)
            Text("Use the email you subscribed with.")
                .font(.callout)
                .foregroundStyle(Color.ink.opacity(0.6))
            field {
                TextField("you@example.com", text: $email)
                    .textContentType(.emailAddress)
                    .onSubmit(sendCode)
            }
            primaryButton(working ? "Sending…" : "Email me a code", action: sendCode)
                .disabled(working || email.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func codeStep(_ address: String) -> some View {
        VStack(spacing: 14) {
            Text("Enter your 6-digit code")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.ink)
            // auth-request never says whether an address subscribes, so the
            // "no subscription" case can only be hinted at here.
            Text("We sent it to \(address) — if that email has a subscription.")
                .font(.callout)
                .foregroundStyle(Color.ink.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            field {
                TextField("123456", text: $code)
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .textContentType(.oneTimeCode)
                    .onSubmit(verify)
                    .onChange(of: code) {
                        let digits = String(code.filter(\.isNumber).prefix(6))
                        if digits != code { code = digits }
                        if digits.count == 6 { verify() }
                    }
            }
            primaryButton(working ? "Checking…" : "Sign in", action: verify)
                .disabled(working || code.count != 6)
            HStack(spacing: 14) {
                Button("Send a new code") {
                    email = address
                    code = ""
                    sendCode()
                }
                Button("Use a different email") {
                    email = address
                    code = ""
                    error = nil
                    subscription.cancelSignIn()
                }
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.brandBlue)
            .disabled(working)
        }
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(focused ? Color.sun : Color.ink.opacity(0.12), lineWidth: 1.5))
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.sun, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func sendCode() {
        guard !working else { return }
        run { try await subscription.requestCode(email: email) }
    }

    private func verify() {
        guard !working, code.count == 6 else { return }
        run {
            do {
                try await subscription.verify(code: code)
                close(nil)
            } catch let failure as SubscriptionManager.SignInError
                        where failure == .noSubscription || failure == .keyUnavailable {
                // Signed in, but nothing to unlock: the paywall carries the news.
                close(failure)
            }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            do {
                try await work()
            } catch let failure as SubscriptionManager.SignInError {
                error = failure
                if failure == .wrongCode || failure == .tooManyTries { code = "" }
            } catch {
                self.error = .server
            }
            working = false
            focused = true
        }
    }

    private func close(_ notice: SubscriptionManager.SignInError?) {
        onFinish(notice)
        dismiss()
    }
}

// MARK: - Account

/// Sidebar footer of the chat: who's signed in, BYOK, sign out.
struct AIAccountButton: View {
    private let subscription = SubscriptionManager.shared
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Label(subscription.isDevKey ? "Dev key" : (subscription.email ?? "Account"),
                  systemImage: "person.crop.circle")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Color.ink.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            AIAccountPopover()
        }
    }
}

private struct AIAccountPopover: View {
    private let subscription = SubscriptionManager.shared
    @State private var keyDraft = ""
    @State private var keyError: SubscriptionManager.SignInError?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Besties AI")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.ink)
            if subscription.isDevKey {
                // DEV CARVE-OUT — REMOVE AT SHIP (SubscriptionManager.devKey).
                Text("Using the dev key from the anthropicKey default. No subscription, no meter.")
                    .font(.callout)
                    .foregroundStyle(Color.ink.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Signed in as \(subscription.email ?? "you")")
                    .font(.callout)
                    .foregroundStyle(Color.ink.opacity(0.7))
                AICreditMeter()
                if subscription.canUseOwnKey {
                    Divider()
                    ownKeySection
                }
                Divider()
                Button("Sign out") { subscription.signOut() }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.orange)
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .background(Color.paper)
    }

    @ViewBuilder
    private var ownKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your own OpenRouter key")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.ink)
            if subscription.usesOwnKey {
                Text("In use — AI bills your OpenRouter account instead of your monthly credit.")
                    .font(.caption)
                    .foregroundStyle(Color.ink.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Remove my key") { subscription.removeOwnKey() }
                    .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    SecureField("sk-or-…", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("Use", action: save)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
                Text(keyError?.message ?? "Optional. Stored in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(keyError == nil ? Color.ink.opacity(0.45) : Color.orange)
            }
        }
    }

    private func save() {
        do {
            try subscription.setOwnKey(keyDraft)
            keyDraft = ""
            keyError = nil
        } catch let error as SubscriptionManager.SignInError {
            keyError = error
        } catch {}
    }
}

// MARK: - Meter

/// "$X.XX of $9.00 left this month" — the minted key's credit, straight from
/// OpenRouter. Absent for the dev key and for BYOK.
struct AICreditMeter: View {
    private let subscription = SubscriptionManager.shared

    var body: some View {
        if subscription.showsMeter, let remaining = subscription.creditRemaining {
            Text(String(format: "$%.2f of $%.2f left this month", remaining, SubscriptionManager.monthlyCredit))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.ink.opacity(0.45))
        }
    }
}
