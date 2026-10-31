import Foundation
import Observation
import os
import Security

/// Who gets the AI tab, and with which OpenRouter key — Phase 3 of
/// docs/ai-subscription-plan.md. There is no free trial: without an active
/// key the AI tab is a paywall.
///
/// The billing API (site/api) only ever learns "this email has an active
/// subscription": sign-in is email → 6-digit code (`auth-request` /
/// `auth-verify`), which yields a long-lived session token; `ai-key` trades
/// that token for the subscriber's own OpenRouter runtime key, and the app
/// then talks to OpenRouter directly. Token and key live in the login
/// Keychain, never in defaults.
@MainActor
@Observable
final class SubscriptionManager {
    enum State: Equatable {
        case noSubscription
        /// A code was emailed to `email`; waiting for it to be entered.
        case needsSignIn(email: String)
        case active(key: String)
    }

    enum SignInError: Error, Equatable {
        case invalidEmail
        case wrongCode
        case tooManyTries
        case noSubscription
        case signedOut
        case keyUnavailable
        case invalidKey
        case offline
        case server

        var message: String {
            switch self {
            case .invalidEmail: "That doesn't look like an email address."
            case .wrongCode: "That code didn't work. Check the email and try again."
            case .tooManyTries: "Too many tries. Send yourself a new code."
            case .noSubscription: "No active subscription for that email."
            case .signedOut: "Your sign-in expired. Sign in again."
            case .keyUnavailable: "You're signed in, but Besties AI didn't load. Try again in a minute."
            case .invalidKey: "OpenRouter keys start with sk-or-."
            case .offline: "Couldn't reach Besties. Check your internet connection."
            case .server: "Something went wrong on our end. Try again in a minute."
            }
        }
    }

    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let shared = SubscriptionManager()

    /// The site's plan picker (monthly $7 / yearly $69); its buttons start
    /// Stripe Checkout through /api/subscribe.
    static let subscribeURL = URL(string: "https://besties.gg/#ai")!

    /// What the subscription buys each month, in USD of model usage. Must equal
    /// MONTHLY_CREDIT in site/api/_lib/plan.js ($2.20 keeps a $4 margin on the
    /// $7 plan at full use). The meter's denominator is this constant, not the
    /// key's OpenRouter `limit`: each month's top-up sets the limit to
    /// `usage + credit`, so `limit` grows forever while `limit_remaining` is
    /// the month's balance.
    static let monthlyCredit = 2.20

    static let recheckInterval: TimeInterval = 7 * 24 * 3600

    private static let apiBase = URL(string: "https://besties.gg/api")!
    /// https://openrouter.ai/docs/api/api-reference/api-keys/get-current-key
    private static let keyInfoURL = URL(string: "https://openrouter.ai/api/v1/key")!

    private enum Item {
        static let token = "aiSessionToken"
        static let mintedKey = "aiRuntimeKey"
        static let ownKey = "aiOwnKey"
    }

    private enum Default {
        static let email = "aiAccountEmail"
        static let checkedAt = "aiKeyCheckedAt"
        /// DEV CARVE-OUT — REMOVE AT SHIP (see `devKey`).
        static let devKey = "anthropicKey"
    }

    private(set) var state: State = .noSubscription
    /// USD left this month on the minted key; nil until read, and always nil
    /// for the dev key or a BYOK key (neither is the subscription's credit).
    private(set) var creditRemaining: Double?
    /// The address signed in with, for the account popover.
    private(set) var email: String?

    /// DEV CARVE-OUT — REMOVE AT SHIP. A non-empty `anthropicKey` default
    /// (`defaults write com.besties.app anthropicKey sk-ant-…` or `sk-or-…`,
    /// relaunch) makes the state `active(thatKey)` with no meter and no network,
    /// so the prototype workflow keeps working until the billing backend is
    /// deployed. Delete this, `Default.devKey` and every `isDevKey` branch
    /// before the subscription ships.
    let isDevKey: Bool
    private let devKey: String

    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private let transport: Transport
    private let now: () -> Date

    private var token: String?
    private var mintedKey: String?
    private var ownKey: String?
    private var pendingEmail: String?
    /// False after a failed Keychain write of `token`: it works this session
    /// and the write is retried on the next successful key refresh.
    private var tokenPersisted = true

    var activeKey: String? {
        if case .active(let key) = state { return key }
        return nil
    }

    var isActive: Bool { activeKey != nil }

    /// Signed in (a session token exists) — true even while the subscription
    /// has lapsed, so the paywall can offer a re-check instead of a sign-in.
    var isSignedIn: Bool { token != nil }

    /// BYOK is a subscriber perk: offered only on a real subscription.
    var canUseOwnKey: Bool { !isDevKey && mintedKey != nil }
    var usesOwnKey: Bool { canUseOwnKey && ownKey != nil }

    var showsMeter: Bool { !isDevKey && !usesOwnKey && isActive && creditRemaining != nil }

    init(keychain: KeychainStore = KeychainStore(service: "com.besties.app"),
         defaults: UserDefaults = .standard,
         transport: @escaping Transport = SubscriptionManager.liveTransport,
         now: @escaping () -> Date = Date.init) {
        self.keychain = keychain
        self.defaults = defaults
        self.transport = transport
        self.now = now
        devKey = defaults.string(forKey: Default.devKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        isDevKey = !devKey.isEmpty
        token = keychain.read(Item.token)
        mintedKey = keychain.read(Item.mintedKey)
        ownKey = keychain.read(Item.ownKey)
        email = defaults.string(forKey: Default.email)
        resolveState()
    }

    /// Whether the AI tab will open unlocked this launch, readable off the main
    /// actor — AppState uses it to decide whether the semantic index (an hour
    /// of background embedding) is worth building at all.
    nonisolated static var hasStoredAccess: Bool {
        let dev = UserDefaults.standard.string(forKey: Default.devKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let keychain = KeychainStore(service: "com.besties.app")
        return !dev.isEmpty || (keychain.read(Item.token) != nil && keychain.read(Item.mintedKey) != nil)
    }

    private func resolveState() {
        if isDevKey {
            state = .active(key: devKey)
        } else if token != nil, let mintedKey {
            state = .active(key: ownKey ?? mintedKey)
        } else if let pendingEmail {
            state = .needsSignIn(email: pendingEmail)
        } else {
            state = .noSubscription
        }
    }

    // MARK: - Launch

    /// Re-checks the subscription at most weekly. Between checks — and when
    /// offline or the API is down — the last known key keeps working; OpenRouter
    /// itself stops a lapsed key once the webhook zeroes its limit. Signed in
    /// without a key (lapsed, or a failed first fetch) always checks.
    func refreshIfDue() async {
        guard !isDevKey, token != nil else { return }
        if mintedKey != nil, let last = defaults.object(forKey: Default.checkedAt) as? Date {
            let age = now().timeIntervalSince(last)
            // A negative age means the clock moved backwards; check rather than trust it.
            if age >= 0, age < Self.recheckInterval { return }
        }
        _ = await refreshKey()
    }

    /// The paywall's "check again" for a signed-in, lapsed (or not yet
    /// loaded) subscriber.
    func checkAgain() async throws {
        switch await refreshKey() {
        case .ok: return
        case .noSubscription: throw SignInError.noSubscription
        case .signedOut: throw SignInError.signedOut
        case .unavailable: throw SignInError.keyUnavailable
        }
    }

    private enum KeyResult { case ok, noSubscription, signedOut, unavailable }

    private func refreshKey() async -> KeyResult {
        guard let token else { return .signedOut }
        var request = URLRequest(url: Self.apiBase.appending(path: "ai-key"), timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await transport(request) else { return .unavailable }
        // The token may have been dropped (signed out) while this was in flight.
        guard self.token == token else { return .signedOut }

        switch response.statusCode {
        case 200:
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard let key = json?["key"] as? String, key.hasPrefix("sk-or-") else { return .unavailable }
            if !tokenPersisted { tokenPersisted = keychain.write(token, for: Item.token) }
            var keyPersisted = true
            if key != mintedKey {
                keyPersisted = keychain.write(key, for: Item.mintedKey)
                mintedKey = key
            }
            // A key that didn't reach the Keychain is used from memory; leaving
            // the check date cleared makes the next launch fetch it again.
            if keyPersisted {
                defaults.set(now(), forKey: Default.checkedAt)
            } else {
                defaults.removeObject(forKey: Default.checkedAt)
            }
            // ai-key reports the key's running totals, which seeds the meter
            // without a second request.
            if let limit = json?["limit"] as? Double, let usage = json?["usage"] as? Double {
                creditRemaining = max(0, limit - usage)
            }
            resolveState()
            return .ok
        case 401:
            // The token is bad for good (AUTH_SECRET rotated, or tampered) —
            // the only way back is a fresh sign-in.
            signOut()
            return .signedOut
        case 402:
            // Lapsed: the key goes, the token stays, so renewing the same Stripe
            // subscription unlocks again with no sign-in. A resubscribe that made
            // a new Stripe customer needs a fresh sign-in (the token names the old
            // one) — the paywall offers "Use a different email" for that.
            keychain.delete(Item.mintedKey)
            mintedKey = nil
            creditRemaining = nil
            defaults.removeObject(forKey: Default.checkedAt)
            resolveState()
            return .noSubscription
        default:
            return .unavailable
        }
    }

    // MARK: - Sign-in

    /// Emails a 6-digit code. `auth-request` answers 200 whether or not the
    /// address subscribes (so it can't be probed for who does), so success here
    /// only means "a code is on its way *if* that email has a subscription".
    func requestCode(email raw: String) async throws {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.count <= 254,
              email.range(of: #"^[^\s@"'\\]+@[^\s@"'\\]+\.[^\s@"'\\]+$"#, options: .regularExpression) != nil
        else { throw SignInError.invalidEmail }

        let response = try await post("auth-request", ["email": email]).response
        guard response.statusCode == 200 else { throw SignInError.server }
        pendingEmail = email
        resolveState()
    }

    /// Verifies the code, stores the session token, then fetches the key.
    func verify(code raw: String) async throws {
        guard let email = pendingEmail else { throw SignInError.wrongCode }
        let code = raw.filter(\.isNumber)
        guard code.count == 6 else { throw SignInError.wrongCode }

        let (data, response) = try await post("auth-verify", ["email": email, "code": code])
        switch response.statusCode {
        case 200:
            break
        case 400:
            throw SignInError.wrongCode
        case 429:
            // auth-verify deletes the code after too many tries; a new one is needed.
            throw SignInError.tooManyTries
        default:
            throw SignInError.server
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let newToken = json?["token"] as? String, !newToken.isEmpty else { throw SignInError.server }

        tokenPersisted = keychain.write(newToken, for: Item.token)
        token = newToken
        self.email = email
        defaults.set(email, forKey: Default.email)
        pendingEmail = nil
        // Leave needsSignIn now, so a failed key fetch lands on the signed-in
        // paywall ("Check again") rather than the code prompt.
        resolveState()
        try await checkAgain()
    }

    /// "Use a different email": drop the pending code.
    func cancelSignIn() {
        pendingEmail = nil
        resolveState()
    }

    func signOut() {
        for item in [Item.token, Item.mintedKey, Item.ownKey] { keychain.delete(item) }
        token = nil
        tokenPersisted = true
        mintedKey = nil
        ownKey = nil
        pendingEmail = nil
        creditRemaining = nil
        email = nil
        defaults.removeObject(forKey: Default.email)
        defaults.removeObject(forKey: Default.checkedAt)
        resolveState()
    }

    private func post(_ path: String, _ body: [String: String]) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: Self.apiBase.appending(path: path), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            return try await transport(request)
        } catch {
            throw SignInError.offline
        }
    }

    // MARK: - BYOK

    /// Swaps the subscriber's own OpenRouter key in for the minted one; every
    /// AI request then bills their account instead of the monthly credit.
    func setOwnKey(_ raw: String) throws {
        guard canUseOwnKey else { throw SignInError.noSubscription }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-or-"), key.count > 10 else { throw SignInError.invalidKey }
        keychain.write(key, for: Item.ownKey)
        ownKey = key
        resolveState()
    }

    func removeOwnKey() {
        keychain.delete(Item.ownKey)
        ownKey = nil
        resolveState()
    }

    // MARK: - Credit meter

    /// Reads the minted key's remaining credit from OpenRouter's key
    /// self-inspection endpoint (`GET /api/v1/key` → `data.limit_remaining`,
    /// USD, null when the key has no limit).
    func refreshMeter() async {
        guard !isDevKey, ownKey == nil, let key = mintedKey else { return }
        var request = URLRequest(url: Self.keyInfoURL, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await transport(request), key == mintedKey else { return }

        switch response.statusCode {
        case 200:
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let info = json?["data"] as? [String: Any]
            creditRemaining = (info?["limit_remaining"] as? Double).map { max(0, $0) }
        case 401:
            // The key was deleted on OpenRouter's side; ai-key mints a new one.
            _ = await refreshKey()
        default:
            break
        }
    }

    nonisolated static func liveTransport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Generic-password items in the login Keychain, one per account name, under
/// one service. Plain Security.framework.
struct KeychainStore {
    let service: String

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// True once the value is stored; failures are logged.
    @discardableResult
    func write(_ value: String, for account: String) -> Bool {
        let data = Data(value.utf8)
        var status = SecItemUpdate(query(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(q as CFDictionary, nil)
        }
        if status != errSecSuccess {
            os_log(.error, "Keychain write failed for %{public}@: %d", account, status)
        }
        return status == errSecSuccess
    }

    func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
