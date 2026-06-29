import Foundation
import Network

/// Minimal Streamable-HTTP MCP server hosted in-process, exposing a single
/// `deck_reply` tool. Lets the panel CLIs (claude / codex / gemini — all of
/// which speak streamable-HTTP MCP) discover and call the tool natively, so the
/// reply convention need not be pasted into the terminal. PoC scope: one tool,
/// `application/json` responses (no SSE stream), bearer-token auth.
final class DeckMCPServer: @unchecked Sendable {
    static let shared = DeckMCPServer()

    /// Returns a user-facing result string for a `deck_reply` call.
    typealias ToolHandler = @Sendable (_ message: String) async -> String

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "deck-mcp-http")
    nonisolated(unsafe) private var listener: NWListener?
    nonisolated(unsafe) private var port: UInt16?
    nonisolated(unsafe) private var handler: ToolHandler?
    let token = UUID().uuidString

    private init() {}

    func start(toolHandler: @escaping ToolHandler) throws {
        lock.lock()
        handler = toolHandler
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

    nonisolated func endpointURL(waitingUpTo timeout: TimeInterval = 2) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            lock.lock(); let p = port; lock.unlock()
            if let p { return "http://127.0.0.1:\(p)/mcp" }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return nil
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
                    self.receive(connection, buffer: data) // need the rest of the body
                }
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: data)
        }
    }

    /// Splits HTTP request into (header lines, body, bodyComplete). Returns nil
    /// until the header block has fully arrived.
    private static func parseRequest(_ data: Data) -> (headers: [String], body: Data, complete: Bool)? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<separator.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let headers = headerText.components(separatedBy: "\r\n")
        let contentLength = headers
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        let body = data[separator.upperBound...]
        return (headers, Data(body), body.count >= contentLength)
    }

    private func respond(headers: [String], body: Data, on connection: NWConnection) {
        lock.lock(); let expected = token; let handler = self.handler; lock.unlock()

        let authorized = headers.contains {
            let line = $0.lowercased()
            return line.hasPrefix("authorization:") && line.contains("bearer \(expected.lowercased())")
        }
        guard authorized else {
            sendHTTP(status: "401 Unauthorized", json: nil, on: connection)
            return
        }
        guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            sendHTTP(status: "400 Bad Request", json: nil, on: connection)
            return
        }
        let method = request["method"] as? String ?? ""
        let id = request["id"]

        // Notifications (no id) get an empty 202.
        guard id != nil else {
            sendHTTP(status: "202 Accepted", json: nil, on: connection)
            return
        }

        switch method {
        case "initialize":
            reply(id: id, result: [
                "protocolVersion": (request["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "hermes-deck", "version": "0.1.0"],
            ], on: connection)
        case "tools/list":
            reply(id: id, result: ["tools": [Self.deckReplyToolSchema]], on: connection)
        case "tools/call":
            handleToolCall(request, id: id, handler: handler, on: connection)
        default:
            reply(id: id, error: "Method not found: \(method)", code: -32601, on: connection)
        }
    }

    private func handleToolCall(_ request: [String: Any], id: Any?, handler: ToolHandler?, on connection: NWConnection) {
        let params = request["params"] as? [String: Any]
        let name = params?["name"] as? String ?? ""
        let arguments = params?["arguments"] as? [String: Any] ?? [:]
        guard name == "deck_reply" else {
            reply(id: id, error: "Unknown tool: \(name)", code: -32602, on: connection)
            return
        }
        let message = (arguments["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            reply(id: id, result: Self.toolResult("message is required", isError: true), on: connection)
            return
        }
        Task {
            let text = await handler?(message) ?? "Hermes Deck is not handling replies right now."
            self.reply(id: id, result: Self.toolResult(text, isError: false), on: connection)
        }
    }

    private static let deckReplyToolSchema: [String: Any] = [
        "name": "deck_reply",
        "description": "Return your final result to the Hermes Deck teammate who delegated this task to you.",
        "inputSchema": [
            "type": "object",
            "properties": ["message": ["type": "string", "description": "The result to return."]],
            "required": ["message"],
        ],
    ]

    private static func toolResult(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    // MARK: - JSON-RPC replies

    private func reply(id: Any?, result: [String: Any], on connection: NWConnection) {
        sendHTTP(status: "200 OK", json: ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result], on: connection)
    }

    private func reply(id: Any?, error: String, code: Int, on connection: NWConnection) {
        sendHTTP(status: "200 OK", json: ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": error]], on: connection)
    }

    private func sendHTTP(status: String, json: [String: Any]?, on connection: NWConnection) {
        var body = Data()
        if let json {
            body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        }
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var data = Data(response.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
