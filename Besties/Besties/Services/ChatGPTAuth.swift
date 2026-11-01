import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import Security

/// "Use your ChatGPT plan": OpenAI's open-source Sign in with ChatGPT flow.
/// The user signs in with their ChatGPT account in the browser; inference then
/// runs against their Plus/Pro plan through the Responses API
/// (`AIBackend.openAIResponses`), with no Besties subscription and no API key.
///
/// The whole OAuth lifecycle lives here: PKCE authorize in the default
/// browser, a one-shot loopback HTTP server for the redirect, the token
/// exchange, rotating refresh tokens, and Keychain persistence. First-time
/// sign-in authorizes as `dynamic_agent_client`; the callback hands back the
/// real issued client id (`oaiapp_…`), which is saved and used for the token
/// exchange and every later sign-in.
@MainActor
@Observable
final class ChatGPTAuth {
    enum State: Equatable {
        case signedOut
        /// The browser is open; waiting on the loopback redirect.
        case signingIn
        case signedIn(email: String)
    }

    enum AuthError: Error, LocalizedError, Equatable {
        /// Every loopback port was taken.
        case portUnavailable
        /// The browser never came back to the redirect.
        case timedOut
        /// The user declined (or OpenAI refused) on the consent page.
        case denied(String?)
        /// The callback's `state` didn't match this attempt's — someone else's
        /// redirect, not ours.
        case stateMismatch
        /// The token endpoint said no (detail when it gave one).
        case exchangeFailed(String?)
        /// Signed in, but without `chatgpt.tokens.use.direct` — the account
        /// can't run inference on its plan.
        case planNotAuthorized
        /// The refresh token is dead for good; only a fresh sign-in helps.
        case signedOut
        case offline

        var message: String {
            switch self {
            case .portUnavailable: "Couldn't open a local port for the sign-in. Close other apps using port 1455 and try again."
            case .timedOut: "The sign-in timed out. Try again."
            case .denied(let detail): "Sign-in was cancelled\(detail.map { " (\($0))" } ?? "")."
            case .stateMismatch: "The sign-in came back wrong. Try again."
            case .exchangeFailed(let detail): "ChatGPT sign-in failed\(detail.map { ": \($0)" } ?? "")."
            case .planNotAuthorized: "That ChatGPT account didn't authorize plan usage. Sign in with a ChatGPT Plus or Pro account."
            case .signedOut: "Your ChatGPT sign-in expired. Sign in again."
            case .offline: "Couldn't reach ChatGPT. Check your internet connection."
            }
        }

        var errorDescription: String? { message }
    }

    static let shared = ChatGPTAuth()

    /// The sentinel `SubscriptionManager.activeKey` hands out when the ChatGPT
    /// plan is the access source. It is not a credential: `AIBackend` routes it
    /// to the Responses API, and the real bearer token comes from
    /// `validAccessToken()` per request.
    static let planKey = "chatgpt-plan"

    /// Keychain account under the app's service holding `Credentials` as JSON.
    static let keychainAccount = "chatgptAuth"
    /// The issued client id (`oaiapp_…`) outlives sign-out, so a later sign-in
    /// reuses it rather than registering again.
    private static let clientIDAccount = "chatgptClientID"
    /// `ext_agent_host_id`: one stable id per Mac, sent on every authorize.
    private static let hostIDDefault = "chatgptHostID"

    // The official contract (developers.openai.com/siwc), followed exactly.
    private static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    private static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private static let dynamicClientID = "dynamic_agent_client"
    private static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    private static let resource = "https://api.openai.com/v1"
    /// Plan inference is authorized only when this scope was granted.
    private static let requiredScope = "chatgpt.tokens.use.direct"
    /// 1455 first (the port OpenAI's own tools use), then a few fallbacks —
    /// only the port may vary between sign-ins, never the host or path.
    private static let ports: [UInt16] = [1455, 1456, 1457, 8734]
    private static let signInTimeout: TimeInterval = 300
    /// Refresh this far before expiry so a token never dies mid-request.
    private static let expiryMargin: TimeInterval = 60

    /// Everything one sign-in produced, stored as a single Keychain JSON blob
    /// so a refresh's rotation replaces all of it atomically.
    private struct Credentials: Codable {
        var clientID: String
        var accessToken: String
        var refreshToken: String
        var expiry: Date
        var scopes: [String]
        var email: String
    }

    private(set) var state: State = .signedOut

    /// Lets `SubscriptionManager` fold sign-in/out into its access precedence.
    var onChange: (() -> Void)?

    private let keychain: KeychainStore
    private var credentials: Credentials?
    /// One refresh at a time: refresh tokens rotate, so concurrent callers
    /// must await the same rotation rather than racing with a dead token.
    private var refreshTask: Task<String, Error>?
    private var server: ChatGPTCallbackServer?

    init(keychain: KeychainStore = KeychainStore(service: "com.besties.app")) {
        self.keychain = keychain
        if let stored = keychain.read(Self.keychainAccount),
           let decoded = try? JSONDecoder().decode(Credentials.self, from: Data(stored.utf8)) {
            credentials = decoded
            state = .signedIn(email: decoded.email)
        }
    }

    var isSignedIn: Bool { credentials != nil }
    var email: String? { credentials?.email }

    /// A `urn:uuid:` minted once per Mac and reused for every sign-in.
    private static func hostID() -> String {
        if let saved = UserDefaults.standard.string(forKey: hostIDDefault) { return saved }
        let fresh = "urn:uuid:" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: hostIDDefault)
        return fresh
    }

    // MARK: - Sign-in

    /// Runs the whole browser flow. Throws an `AuthError` the paywall can show;
    /// on success `state` becomes `.signedIn` and `onChange` fires.
    func signIn() async throws {
        guard state != .signingIn else { return }
        state = .signingIn
        do {
            let fresh = try await performSignIn()
            credentials = fresh
            persist(fresh)
            state = .signedIn(email: fresh.email)
        } catch {
            server?.stop()
            server = nil
            state = credentials.map { .signedIn(email: $0.email) } ?? .signedOut
            onChange?()
            throw error
        }
        onChange?()
    }

    private func performSignIn() async throws -> Credentials {
        // Fresh state, nonce and verifier per attempt.
        let verifier = Self.base64URL(Self.randomBytes(32))
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let stateParam = Self.base64URL(Self.randomBytes(16))
        let nonce = Self.base64URL(Self.randomBytes(16))

        // The listener binds before the URL is built, since its port is part
        // of the redirect URI — which must be identical in authorize and
        // exchange, and loopback-by-IP (127.0.0.1, never localhost).
        let server = try await ChatGPTCallbackServer.start(tryingPorts: Self.ports)
        self.server = server
        defer {
            server.stop()
            self.server = nil
        }
        let redirectURI = "http://127.0.0.1:\(server.port)\(ChatGPTCallbackServer.callbackPath)"

        // First-time sign-in registers through the shared dynamic client;
        // after that the issued id is reused.
        let clientID = keychain.read(Self.clientIDAccount) ?? Self.dynamicClientID

        var params: [(String, String)] = [("client_id", clientID)]
        // Registration only: the name users see on OpenAI's consent screen.
        if clientID == Self.dynamicClientID { params.append(("agent_name_hint", appName)) }
        params += [
            ("ext_agent_host_id", Self.hostID()),
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("scope", Self.scopes),
            ("resource", Self.resource),
            ("state", stateParam),
            ("nonce", nonce),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
        ]
        // Every value fully percent-encoded (URLComponents leaves ":" and "/"
        // in query values alone; the contract says to encode them).
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = params
            .map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? $1)" }
            .joined(separator: "&")
        NSWorkspace.shared.open(URL(string: Self.authorizeURL.absoluteString + "?" + query)!)

        let callback = try await server.waitForCallback(timeout: Self.signInTimeout)
        guard callback["state"] == stateParam else { throw AuthError.stateMismatch }
        if let error = callback["error"] {
            throw AuthError.denied(callback["error_description"] ?? error)
        }
        guard let code = callback["code"] else { throw AuthError.denied(nil) }

        // The dynamic flow's callback carries the real issued client id; save
        // it for the exchange below and for every later sign-in.
        let issuedClientID = callback["client_id"] ?? clientID
        guard issuedClientID != Self.dynamicClientID else {
            throw AuthError.exchangeFailed("no client id was issued")
        }
        keychain.write(issuedClientID, for: Self.clientIDAccount)

        let (json, status) = try await Self.postForm(Self.tokenURL, [
            "grant_type": "authorization_code",
            "client_id": issuedClientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "resource": Self.resource,
        ])
        guard status == 200 else {
            // An invalid_grant means the code is spent; it's discarded with
            // this attempt and the user restarts the auth from the button.
            throw AuthError.exchangeFailed(json?["error_description"] as? String ?? json?["error"] as? String)
        }
        guard let access = json?["access_token"] as? String,
              let refresh = json?["refresh_token"] as? String else {
            throw AuthError.exchangeFailed("the token response was incomplete")
        }
        let granted = Self.grantedScopes(json)
        guard granted.contains(Self.requiredScope) else { throw AuthError.planNotAuthorized }

        return Credentials(
            clientID: issuedClientID,
            accessToken: access,
            refreshToken: refresh,
            expiry: Date().addingTimeInterval((json?["expires_in"] as? Double) ?? 3600),
            scopes: granted,
            // Display only, so the JWT payload is read without verifying the
            // signature — the token itself came straight from the token endpoint.
            email: (json?["id_token"] as? String).flatMap(Self.email(fromIDToken:)) ?? "your ChatGPT account")
    }

    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        keychain.delete(Self.keychainAccount)
        credentials = nil
        state = .signedOut
        onChange?()
    }

    // MARK: - Tokens

    /// The bearer token for a Responses request, refreshed when (nearly)
    /// expired. Refresh tokens rotate, so refreshes are serialized and the
    /// stored blob is replaced whole. An unrecoverable refresh (invalid_grant)
    /// signs out, so the paywall comes back asking to sign in again.
    func validAccessToken() async throws -> String {
        guard let credentials else { throw AuthError.signedOut }
        guard credentials.scopes.contains(Self.requiredScope) else { throw AuthError.planNotAuthorized }
        if credentials.expiry.timeIntervalSinceNow > Self.expiryMargin {
            return credentials.accessToken
        }
        let task = refreshTask ?? Task { try await refresh(credentials) }
        refreshTask = task
        defer { if refreshTask == task { refreshTask = nil } }
        return try await task.value
    }

    private func refresh(_ old: Credentials) async throws -> String {
        // Standard OAuth refresh against the same token endpoint; the SiwC
        // docs leave this request underspecified, so errors surface plainly.
        let (json, status) = try await Self.postForm(Self.tokenURL, [
            "grant_type": "refresh_token",
            "client_id": old.clientID,
            "refresh_token": old.refreshToken,
        ])
        guard status == 200 else {
            if json?["error"] as? String == "invalid_grant" {
                signOut()
                throw AuthError.signedOut
            }
            throw AuthError.exchangeFailed(json?["error_description"] as? String ?? json?["error"] as? String)
        }
        guard let access = json?["access_token"] as? String else {
            throw AuthError.exchangeFailed("the refresh response was incomplete")
        }
        // Atomic rotation: token, expiry, scopes and refresh token move
        // together, in memory and in the Keychain.
        var fresh = old
        fresh.accessToken = access
        fresh.refreshToken = (json?["refresh_token"] as? String) ?? old.refreshToken
        fresh.expiry = Date().addingTimeInterval((json?["expires_in"] as? Double) ?? 3600)
        let granted = Self.grantedScopes(json)
        if !granted.isEmpty { fresh.scopes = granted }
        credentials = fresh
        persist(fresh)
        return access
    }

    private func persist(_ credentials: Credentials) {
        guard let data = try? JSONEncoder().encode(credentials),
              let json = String(data: data, encoding: .utf8) else { return }
        keychain.write(json, for: Self.keychainAccount)
    }

    // MARK: - Plumbing

    /// `scope` (space-separated string) or `scopes` (array) — the token
    /// endpoint has sent both shapes.
    private static func grantedScopes(_ json: [String: Any]?) -> [String] {
        if let list = json?["scopes"] as? [String] { return list }
        if let joined = json?["scope"] as? String {
            return joined.split(separator: " ").map(String.init)
        }
        return []
    }

    private static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return claims["email"] as? String
    }

    private static func postForm(_ url: URL, _ fields: [String: String]) async throws -> (json: [String: Any]?, status: Int) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AuthError.offline
        }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            // SecRandom only fails in pathological cases; SystemRandom is a
            // cryptographically secure fallback, not a downgrade.
            bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes)
    }

    /// base64url, no padding — PKCE's encoding.
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback callback server

/// A one-shot HTTP listener for the OAuth redirect: binds 127.0.0.1 on the
/// first free port, answers GET /auth/callback with a tiny "go back to
/// Besties" page, hands the query parameters to the waiting sign-in, and is
/// stopped by its owner. Anything else gets a 404 and the listener keeps
/// waiting. Deliberately not coupled to MCPListener — this serves exactly one
/// request and dies.
private final class ChatGPTCallbackServer: @unchecked Sendable {
    static let callbackPath = "/auth/callback"

    let port: UInt16

    private let listener: NWListener
    private let queue = DispatchQueue(label: "besties.chatgpt-auth")
    /// Guarded by `queue`. Resumed exactly once — by the callback, the
    /// timeout, or `stop()`.
    private var continuation: CheckedContinuation<[String: String], Error>?

    static func start(tryingPorts ports: [UInt16]) async throws -> ChatGPTCallbackServer {
        for port in ports {
            if let server = try? await ChatGPTCallbackServer(port: port) { return server }
        }
        throw ChatGPTAuth.AuthError.portUnavailable
    }

    private init(port: UInt16) async throws {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        // 127.0.0.1 by IP: the contract's redirect host, never "localhost".
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.port = port
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        // The bind result arrives through the state handler; wait for it so a
        // taken port fails here and the caller can try the next one.
        try await withCheckedThrowingContinuation { (started: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    started.resume()
                case .failed(let error), .waiting(let error):
                    resumed = true
                    listener.cancel()
                    started.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        listener.stateUpdateHandler = nil
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(ChatGPTAuth.AuthError.timedOut))
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.finish(.failure(ChatGPTAuth.AuthError.timedOut))
            self.listener.cancel()
        }
    }

    /// On `queue`. Resumes the waiter once; later calls are no-ops.
    private func finish(_ result: Result<[String: String], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
        // Drop clients that connect and never finish a request.
        queue.asyncAfter(deadline: .now() + 30) { connection.cancel() }   // no-op if already closed
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(toHead: buffer[buffer.startIndex..<headerEnd.lowerBound], on: connection)
            } else if isComplete || error != nil || buffer.count > 16 * 1024 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    /// On `queue`. Parses "GET /auth/callback?… HTTP/1.1" and answers it.
    private func respond(toHead head: Data, on connection: NWConnection) {
        let requestLine = String(data: head, encoding: .utf8)?.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
              components.path == Self.callbackPath else {
            send(status: "404 Not Found", html: "<!doctype html><title>Besties</title>Not found.", on: connection)
            return
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let page = query["error"] == nil ? Self.successPage : Self.failurePage
        send(status: "200 OK", html: page, on: connection) { [weak self] in
            self?.queue.async { self?.finish(.success(query)) }
        }
    }

    private func send(status: String, html: String, on connection: NWConnection, then: (() -> Void)? = nil) {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
            then?()
        })
    }

    /// Brand paper/ink, nothing to click — the browser tab's only job is done.
    private static let successPage = """
        <!doctype html><html><head><meta charset="utf-8"><title>Besties</title></head>\
        <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;\
        background:#FDF8EE;color:#211E1A;font-family:-apple-system,'SF Pro Rounded',sans-serif;text-align:center">\
        <div><div style="font-size:44px">✨</div><h1 style="font-weight:800;margin:12px 0 4px">You're signed in</h1>\
        <p style="opacity:.6;margin:0">Go back to Besties — you can close this tab.</p></div></body></html>
        """

    private static let failurePage = """
        <!doctype html><html><head><meta charset="utf-8"><title>Besties</title></head>\
        <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;\
        background:#FDF8EE;color:#211E1A;font-family:-apple-system,'SF Pro Rounded',sans-serif;text-align:center">\
        <div><h1 style="font-weight:800;margin:12px 0 4px">Sign-in didn't finish</h1>\
        <p style="opacity:.6;margin:0">Go back to Besties and try again.</p></div></body></html>
        """
}
