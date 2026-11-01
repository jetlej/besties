import AppKit
import SwiftUI

// MARK: - Chooser

/// How Besties AI runs — one pick out of four. Shown on the AI tab until one
/// is set up, and in Settings to see or switch it. Three are free (the user
/// brings the AI); only "Besties AI" — our key — costs money.
struct AIChooserView: View {
    enum Way: CaseIterable {
        case localApp, chatGPT, ownKey, besties
    }

    @Bindable var mcp: MCPController
    /// Settings: no big header, tighter rows.
    var compact = false

    private let subscription = SubscriptionManager.shared
    private let chatGPT = ChatGPTAuth.shared
    @State private var selected: Way?
    @State private var keyDraft = ""
    @State private var notice: String?
    @State private var showSignIn = false
    @State private var checking = false

    private static let title: AttributedString = {
        var title = AttributedString("How do you want to use AI?")
        if let range = title.range(of: "AI") {
            title[range].backgroundColor = .sun
        }
        return title
    }()

    /// The way currently in use. The dev key overrides everything and isn't
    /// one of the four, so it's shown separately.
    private var inUse: Way? {
        if subscription.isDevKey { return nil }
        if subscription.usesOwnKey { return .ownKey }
        if subscription.usesChatGPTPlan { return .chatGPT }
        if subscription.isActive { return .besties }
        if mcp.enabled { return .localApp }
        return nil
    }

    var body: some View {
        VStack(spacing: compact ? 10 : 14) {
            if !compact {
                VStack(spacing: 6) {
                    Text(Self.title)
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                    Text("Pick one. You can switch anytime in Settings.")
                        .font(.callout)
                        .foregroundStyle(Color.ink.opacity(0.55))
                }
                .padding(.bottom, 6)
            }
            if subscription.isDevKey {
                // DEV CARVE-OUT — REMOVE AT SHIP (SubscriptionManager.devKey).
                Text("The dev key (anthropicKey default) is on and overrides these.")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Way.allCases, id: \.self) { way in
                row(way)
            }
            if let notice {
                Text(notice)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { if selected == nil { selected = inUse } }
        .animation(.easeInOut(duration: 0.25), value: selected)
        .animation(.easeInOut(duration: 0.25), value: inUse)
        .sheet(isPresented: $showSignIn) {
            AISignInSheet { error in
                notice = error?.message
                if subscription.isSignedIn { clearOthers(keeping: .besties) }
            }
        }
    }

    // MARK: Rows

    private func row(_ way: Way) -> some View {
        let active = inUse == way
        let open = selected == way && hasDetail(way)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(emoji(way))
                    .font(.system(size: compact ? 18 : 22))
                    .frame(width: compact ? 34 : 42, height: compact ? 34 : 42)
                    .background(tint(way).opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(way))
                        .font(.system(size: compact ? 14 : 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.ink)
                    Text(caption(way))
                        .font(compact ? .caption : .callout)
                        .foregroundStyle(Color.ink.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                trailing(way, active: active)
            }
            .padding(compact ? 10 : 14)
            .contentShape(Rectangle())
            // The header only opens details; the trailing button does the setup.
            .onTapGesture {
                notice = nil
                selected = selected == way ? nil : way
            }

            if open {
                detail(way)
                    .padding(.horizontal, compact ? 10 : 14)
                    .padding(.bottom, compact ? 12 : 16)
                    .padding(.leading, compact ? 46 : 54)
                    // Content fades in once the card has grown, so the card
                    // reads as unfolding downward rather than sliding.
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.12)),
                        removal: .opacity.animation(.easeIn(duration: 0.1))))
            }
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(active ? Color.sun : Color.ink.opacity(0.08), lineWidth: active ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// The set-up button, or — for the way in use — an "In use" badge (its
    /// details below hold the way to turn it off).
    @ViewBuilder
    private func trailing(_ way: Way, active: Bool) -> some View {
        if active {
            Label("In use", systemImage: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.brandBlue, in: Capsule())
        } else if way == .chatGPT, chatGPT.state == .signingIn {
            ProgressView().controlSize(.small)
        } else {
            Button {
                notice = nil
                setUp(way)
            } label: {
                Text(cta(way))
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(way == .besties ? Color.sun : Color.ink.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func cta(_ way: Way) -> String {
        switch way {
        case .localApp: return "Turn on"
        case .chatGPT: return "Sign in"
        case .ownKey: return "Add key"
        case .besties: return "Subscribe"
        }
    }

    private func setUp(_ way: Way) {
        switch way {
        case .localApp:
            clearOthers(keeping: .localApp)
            mcp.enabled = true
            selected = .localApp
        case .chatGPT:
            selected = .chatGPT
            Task {
                do {
                    try await chatGPT.signIn()
                    clearOthers(keeping: .chatGPT)
                } catch let error as ChatGPTAuth.AuthError {
                    notice = error.message
                } catch {
                    notice = error.localizedDescription
                }
            }
        case .ownKey:
            selected = .ownKey
        case .besties:
            NSWorkspace.shared.open(SubscriptionManager.subscribeURL)
            selected = .besties
        }
    }

    private func emoji(_ way: Way) -> String {
        switch way {
        case .localApp: return "🖥️"
        case .chatGPT: return "💬"
        case .ownKey: return "🔑"
        case .besties: return "✨"
        }
    }

    private func tint(_ way: Way) -> Color {
        switch way {
        case .localApp: return .green
        case .chatGPT: return .brandBlue
        case .ownKey: return .orange
        case .besties: return .sun
        }
    }

    private func title(_ way: Way) -> String {
        switch way {
        case .localApp: return "Use an AI app on your Mac"
        case .chatGPT: return "Sign in with ChatGPT"
        case .ownKey: return "Paste a Claude API key"
        case .besties: return "Besties AI"
        }
    }

    private func caption(_ way: Way) -> String {
        switch way {
        case .localApp: return "LM Studio, Claude Desktop, Cursor… With a local model, nothing leaves your Mac."
        case .chatGPT: return "Free with your ChatGPT Plus or Pro plan."
        case .ownKey: return "Anthropic bills you directly for what you use."
        case .besties: return "$7/mo. Nothing to set up — Claude, GPT and more, with 3,000 AI credits every month."
        }
    }

    // MARK: Details

    /// Whether a way has anything to show below its header right now.
    private func hasDetail(_ way: Way) -> Bool {
        switch way {
        case .localApp: return mcp.enabled
        case .chatGPT: return chatGPT.isSignedIn || chatGPT.state == .signingIn
        case .ownKey, .besties: return true
        }
    }

    @ViewBuilder
    private func detail(_ way: Way) -> some View {
        switch way {
        case .localApp: MCPConnectPanel(mcp: mcp)
        case .chatGPT: chatGPTDetail
        case .ownKey: ownKeyDetail
        case .besties: bestiesDetail
        }
    }

    @ViewBuilder
    private var chatGPTDetail: some View {
        if chatGPT.isSignedIn {
            HStack {
                Text("Signed in as \(chatGPT.email ?? "you")")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                linkButton("Sign out", color: .orange) { chatGPT.signOut() }
            }
        } else {
            Text("Finish signing in in your browser…")
                .font(.callout)
                .foregroundStyle(Color.ink.opacity(0.6))
        }
    }

    @ViewBuilder
    private var ownKeyDetail: some View {
        if subscription.usesOwnKey {
            HStack {
                Text("Your key is saved in the Keychain.")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.ink)
                Spacer()
                linkButton("Remove", color: .orange) { subscription.removeOwnKey() }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SecureField("sk-ant-…", text: $keyDraft)
                        .textFieldStyle(.plain)
                        .onSubmit(saveKey)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.paper, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.ink.opacity(0.15)))
                    primaryButton("Use key", action: saveKey)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack(spacing: 4) {
                    Text("No key yet?")
                        .foregroundStyle(Color.ink.opacity(0.45))
                    linkButton("Get one from Anthropic →") {
                        NSWorkspace.shared.open(URL(string: "https://console.anthropic.com/settings/keys")!)
                    }
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var bestiesDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if inUse == .besties {
                HStack {
                    Text("Signed in as \(subscription.email ?? "you")")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    linkButton("Sign out", color: .orange) { subscription.signOut() }
                }
                AICreditMeter()
            } else {
                Text("Or $69/year. Cancel anytime.")
                    .font(.caption)
                    .foregroundStyle(Color.ink.opacity(0.45))
                if case .needsSignIn = subscription.state {
                    linkButton("Enter your sign-in code") { notice = nil; showSignIn = true }
                        .font(.callout)
                } else if subscription.isSignedIn {
                    HStack(spacing: 10) {
                        Text("Signed in as \(subscription.email ?? "you"), no active plan.")
                            .foregroundStyle(Color.ink.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        linkButton(checking ? "Checking…" : "Check again") {
                            Task {
                                checking = true
                                notice = nil
                                do { try await subscription.checkAgain() } catch let error as SubscriptionManager.SignInError {
                                    notice = error.message
                                } catch {}
                                checking = false
                            }
                        }
                        .disabled(checking)
                    }
                    .font(.callout)
                } else {
                    linkButton("Already subscribed? Sign in") { notice = nil; showSignIn = true }
                        .font(.callout)
                }
            }
        }
    }

    // MARK: Actions

    private func saveKey() {
        do {
            try subscription.setOwnKey(keyDraft)
            keyDraft = ""
            notice = nil
            clearOthers(keeping: .ownKey)
        } catch let error as SubscriptionManager.SignInError {
            notice = error.message
        } catch {}
    }

    /// One way at a time: setting one up turns the free ones off. A paid
    /// subscription is never signed out from here — it only ever loses on
    /// precedence, so removing the other way brings it straight back.
    private func clearOthers(keeping way: Way) {
        if way != .ownKey, subscription.usesOwnKey { subscription.removeOwnKey() }
        if way != .chatGPT, chatGPT.isSignedIn { chatGPT.signOut() }
        if way != .localApp, mcp.enabled { mcp.enabled = false }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.sun, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func linkButton(_ title: String, color: Color = .brandBlue, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
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
    let mcpController: MCPController
    private let subscription = SubscriptionManager.shared
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Label(label, systemImage: "person.crop.circle")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Color.ink.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { showing && subscription.isActive }, set: { showing = $0 }),
                 arrowEdge: .trailing) {
            AIAccountPopover()
        }
        .sheet(isPresented: Binding(get: { showing && !subscription.isActive }, set: { showing = $0 })) {
            AISetupSheet(mcp: mcpController)
        }
    }

    private var label: String {
        if subscription.isDevKey { return "Dev key" }
        if subscription.usesChatGPTPlan { return ChatGPTAuth.shared.email ?? "ChatGPT plan" }
        if subscription.usesOwnKey { return "Your API key" }
        if !subscription.isActive { return "Set up AI" }
        return subscription.email ?? "Account"
    }
}

private struct AIAccountPopover: View {
    private let subscription = SubscriptionManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Besties AI")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.ink)
            if subscription.isDevKey {
                // DEV CARVE-OUT — REMOVE AT SHIP (SubscriptionManager.devKey).
                line("Using the dev key from the anthropicKey default.")
            } else if subscription.usesChatGPTPlan {
                line("Using your ChatGPT plan — \(ChatGPTAuth.shared.email ?? "signed in")")
                note("GPT models only. Uses your plan's limits, not ours.")
            } else if subscription.usesOwnKey {
                line("Using your own API key")
                note("Billed by your provider, straight to your account.")
            } else {
                line("Signed in as \(subscription.email ?? "you")")
                AICreditMeter()
            }
            if !subscription.isDevKey {
                Divider()
                Button("Use a different way") {
                    subscription.resetAccess()
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.orange)
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .background(Color.paper)
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Color.ink.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.ink.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Meter

/// "X of 3,000 credits left this month" — the minted key's credit, straight
/// from OpenRouter (1 credit = $0.001 of usage). Absent for the dev key and
/// for BYOK.
struct AICreditMeter: View {
    private let subscription = SubscriptionManager.shared

    var body: some View {
        if subscription.showsMeter, let remaining = subscription.creditRemaining {
            let credits = Int((remaining / SubscriptionManager.creditUSD).rounded(.down))
            Text("\(credits.formatted()) of \(SubscriptionManager.monthlyCredits.formatted()) credits left this month")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.ink.opacity(0.45))
        }
    }
}

// MARK: - Setup sheet

/// The chooser as a modal: what the AI tab opens when someone acts on it
/// before picking a way. Fixed size — expanding an option scrolls.
struct AISetupSheet: View {
    @Bindable var mcp: MCPController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                AIChooserView(mcp: mcp)
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                    .padding(.bottom, 12)
            }
            Button("Not now") { dismiss() }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.ink.opacity(0.5))
                .keyboardShortcut(.cancelAction)
                .padding(.vertical, 14)
        }
        .frame(width: 580, height: 600)
        .background(Color.paper)
    }
}
