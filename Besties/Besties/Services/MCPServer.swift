import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Besties as an MCP server: lets AI apps on this Mac (LM Studio, Claude
// Desktop, …) read your message history through a few read-only tools, so
// people can use a local model instead of sending history to a cloud AI.
//
// Off by default. When on, it listens on 127.0.0.1 only, while Besties is
// open, and every request needs the bearer token shown in Settings. It speaks
// Streamable HTTP for both MCP eras: the stateless 2026-07-28 revision
// (per-request `_meta`, `server/discover`) and the `initialize` handshake of
// 2025-11-25 and earlier, which most clients still use.
//
// Everything above the socket lives in this file as plain Foundation, so it
// can be tested without a Mac; MCPListener (Network.framework) is the socket.

// MARK: - What the tools read

struct MCPPerson {
    let id: String              // stable id the tools accept back (the merge key)
    let name: String
    let totalMessages: Int
    let sentMessages: Int
    let firstDate: Date
    let lastDate: Date
}

struct MCPMessage {
    let date: Date
    let isFromMe: Bool
    let text: String
}

struct MCPSearchHit {
    let date: Date
    let chat: String            // person's name, or a group chat's name
    let isFromMe: Bool
    let snippet: String
}

/// The app's data, as the tools see it. Called off the main thread.
protocol MCPLibrary: AnyObject {
    /// One entry per person (all their handles merged), busiest first.
    func people() -> [MCPPerson]
    /// A person's messages, oldest first. With `from`, the first `limit` at or
    /// after it; otherwise the last `limit` before `to` (or now).
    func messages(personID: String, from: Date?, to: Date?, limit: Int) throws -> [MCPMessage]
    func search(_ query: String, personID: String?, limit: Int) throws -> [MCPSearchHit]
    /// People worth reconnecting with, best first (the Reconnect tab's ranking).
    func reconnect(maxDaysSinceContact: Int, limit: Int) -> [MCPPerson]
}

// MARK: - HTTP

struct MCPHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]   // lowercased names
    let body: Data

    enum Parse {
        case incomplete
        case invalid
        case complete(MCPHTTPRequest)
    }

    static let maxSize = 1 << 20

    /// Parses one HTTP/1.1 request from the start of `data`.
    static func parse(_ data: Data) -> Parse {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 64 * 1024 ? .invalid : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid }   // clients send Content-Length
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxSize else { return .invalid }
        let bodyStart = headerEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        let target = String(requestLine[1])
        return .complete(MCPHTTPRequest(
            method: String(requestLine[0]),
            path: String(target.split(separator: "?", maxSplits: 1).first ?? ""),
            headers: headers,
            body: Data(body)
        ))
    }
}

struct MCPHTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ status: Int, _ object: Any) -> MCPHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return MCPHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    func serialized() -> Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

// MARK: - MCP

final class MCPHandler {
    static let modernVersion = "2026-07-28"
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    static let path = "/mcp"
    private static let versionKey = "io.modelcontextprotocol/protocolVersion"

    private let tokenLock = NSLock()
    private var token: String
    private let library: MCPLibrary
    private let serverVersion: String

    init(token: String, library: MCPLibrary, serverVersion: String) {
        self.token = token
        self.library = library
        self.serverVersion = serverVersion
    }

    /// Swaps the token in place, so a running server needn't restart.
    func setToken(_ newToken: String) {
        tokenLock.lock()
        token = newToken
        tokenLock.unlock()
    }

    private var currentToken: String {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        return token
    }

    static let instructions = """
        \(appName) reads the user's own iMessage and WhatsApp history on this Mac. \
        Use list_people or reconnect_suggestions to find someone, then get_messages to read a conversation \
        (pass `from`/`to` dates to read a period) or search_messages to find mentions of a topic. \
        Dates are local time, formatted yyyy-MM-dd HH:mm. "Me" is the user. Everything is read-only.
        """

    func handle(_ request: MCPHTTPRequest) -> MCPHTTPResponse {
        // DNS rebinding: a web page can resolve its own name to 127.0.0.1, but
        // can't change Host/Origin. Only localhost names are accepted.
        if let host = request.headers["host"], !Self.isLocal(authority: host) {
            return .json(403, Self.error(nil, -32600, "Forbidden host"))
        }
        if let origin = request.headers["origin"], !Self.isLocal(origin: origin) {
            return .json(403, Self.error(nil, -32600, "Forbidden origin"))
        }
        guard request.path == Self.path else { return MCPHTTPResponse(status: 404) }
        guard Self.constantTimeEquals(request.headers["authorization"] ?? "", "Bearer \(currentToken)") else {
            var response = MCPHTTPResponse.json(401, Self.error(nil, -32600, "Missing or wrong token. Copy it from \(appName) → Settings → AI Apps."))
            response.headers["WWW-Authenticate"] = "Bearer"
            return response
        }
        // No server-initiated streams or sessions here.
        guard request.method == "POST" else { return MCPHTTPResponse(status: 405, headers: ["Allow": "POST"]) }

        guard let message = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            return .json(400, Self.error(nil, -32700, "Expected one JSON-RPC 2.0 request"))
        }
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]
        guard id != nil else { return MCPHTTPResponse(status: 202) }   // notifications need no reply

        let meta = params["_meta"] as? [String: Any]
        if let version = meta?[Self.versionKey] as? String {
            return handleModern(request, id: id, method: method, params: params, version: version)
        }
        return handleLegacy(request, id: id, method: method, params: params)
    }

    // 2026-07-28: stateless, version on every request, headers mirror the body.
    private func handleModern(_ request: MCPHTTPRequest, id: Any?, method: String, params: [String: Any], version: String) -> MCPHTTPResponse {
        guard version == Self.modernVersion else {
            return .json(400, Self.error(id, -32022, "Unsupported protocol version",
                                         data: ["supported": [Self.modernVersion] + Self.legacyVersions, "requested": version]))
        }
        guard request.headers["mcp-protocol-version"] == version else {
            return .json(400, Self.error(id, -32020, "Header mismatch: MCP-Protocol-Version must be \(version)"))
        }
        guard request.headers["mcp-method"] == method else {
            return .json(400, Self.error(id, -32020, "Header mismatch: Mcp-Method must be \(method)"))
        }
        if method == "tools/call" {
            let name = params["name"] as? String ?? ""
            guard Self.decodeHeader(request.headers["mcp-name"]) == name else {
                return .json(400, Self.error(id, -32020, "Header mismatch: Mcp-Name must be \(name)"))
            }
        }
        switch method {
        case "server/discover":
            return .json(200, Self.result(id, [
                "resultType": "complete",
                "supportedVersions": [Self.modernVersion] + Self.legacyVersions,
                "capabilities": ["tools": [String: Any]()],
                "_meta": ["io.modelcontextprotocol/serverInfo": serverInfo],
                "instructions": Self.instructions,
            ]))
        case "tools/list":
            return .json(200, Self.result(id, ["resultType": "complete", "tools": Self.tools]))
        case "tools/call":
            var result = callTool(params)
            result["resultType"] = "complete"
            return .json(200, Self.result(id, result))
        case "ping":
            return .json(200, Self.result(id, ["resultType": "complete"]))
        default:
            return .json(404, Self.error(id, -32601, "Method not found: \(method)"))
        }
    }

    // 2025-11-25 and earlier: `initialize` handshake, then plain requests.
    // Stateless here too: no session ids are issued.
    private func handleLegacy(_ request: MCPHTTPRequest, id: Any?, method: String, params: [String: Any]) -> MCPHTTPResponse {
        if let header = request.headers["mcp-protocol-version"], !Self.legacyVersions.contains(header) {
            return .json(400, Self.error(id, -32600, "Unsupported MCP-Protocol-Version \(header); this server supports \(([Self.modernVersion] + Self.legacyVersions).joined(separator: ", "))"))
        }
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return .json(200, Self.result(id, [
                "protocolVersion": Self.legacyVersions.contains(requested) ? requested : Self.legacyVersions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": serverInfo,
                "instructions": Self.instructions,
            ]))
        case "tools/list":
            return .json(200, Self.result(id, ["tools": Self.tools]))
        case "tools/call":
            return .json(200, Self.result(id, callTool(params)))
        case "ping":
            return .json(200, Self.result(id, [:]))
        default:
            return .json(200, Self.error(id, -32601, "Method not found: \(method)"))
        }
    }

    private var serverInfo: [String: Any] { ["name": appName, "version": serverVersion] }

    // MARK: Tools

    static let tools: [[String: Any]] = [
        [
            "name": "list_people",
            "title": "List people",
            "description": "People the user has messaged, with message counts and last contact. Use the returned id (or the name) with the other tools.",
            "inputSchema": schema([
                "query": ["type": "string", "description": "Filter by name (optional)"],
                "sort": ["type": "string", "enum": ["most_messages", "most_recent"], "description": "Default most_messages"],
                "limit": ["type": "integer", "minimum": 1, "maximum": 200, "description": "Default 30"],
            ]),
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "get_messages",
            "title": "Read a conversation",
            "description": "Messages between the user and one person, oldest first. With `from`, reads forward from that date; otherwise returns the most recent messages (before `to`, if given).",
            "inputSchema": schema([
                "person": ["type": "string", "description": "A name or id from list_people"],
                "from": ["type": "string", "description": "Start date, yyyy-MM-dd (optional)"],
                "to": ["type": "string", "description": "End date, yyyy-MM-dd, exclusive (optional)"],
                "limit": ["type": "integer", "minimum": 1, "maximum": 1000, "description": "Default 200"],
            ], required: ["person"]),
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "search_messages",
            "title": "Search messages",
            "description": "Full-text search across all conversations (or one person's), newest first. Returns dates, who, and a snippet; read around a hit with get_messages.",
            "inputSchema": schema([
                "query": ["type": "string", "description": "Words to find"],
                "person": ["type": "string", "description": "Only this person (optional)"],
                "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Default 25"],
            ], required: ["query"]),
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "reconnect_suggestions",
            "title": "Who to reconnect with",
            "description": "People the user used to talk to a lot but hasn't lately, best first (the app's Reconnect ranking).",
            "inputSchema": schema([
                "max_days_since_contact": ["type": "integer", "minimum": 7, "maximum": 3650, "description": "Only people last contacted within this many days. Default 365"],
                "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Default 15"],
            ]),
            "annotations": ["readOnlyHint": true],
        ],
    ]

    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    private func callTool(_ params: [String: Any]) -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let text: String
            switch name {
            case "list_people": text = listPeople(args)
            case "get_messages": text = try getMessages(args)
            case "search_messages": text = try searchMessages(args)
            case "reconnect_suggestions": text = reconnect(args)
            default: throw ToolError("Unknown tool \(name)")
            }
            return ["content": [["type": "text", "text": text]], "isError": false]
        } catch {
            return ["content": [["type": "text", "text": (error as? ToolError)?.message ?? error.localizedDescription]], "isError": true]
        }
    }

    private struct ToolError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func listPeople(_ args: [String: Any]) -> String {
        var people = library.people()
        if let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
            people = people.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        if args["sort"] as? String == "most_recent" { people.sort { $0.lastDate > $1.lastDate } }
        let limit = Self.clamp(args["limit"], default: 30, max: 200)
        guard !people.isEmpty else { return "No one matches." }
        return people.prefix(limit).map(Self.describe).joined(separator: "\n")
            + (people.count > limit ? "\n…and \(people.count - limit) more" : "")
    }

    private func getMessages(_ args: [String: Any]) throws -> String {
        let person = try resolve(args["person"])
        let from = try Self.parseDay(args["from"], field: "from")
        let to = try Self.parseDay(args["to"], field: "to")
        let limit = Self.clamp(args["limit"], default: 200, max: 1000)
        let messages = try library.messages(personID: person.id, from: from, to: to, limit: limit)
        let header = "Messages with \(person.name) (\(Self.describe(person))):"
        guard !messages.isEmpty else { return header + "\nNo messages in that range." }
        let lines = messages.map { "[\(Self.stamp($0.date))] \($0.isFromMe ? "Me" : person.name): \($0.text)" }
        return ([header] + lines).joined(separator: "\n")
    }

    private func searchMessages(_ args: [String: Any]) throws -> String {
        guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            throw ToolError("`query` is required.")
        }
        let person = try args["person"].map { try resolve($0) }
        let hits = try library.search(query, personID: person?.id, limit: Self.clamp(args["limit"], default: 25, max: 100))
        guard !hits.isEmpty else { return "No messages match “\(query)”." }
        return hits.map { "[\(Self.stamp($0.date))] \($0.chat) — \($0.isFromMe ? "Me" : $0.chat): \($0.snippet)" }
            .joined(separator: "\n")
    }

    private func reconnect(_ args: [String: Any]) -> String {
        let people = library.reconnect(maxDaysSinceContact: Self.clamp(args["max_days_since_contact"], default: 365, max: 3650),
                                       limit: Self.clamp(args["limit"], default: 15, max: 100))
        return people.isEmpty ? "No one to suggest right now." : people.map(Self.describe).joined(separator: "\n")
    }

    /// A person by id, exact name, or a name fragment that matches only one.
    private func resolve(_ value: Any?) throws -> MCPPerson {
        guard let query = (value as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            throw ToolError("`person` is required: a name or id from list_people.")
        }
        let people = library.people()
        if let match = people.first(where: { $0.id == query })
            ?? people.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
            return match
        }
        let partial = people.filter { $0.name.localizedCaseInsensitiveContains(query) }
        if partial.count == 1 { return partial[0] }
        if partial.isEmpty { throw ToolError("No one named “\(query)”. Try list_people with a query.") }
        throw ToolError("“\(query)” matches several people; use one id:\n" + partial.prefix(10).map(Self.describe).joined(separator: "\n"))
    }

    // MARK: Helpers

    private static func describe(_ p: MCPPerson) -> String {
        "\(p.name) — id \(p.id) — \(p.totalMessages.formatted()) messages (\(p.sentMessages.formatted()) from Me), \(day(p.firstDate)) to \(day(p.lastDate))"
    }

    private static func clamp(_ value: Any?, default fallback: Int, max upper: Int) -> Int {
        let n = (value as? Int) ?? (value as? Double).map { Int($0) } ?? (value as? String).flatMap { Int($0) } ?? fallback
        return Swift.min(Swift.max(n, 1), upper)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    private static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }

    private static func parseDay(_ value: Any?, field: String) throws -> Date? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        guard let date = dayFormatter.date(from: String(text.prefix(10))) else {
            throw ToolError("`\(field)` must be a date like 2024-03-01.")
        }
        return date
    }

    private static func isLocal(authority: String) -> Bool {
        let host = authority.hasPrefix("[") ? String(authority.prefix { $0 != "]" }.dropFirst()) : String(authority.split(separator: ":").first ?? "")
        return ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }

    private static func isLocal(origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host else { return false }
        return isLocal(authority: host.contains(":") ? "[\(host)]" : host)
    }

    /// Mcp-Name may arrive Base64-wrapped: =?base64?…?=
    private static func decodeHeader(_ value: String?) -> String? {
        guard let value, value.hasPrefix("=?base64?"), value.hasSuffix("?=") else { return value }
        let encoded = String(value.dropFirst(9).dropLast(2))
        return Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func result(_ id: Any?, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    private static func error(_ id: Any?, _ code: Int, _ message: String, data: [String: Any]? = nil) -> [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        var response: [String: Any] = ["jsonrpc": "2.0", "error": error]
        if let id { response["id"] = id }
        return response
    }

    /// A random 32-byte token, URL-safe.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

#if canImport(Network)
import Network

/// The socket: HTTP/1.1 on 127.0.0.1, one request per connection.
final class MCPListener {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "besties.mcp")
    private let handler: MCPHandler

    init(handler: MCPHandler) {
        self.handler = handler
    }

    func start(port: UInt16, onState: @escaping (NWListener.State) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        // Rebinding right after a stop or relaunch would otherwise fail
        // while old connections sit in TIME_WAIT.
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? 47210)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = onState
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
        // Drop clients that connect and never finish a request.
        queue.asyncAfter(deadline: .now() + 30) { connection.cancel() }   // no-op if already closed
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch MCPHTTPRequest.parse(buffer) {
            case .complete(let request):
                self.reply(self.handler.handle(request), on: connection)
            case .invalid:
                self.reply(MCPHTTPResponse(status: 400), on: connection)
            case .incomplete:
                if isComplete || error != nil { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
            }
        }
    }

    private func reply(_ response: MCPHTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
