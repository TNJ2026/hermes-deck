import Foundation
import Network

/// In-process Streamable-HTTP MCP server exposing the Deck agent bus tools.
/// Panel CLIs get per-panel bearer tokens so `deck_reply` can be attributed to
/// the panel that is replying. Hermes gateway processes get a Deck bearer token
/// through their environment so `deck_delegate_prompt` can enqueue hand-offs.
final class DeckMCPServer: @unchecked Sendable {
    static let shared = DeckMCPServer()

    /// Closes the loop for a panel reply. Returns a short status string shown to
    /// the calling agent.
    typealias ReplyHandler = @Sendable (_ panelSession: String, _ message: String) async -> String
    typealias DelegateHandler = @Sendable (_ request: DeckMCPDelegateRequest) async -> DeckMCPDelegateResponse

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "deck-mcp-http")
    nonisolated(unsafe) private var listener: NWListener?
    nonisolated(unsafe) private var port: UInt16?
    nonisolated(unsafe) private var replyHandler: ReplyHandler?
    nonisolated(unsafe) private var delegateHandler: DelegateHandler?
    nonisolated(unsafe) private var gatewayToken = UUID().uuidString
    nonisolated(unsafe) private var sessionForToken: [String: String] = [:]
    nonisolated(unsafe) private var tokenForSession: [String: String] = [:]

    private init() {}

    func start(
        replyHandler: @escaping ReplyHandler,
        delegateHandler: DelegateHandler? = nil
    ) throws {
        lock.lock()
        self.replyHandler = replyHandler
        self.delegateHandler = delegateHandler
        let already = listener != nil
        lock.unlock()
        guard !already else { return }

        let listener = try NWListener(using: .tcp, on: 0)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let port = listener.port else { return }
            self?.lock.lock(); self?.port = port.rawValue; self?.lock.unlock()
        }
        listener.start(queue: queue)
        lock.lock(); self.listener = listener; lock.unlock()
    }

    /// A stable bearer token for `panelSession`, minted on first use. The panel
    /// hands this to its CLI's MCP config so the tool call is attributable.
    func token(forSession panelSession: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = tokenForSession[panelSession] { return existing }
        let token = UUID().uuidString
        tokenForSession[panelSession] = token
        sessionForToken[token] = panelSession
        return token
    }

    nonisolated func endpointURL(waitingUpTo timeout: TimeInterval = 2) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            lock.lock(); let p = port; lock.unlock()
            if let p { return "http://127.0.0.1:\(p)/mcp" }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return nil
    }

    nonisolated func environmentVariablesBlocking(waitingUpTo timeout: TimeInterval) -> [String: String] {
        guard let url = endpointURL(waitingUpTo: timeout) else { return [:] }
        return gatewayEnvironment(url: url)
    }

    /// Async variant — waits with `Task.sleep` rather than blocking the calling
    /// thread, so it is safe to await without freezing the main actor.
    nonisolated func environmentVariables(waitingUpTo timeout: TimeInterval) async -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let p = port; lock.unlock()
            if let p { return gatewayEnvironment(url: "http://127.0.0.1:\(p)/mcp") }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        lock.lock(); let p = port; lock.unlock()
        guard let p else { return [:] }
        return gatewayEnvironment(url: "http://127.0.0.1:\(p)/mcp")
    }

    private nonisolated func gatewayEnvironment(url: String) -> [String: String] {
        lock.lock()
        let token = gatewayToken
        lock.unlock()
        return ["HERMES_DECK_MCP_URL": url, "HERMES_DECK_MCP_TOKEN": token]
    }

    // MARK: - HTTP

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var data = buffer
            if let chunk { data.append(chunk) }
            if let (headers, body, complete) = Self.parseRequest(data) {
                if complete {
                    self.respond(headers: headers, body: body, on: connection)
                } else {
                    self.receive(connection, buffer: data)
                }
                return
            }
            if isComplete || error != nil { connection.cancel(); return }
            self.receive(connection, buffer: data)
        }
    }

    private static func parseRequest(_ data: Data) -> (headers: [String], body: Data, complete: Bool)? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: data[..<separator.lowerBound], as: UTF8.self)
        let headers = headerText.components(separatedBy: "\r\n")
        let contentLength = headers
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        let body = data[separator.upperBound...]
        return (headers, Data(body), body.count >= contentLength)
    }

    private func respond(headers: [String], body: Data, on connection: NWConnection) {
        let bearer = Self.bearerToken(in: headers)
        lock.lock()
        let session = bearer.flatMap { sessionForToken[$0] }
        let isGatewayToken = bearer == gatewayToken
        let replyHandler = self.replyHandler
        let delegateHandler = self.delegateHandler
        lock.unlock()

        guard session != nil || isGatewayToken else {
            sendHTTP(status: "401 Unauthorized", json: nil, on: connection)
            return
        }
        guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            sendHTTP(status: "400 Bad Request", json: nil, on: connection)
            return
        }
        let method = request["method"] as? String ?? ""
        let id = request["id"]
        guard id != nil else {
            sendHTTP(status: "202 Accepted", json: nil, on: connection) // notification
            return
        }

        // A gateway agent (delegation source) and a panel CLI (reply target) get
        // different tokens and different tools. Keep them apart: a panel token
        // must not be able to enqueue delegations as a Hermes source.
        switch method {
        case "initialize":
            reply(id: id, result: [
                "protocolVersion": (request["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "hermes-deck", "version": "0.1.0"],
            ], on: connection)
        case "tools/list":
            let tools = isGatewayToken ? [Self.deckDelegatePromptToolSchema] : [Self.deckReplyToolSchema]
            reply(id: id, result: ["tools": tools], on: connection)
        case "tools/call":
            handleToolCall(
                request,
                id: id,
                isGateway: isGatewayToken,
                session: session ?? "",
                replyHandler: replyHandler,
                delegateHandler: delegateHandler,
                on: connection
            )
        default:
            reply(id: id, error: "Method not found: \(method)", code: -32601, on: connection)
        }
    }

    private static func bearerToken(in headers: [String]) -> String? {
        guard let line = headers.first(where: { $0.lowercased().hasPrefix("authorization:") }) else { return nil }
        let value = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
        guard value.lowercased().hasPrefix("bearer ") else { return nil }
        return String(value.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
    }

    private func handleToolCall(
        _ request: [String: Any],
        id: Any?,
        isGateway: Bool,
        session: String,
        replyHandler: ReplyHandler?,
        delegateHandler: DelegateHandler?,
        on connection: NWConnection
    ) {
        let params = request["params"] as? [String: Any]
        let name = params?["name"] as? String ?? ""
        let arguments = params?["arguments"] as? [String: Any] ?? [:]

        // Panel tokens may only reply; gateway tokens may only delegate.
        switch (name, isGateway) {
        case ("deck_reply", false):
            handleDeckReply(arguments: arguments, id: id, session: session, handler: replyHandler, on: connection)
        case ("deck_delegate_prompt", true):
            handleDeckDelegatePrompt(arguments: arguments, id: id, handler: delegateHandler, on: connection)
        default:
            reply(id: id, error: "Tool \(name) is not available for this client", code: -32601, on: connection)
        }
    }

    private func handleDeckReply(
        arguments: [String: Any],
        id: Any?,
        session: String,
        handler: ReplyHandler?,
        on connection: NWConnection
    ) {
        let message = (arguments["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            reply(id: id, result: Self.toolResult("message is required", isError: true), on: connection)
            return
        }
        Task {
            let text = await handler?(session, message) ?? "Hermes Deck is not handling replies right now."
            self.reply(id: id, result: Self.toolResult(text, isError: false), on: connection)
        }
    }

    private func handleDeckDelegatePrompt(
        arguments: [String: Any],
        id: Any?,
        handler: DelegateHandler?,
        on connection: NWConnection
    ) {
        var target = (arguments["target"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if target.hasPrefix("@") { target.removeFirst() }
        let prompt = (arguments["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            reply(id: id, result: Self.toolResult("target is required", isError: true), on: connection)
            return
        }
        guard !prompt.isEmpty else {
            reply(id: id, result: Self.toolResult("prompt is required", isError: true), on: connection)
            return
        }

        let request = DeckMCPDelegateRequest(
            target: target,
            prompt: prompt,
            wait: arguments["wait"] as? Bool,
            sourceSessionKey: (arguments["source_session_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceProfileID: (arguments["source_profile_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        Task {
            let response = await handler?(request)
                ?? DeckMCPDelegateResponse(ok: false, status: nil, error: "Hermes Deck is not handling delegations right now.", fallback: true)
            let text = response.jsonString
            self.reply(id: id, result: Self.toolResult(text, isError: !response.ok), on: connection)
        }
    }

    private static let deckDelegatePromptToolSchema: [String: Any] = [
        "name": "deck_delegate_prompt",
        "description": "Delegate a focused prompt to another Hermes Deck agent/profile or external panel. Returns queued/sent status; replies arrive asynchronously through deck_reply.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "target": ["type": "string", "description": "Deck target alias without @, such as default, coding, claude, codex, or gemini."],
                "prompt": ["type": "string", "description": "Self-contained prompt to send to the target agent."],
                "wait": ["type": "boolean", "description": "Reserved for synchronous waiting; currently handled as async."],
                "source_session_key": ["type": "string", "description": "Hermes source session/task key, supplied by the Deck plugin."],
                "source_profile_id": ["type": "string", "description": "Hermes source profile id, supplied by the Deck plugin."],
            ],
            "required": ["target", "prompt"],
        ],
    ]

    private static let deckReplyToolSchema: [String: Any] = [
        "name": "deck_reply",
        "description": "Return your final result to the Hermes Deck teammate who delegated this task to you. Call this once, when you are done.",
        "inputSchema": [
            "type": "object",
            "properties": ["message": ["type": "string", "description": "The result to return to the requesting agent."]],
            "required": ["message"],
        ],
    ]

    private static func toolResult(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    // MARK: - JSON-RPC

    private func reply(id: Any?, result: [String: Any], on connection: NWConnection) {
        sendHTTP(status: "200 OK", json: ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result], on: connection)
    }

    private func reply(id: Any?, error: String, code: Int, on connection: NWConnection) {
        sendHTTP(status: "200 OK", json: ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": error]], on: connection)
    }

    private func sendHTTP(status: String, json: [String: Any]?, on connection: NWConnection) {
        var body = Data()
        if let json { body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data() }
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var data = Data(response.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

struct DeckMCPDelegateRequest: Sendable {
    var target: String
    var prompt: String
    var wait: Bool?
    var sourceSessionKey: String?
    var sourceProfileID: String?
}

struct DeckMCPDelegateResponse: Sendable {
    var ok: Bool
    var status: String?
    var error: String?
    /// True when the failure is the Deck MCP side being unavailable (handler not
    /// wired, app shutting down) rather than a validation error — the plugin
    /// then retries over the legacy TCP IPC. Validation failures leave this
    /// false: IPC routes through the same path and would fail identically.
    var fallback: Bool = false

    var jsonString: String {
        var payload: [String: Any] = ["ok": ok]
        if let status { payload["status"] = status }
        if let error { payload["error"] = error }
        if fallback { payload["fallback"] = true }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":"Failed to encode Deck MCP response"}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
