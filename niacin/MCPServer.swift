import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.oldsalt.niacin", category: "mcp")
private let auditLog = Logger(subsystem: "com.oldsalt.niacin", category: "audit")

// HTTP-transport MCP (Model Context Protocol) server. Bound to 127.0.0.1
// only — no external traffic. Bearer-token auth on every request via the
// `Authorization: Bearer <token>` header.
//
// Why HTTP rather than stdio (the original MCP transport): under MAS App
// Sandbox a client-spawned stdio child runs in its own container and can't
// drive the main app's IOPMAssertion lifecycle without bridging back via
// IPC. That bridge would be HTTP-shaped anyway. Going HTTP-first lets every
// MCP client that supports HTTP/Streamable-HTTP (Claude Desktop, Claude
// Code, Cursor, …) just work.
//
// Implemented JSON-RPC methods:
//   initialize        → handshake + server capabilities
//   tools/list        → enumerate the tool surface
//   tools/call        → invoke keep_awake, release_awake, or status
//   ping              → liveness probe
//
// Sessions created over MCP join the same force-active pool as the
// ProcessWatcher and AIRuntimeProbeRegistry signals (see AppState's
// `mcpSessions` map). Bounded body size (256 KiB) and one-shot connections
// keep the attack surface small for a localhost service.

@MainActor
protocol MCPDelegate: AnyObject {
    func mcpKeepAwake(durationSeconds: Int?, reason: String, allowDisplaySleep: Bool, clientName: String?) -> MCPKeepAwakeResult
    func mcpReleaseAwake(sessionId: String?) -> Bool
    func mcpStatus() -> MCPStatus
}

struct MCPKeepAwakeResult: Sendable {
    let sessionId: String
    let expiresAt: Date?
}

struct MCPStatus: Sendable {
    let keepingAwake: Bool
    let activeUntil: Date?
    let forceActiveSources: [String]
}

@MainActor
final class MCPServer {
    static let defaultPort: UInt16 = 11473
    // Try a small range so an existing collider on the default port doesn't
    // brick the feature — the chosen port surfaces in Settings for the user
    // to paste into their client config.
    private static let portRange: ClosedRange<UInt16> = 11473...11479

    private weak var delegate: MCPDelegate?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private(set) var actualPort: UInt16?

    init(delegate: MCPDelegate) {
        self.delegate = delegate
    }

    var isRunning: Bool { listener != nil }

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.requiredInterfaceType = .loopback

        var lastError: Error?
        for candidate in Self.portRange {
            do {
                let port = NWEndpoint.Port(rawValue: candidate)!
                let l = try NWListener(using: params, on: port)
                self.listener = l
                self.actualPort = candidate
                lastError = nil
                break
            } catch {
                lastError = error
            }
        }
        guard let listener else {
            throw lastError ?? NSError(
                domain: "com.oldsalt.niacin.mcp",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No port in \(Self.portRange) available"]
            )
        }

        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in self?.handleListenerState(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection: connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        log.info("mcp server listening on 127.0.0.1:\(self.actualPort ?? 0, privacy: .public)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        actualPort = nil
        for conn in connections.values { conn.cancel() }
        connections.removeAll()
        log.info("mcp server stopped")
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .failed(let err):
            log.error("mcp listener failed: \(err.localizedDescription, privacy: .public)")
            stop()
        case .cancelled:
            log.info("mcp listener cancelled")
        default:
            break
        }
    }

    private func accept(connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in self?.connections.removeValue(forKey: id) }
            default: break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        // Detach so we can `await` on the connection without blocking the
        // listener queue.
        Task.detached { [weak self] in
            do {
                let request = try await readHTTPRequest(connection: connection)
                let response: HTTPResponse
                if let server = self {
                    response = await server.handle(request: request)
                } else {
                    response = httpPlain(status: 503, body: "server stopped")
                }
                try await writeHTTPResponse(response, to: connection)
            } catch {
                let response = httpPlain(status: 400, body: "bad request: \(error.localizedDescription)")
                try? await writeHTTPResponse(response, to: connection)
            }
            connection.cancel()
        }
    }

    // MARK: - Request handling (main-actor isolated — touches delegate)

    func handle(request: HTTPRequest) -> HTTPResponse {
        guard let stored = (try? MCPTokenStore.currentToken()), !stored.isEmpty else {
            return jsonRPCErrorResponse(httpStatus: 503, code: -32001, message: "MCP server not configured (no token)")
        }
        guard let auth = request.headers["authorization"],
              isBearer(auth, token: stored) else {
            log.warning("mcp auth failed for \(request.method) \(request.path)")
            return jsonRPCErrorResponse(httpStatus: 401, code: -32001, message: "unauthorized")
        }

        guard request.method == "POST", request.path == "/" || request.path == "/mcp" else {
            return jsonRPCErrorResponse(httpStatus: 404, code: -32601, message: "endpoint not found")
        }

        let envelope: JSONRPCEnvelope
        do {
            envelope = try JSONDecoder().decode(JSONRPCEnvelope.self, from: request.body)
        } catch {
            return jsonRPCErrorResponse(httpStatus: 400, code: -32700, message: "parse error: \(error.localizedDescription)")
        }
        return dispatch(envelope: envelope)
    }

    private func isBearer(_ header: String, token: String) -> Bool {
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        return String(parts[1]) == token
    }

    private func dispatch(envelope: JSONRPCEnvelope) -> HTTPResponse {
        let id = envelope.id
        switch envelope.method {
        case "initialize":
            return jsonRPCSuccess(id: id, result: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string("niacin"),
                    "version": .string(appVersion()),
                ]),
            ]))
        case "notifications/initialized", "ping":
            return jsonRPCSuccess(id: id, result: .object([:]))
        case "tools/list":
            return jsonRPCSuccess(id: id, result: .object(["tools": .array(toolDefinitions())]))
        case "tools/call":
            return invokeTool(id: id, params: envelope.params)
        default:
            return jsonRPCErrorBody(id: id, code: -32601, message: "method not found: \(envelope.method)")
        }
    }

    private func invokeTool(id: JSONRPCID?, params: JSONValue?) -> HTTPResponse {
        guard case .object(let dict) = params,
              case .string(let name) = dict["name"] ?? .null else {
            return jsonRPCErrorBody(id: id, code: -32602, message: "missing tool name")
        }
        let args: [String: JSONValue]
        if case .object(let a) = dict["arguments"] ?? .object([:]) { args = a } else { args = [:] }

        switch name {
        case "keep_awake":    return callKeepAwake(id: id, args: args)
        case "release_awake": return callReleaseAwake(id: id, args: args)
        case "status":        return callStatus(id: id)
        default:
            return jsonRPCErrorBody(id: id, code: -32602, message: "unknown tool: \(name)")
        }
    }

    private func callKeepAwake(id: JSONRPCID?, args: [String: JSONValue]) -> HTTPResponse {
        let reason = args["reason"].flatMap(stringValue) ?? "MCP client request"
        let allowDisplaySleep = args["allow_display_sleep"].flatMap(boolValue) ?? false
        let clientName = args["client"].flatMap(stringValue)
        let duration = args["duration_seconds"].flatMap(intValue)

        guard let delegate else {
            return jsonRPCErrorBody(id: id, code: -32603, message: "delegate unavailable")
        }
        let result = delegate.mcpKeepAwake(
            durationSeconds: duration,
            reason: reason,
            allowDisplaySleep: allowDisplaySleep,
            clientName: clientName
        )
        auditLog.info("mcp keep-awake: session=\(result.sessionId, privacy: .public) reason=\(reason, privacy: .public) duration=\(duration ?? -1, privacy: .public)s client=\(clientName ?? "?", privacy: .public)")
        let expiresText = result.expiresAt.map { iso8601($0) } ?? "indefinite"
        let body = "keep-awake granted. session=\(result.sessionId) expires=\(expiresText)"
        return jsonRPCSuccess(id: id, result: .object([
            "content": .array([.object([
                "type": .string("text"),
                "text": .string(body),
            ])]),
            "structuredContent": .object([
                "session_id": .string(result.sessionId),
                "expires_at": result.expiresAt.map { .string(iso8601($0)) } ?? .null,
            ]),
        ]))
    }

    private func callReleaseAwake(id: JSONRPCID?, args: [String: JSONValue]) -> HTTPResponse {
        let sessionId = args["session_id"].flatMap(stringValue)
        let released = delegate?.mcpReleaseAwake(sessionId: sessionId) ?? false
        auditLog.info("mcp release: session=\(sessionId ?? "all", privacy: .public) released=\(released, privacy: .public)")
        return jsonRPCSuccess(id: id, result: .object([
            "content": .array([.object([
                "type": .string("text"),
                "text": .string(released ? "released" : "no matching session"),
            ])]),
            "structuredContent": .object(["released": .bool(released)]),
        ]))
    }

    private func callStatus(id: JSONRPCID?) -> HTTPResponse {
        guard let status = delegate?.mcpStatus() else {
            return jsonRPCErrorBody(id: id, code: -32603, message: "delegate unavailable")
        }
        let activeUntilJSON: JSONValue = status.activeUntil.map { .string(iso8601($0)) } ?? .null
        let summary = status.keepingAwake
            ? "Niacin is keeping the system awake. Sources: \(status.forceActiveSources.joined(separator: ", "))"
            : "Niacin is idle (system can sleep)."
        return jsonRPCSuccess(id: id, result: .object([
            "content": .array([.object([
                "type": .string("text"),
                "text": .string(summary),
            ])]),
            "structuredContent": .object([
                "keeping_awake": .bool(status.keepingAwake),
                "active_until": activeUntilJSON,
                "force_active_sources": .array(status.forceActiveSources.map { .string($0) }),
            ]),
        ]))
    }

    // MARK: - Reply helpers

    private func jsonRPCSuccess(id: JSONRPCID?, result: JSONValue) -> HTTPResponse {
        let envelope = JSONRPCResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
        return httpJSON(status: 200, body: envelope.encoded())
    }

    private func jsonRPCErrorBody(id: JSONRPCID?, code: Int, message: String) -> HTTPResponse {
        let err = JSONRPCError(code: code, message: message)
        let envelope = JSONRPCResponse(jsonrpc: "2.0", id: id, result: nil, error: err)
        return httpJSON(status: 200, body: envelope.encoded())
    }

    private func jsonRPCErrorResponse(httpStatus: Int, code: Int, message: String) -> HTTPResponse {
        let err = JSONRPCError(code: code, message: message)
        let envelope = JSONRPCResponse(jsonrpc: "2.0", id: nil, result: nil, error: err)
        return httpJSON(status: httpStatus, body: envelope.encoded())
    }
}

// MARK: - Tool catalog

private func toolDefinitions() -> [JSONValue] {
    [
        .object([
            "name": .string("keep_awake"),
            "description": .string("Hold a power assertion preventing system sleep. Returns a session id; call release_awake or wait for duration to expire."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "duration_seconds": .object([
                        "type": .string("integer"),
                        "description": .string("How long to hold the assertion. Omit for indefinite."),
                    ]),
                    "reason": .object([
                        "type": .string("string"),
                        "description": .string("Short human-readable reason — appears in the menu bar tooltip and audit log."),
                    ]),
                    "allow_display_sleep": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, the display may sleep but the system stays awake."),
                    ]),
                    "client": .object([
                        "type": .string("string"),
                        "description": .string("Identifier of the calling client (logged for audit)."),
                    ]),
                ]),
            ]),
        ]),
        .object([
            "name": .string("release_awake"),
            "description": .string("Release a keep-awake session. Omitting session_id releases all MCP-owned sessions."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "session_id": .object([
                        "type": .string("string"),
                        "description": .string("Session id returned by keep_awake."),
                    ]),
                ]),
            ]),
        ]),
        .object([
            "name": .string("status"),
            "description": .string("Get current Niacin state — whether the system is being kept awake and which sources are holding assertions."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
        ]),
    ]
}

// MARK: - JSON value helpers

private func stringValue(_ v: JSONValue) -> String? {
    if case .string(let s) = v { return s } else { return nil }
}
private func boolValue(_ v: JSONValue) -> Bool? {
    if case .bool(let b) = v { return b } else { return nil }
}
private func intValue(_ v: JSONValue) -> Int? {
    switch v {
    case .int(let n): return n
    case .double(let d): return Int(d)
    default: return nil
    }
}

private func iso8601(_ date: Date) -> String {
    date.formatted(.iso8601)
}

private func appVersion() -> String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
}

// MARK: - HTTP request / response value types (nonisolated, Sendable)

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]  // lowercased keys
    let body: Data
}

struct HTTPResponse: Sendable {
    let status: Int
    let headers: [(String, String)]
    let body: Data

    nonisolated fileprivate var rendered: Data {
        var out = "HTTP/1.1 \(status) \(statusReason(status))\r\n"
        out += "Content-Length: \(body.count)\r\n"
        out += "Connection: close\r\n"
        for (k, v) in headers {
            out += "\(k): \(v)\r\n"
        }
        out += "\r\n"
        var data = Data(out.utf8)
        data.append(body)
        return data
    }
}

nonisolated private func httpJSON(status: Int, body: Data) -> HTTPResponse {
    HTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: body)
}

nonisolated private func httpPlain(status: Int, body: String) -> HTTPResponse {
    HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: Data(body.utf8))
}

nonisolated private func statusReason(_ code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 404: return "Not Found"
    case 500: return "Internal Server Error"
    case 503: return "Service Unavailable"
    default:  return "Status"
    }
}

// MARK: - HTTP I/O (nonisolated free functions)

private enum HTTPParseError: Error, LocalizedError {
    case incomplete
    case malformedRequestLine
    case bodyTooLarge
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .incomplete:           return "incomplete request"
        case .malformedRequestLine: return "malformed request line"
        case .bodyTooLarge:         return "body too large"
        case .connectionClosed:     return "connection closed before request completed"
        }
    }
}

nonisolated private let maxBodyBytes = 256 * 1024

nonisolated private func readHTTPRequest(connection: NWConnection) async throws -> HTTPRequest {
    var buffer = Data()
    let headerTerminator = Data("\r\n\r\n".utf8)
    while buffer.range(of: headerTerminator) == nil {
        let chunk = try await nwReceive(connection: connection, max: 16 * 1024)
        if chunk.isEmpty { throw HTTPParseError.connectionClosed }
        buffer.append(chunk)
        if buffer.count > maxBodyBytes { throw HTTPParseError.bodyTooLarge }
    }
    guard let split = buffer.range(of: headerTerminator) else {
        throw HTTPParseError.incomplete
    }
    let headerData = buffer.prefix(upTo: split.lowerBound)
    var bodyBuffer = Data(buffer.suffix(from: split.upperBound))

    guard let headerString = String(data: headerData, encoding: .utf8) else {
        throw HTTPParseError.malformedRequestLine
    }
    let lines = headerString.components(separatedBy: "\r\n")
    guard let firstLine = lines.first else { throw HTTPParseError.malformedRequestLine }
    let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard parts.count >= 2 else { throw HTTPParseError.malformedRequestLine }
    let method = String(parts[0]).uppercased()
    let path = String(parts[1])

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        if let colon = line.firstIndex(of: ":") {
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
    }

    let contentLength = Int(headers["content-length"] ?? "0") ?? 0
    if contentLength > maxBodyBytes { throw HTTPParseError.bodyTooLarge }

    while bodyBuffer.count < contentLength {
        let chunk = try await nwReceive(connection: connection, max: 16 * 1024)
        if chunk.isEmpty { throw HTTPParseError.connectionClosed }
        bodyBuffer.append(chunk)
        if bodyBuffer.count > maxBodyBytes { throw HTTPParseError.bodyTooLarge }
    }

    return HTTPRequest(
        method: method,
        path: path,
        headers: headers,
        body: Data(bodyBuffer.prefix(contentLength))
    )
}

nonisolated private func writeHTTPResponse(_ response: HTTPResponse, to connection: NWConnection) async throws {
    let data = response.rendered
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { cont.resume(throwing: error) }
            else { cont.resume(returning: ()) }
        })
    }
}

nonisolated private func nwReceive(connection: NWConnection, max: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: max) { content, _, isComplete, error in
            if let error { cont.resume(throwing: error); return }
            if let content { cont.resume(returning: content); return }
            if isComplete { cont.resume(returning: Data()); return }
            cont.resume(returning: Data())
        }
    }
}

// MARK: - JSON-RPC value model (nonisolated — pure data)

enum JSONRPCID: Codable, Sendable {
    case integer(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .integer(i); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.typeMismatch(
            JSONRPCID.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "JSON-RPC id must be int or string")
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .integer(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

struct JSONRPCEnvelope: Decodable, Sendable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String
    let params: JSONValue?
}

struct JSONRPCError: Encodable, Sendable {
    let code: Int
    let message: String
}

struct JSONRPCResponse: Encodable, Sendable {
    let jsonrpc: String
    let id: JSONRPCID?
    let result: JSONValue?
    let error: JSONRPCError?

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data("{}".utf8)
    }
}

// Codable JSON value, just enough for arg passthrough and result construction.
enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrecognized JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let b):   try c.encode(b)
        case .int(let i):    try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
