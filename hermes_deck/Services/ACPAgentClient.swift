import Foundation

/// Runs `operation`, throwing a friendly timeout error if it doesn't finish
/// within `duration`. Used to bound the ACP handshake (initialize / session/new)
/// so a stuck or missing adapter surfaces an error instead of hanging the UI
/// forever. The prompt itself is intentionally not bounded — turns run long.
private func acpCallWithTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw HermesAgentError.rpcError(
                "The agent didn't respond within \(Int(duration.components.seconds))s while starting up. It may not be installed or is stuck."
            )
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Drives an external coding agent over ACP and adapts it to the app's
/// `HermesAgentClient` boundary, so the existing chat store and views render an
/// ACP session exactly like a Hermes one.
actor ACPAgentClient: HermesAgentClient {
    private let agent: ACPAgent
    private let connection: ACPConnection
    private struct PendingPermission {
        var id: TUIJSONValue
        var sessionID: String
    }
    /// The single in-flight (or completed) `initialize` call. Sharing one task
    /// stops a warm-up and a first prompt from initializing the adapter twice.
    private var initTask: Task<Void, Error>?
    private var sessionsByConversationID: [UUID: String] = [:]
    /// ACP request ids for in-flight permission prompts, keyed by the token we
    /// hand to the UI via the `.approvalRequest` event.
    private var pendingPermissions: [String: PendingPermission] = [:]
    /// One long-lived task drains `connection.inbound`; re-iterating the stream
    /// per turn would silently yield nothing on the second turn.
    private var pumpStarted = false
    /// The stream continuation for each live turn, keyed by ACP session id, so
    /// the pump can route notifications to the right turn.
    private var activeTurns: [String: AsyncThrowingStream<HermesAgentEvent, Error>.Continuation] = [:]

    init(agent: ACPAgent, connection: ACPConnection? = nil) {
        self.agent = agent
        self.connection = connection ?? ACPConnection(spec: agent.launchSpec())
    }

    func send(_ request: HermesChatRequest) async throws -> HermesChatResponse {
        var final = ""
        for try await event in eventStream(for: request) {
            switch event {
            case .messageDelta(_, let text): final += text
            case .messageComplete(_, let text, _, _) where !text.isEmpty: final = text
            default: break
            }
        }
        return HermesChatResponse(content: final)
    }

    nonisolated func eventStream(for request: HermesChatRequest) -> AsyncThrowingStream<HermesAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var registeredSession: String?
                do {
                    await startPumpIfNeeded()
                    let sessionID = try await prepareSession(for: request)
                    registeredSession = sessionID
                    await register(continuation, for: sessionID)
                    let result = try await connection.call(
                        method: "session/prompt",
                        params: promptParams(sessionID: sessionID, request: request)
                    )
                    let stop = result["stopReason"]?.stringValue ?? "end_turn"
                    continuation.yield(.messageComplete(
                        sessionID: sessionID,
                        text: "",
                        status: stop == "end_turn" ? "complete" : stop,
                        usage: nil
                    ))
                    continuation.finish()
                } catch is CancellationError {
                    // Tell the agent to actually abort the turn, not just detach
                    // the UI — otherwise codex keeps running tools server-side.
                    if let registeredSession {
                        await connection.notify(
                            method: "session/cancel",
                            params: .object(["sessionId": .string(registeredSession)])
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                if let registeredSession {
                    await unregister(sessionID: registeredSession)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Inbound pump

    private func startPumpIfNeeded() {
        guard !pumpStarted else { return }
        pumpStarted = true
        let inbound = connection.inbound
        Task { [weak self] in
            for await item in inbound {
                await self?.dispatch(item)
            }
        }
    }

    private func register(_ continuation: AsyncThrowingStream<HermesAgentEvent, Error>.Continuation, for sessionID: String) {
        activeTurns[sessionID] = continuation
    }

    private func unregister(sessionID: String) {
        activeTurns[sessionID] = nil
        pendingPermissions = pendingPermissions.filter { $0.value.sessionID != sessionID }
    }

    private func dispatch(_ item: ACPInbound) async {
        switch item {
        case .notification(let method, let params):
            guard method == "session/update",
                  let sessionID = params["sessionId"]?.stringValue,
                  let continuation = activeTurns[sessionID],
                  let update = params["update"]?.objectValue else { return }
            for event in ACPEventMapper.events(update: update, sessionID: sessionID) {
                continuation.yield(event)
            }
        case .request(let id, let method, let params):
            guard method == "session/request_permission",
                  let sessionID = params["sessionId"]?.stringValue,
                  let continuation = activeTurns[sessionID] else {
                // fs/* and terminal/* are advertised unsupported; decline cleanly.
                await connection.respond(id: id, errorCode: -32601, message: "Method not supported")
                return
            }
            let requestID = "acp:\(agent.rawValue):\(UUID().uuidString)"
            pendingPermissions[requestID] = PendingPermission(id: id, sessionID: sessionID)
            continuation.yield(.approvalRequest(
                sessionID: sessionID,
                requestID: requestID,
                text: ACPEventMapper.permissionText(params),
                options: ACPEventMapper.permissionOptions(params)
            ))
        }
    }

    func respondToPermission(requestID: String, optionID: String) async {
        guard let pending = pendingPermissions.removeValue(forKey: requestID) else { return }
        let outcome: TUIJSONValue = optionID.isEmpty
            ? .object(["outcome": .string("cancelled")])
            : .object(["outcome": .string("selected"), "optionId": .string(optionID)])
        await connection.respond(id: pending.id, result: outcome)
    }

    /// Spawns the adapter and runs `initialize` ahead of the first prompt so the
    /// startup cost (npx + node + SDK boot) overlaps with the user typing.
    func warmUp() async {
        try? await ensureInitialized()
    }

    /// Terminates the adapter process tree (called on app quit).
    func shutdown() async {
        await connection.shutdown()
    }

    // MARK: - Session

    private func ensureInitialized() async throws {
        if let initTask {
            try await initTask.value
            return
        }
        let task = Task { [connection] in
            try await acpCallWithTimeout(.seconds(30)) {
                _ = try await connection.call(method: "initialize", params: .object([
                    "protocolVersion": .number(1),
                    "clientCapabilities": .object([
                        "fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]),
                        "terminal": .bool(false),
                    ]),
                ]))
            }
        }
        initTask = task
        do {
            try await task.value
        } catch {
            initTask = nil  // allow a later retry after a failed boot
            throw error
        }
    }

    private func prepareSession(for request: HermesChatRequest) async throws -> String {
        try await ensureInitialized()
        if let existing = sessionsByConversationID[request.conversationID] {
            return existing
        }
        let cwd = request.workingDirectory.path(percentEncoded: false)
        let connection = connection
        let result = try await acpCallWithTimeout(.seconds(30)) {
            try await connection.call(method: "session/new", params: .object([
                "cwd": .string(cwd),
                "mcpServers": .array([]),
            ]))
        }
        guard let sessionID = result["sessionId"]?.stringValue else {
            throw HermesAgentError.missingSession
        }
        sessionsByConversationID[request.conversationID] = sessionID
        return sessionID
    }

    private nonisolated func promptParams(sessionID: String, request: HermesChatRequest) -> TUIJSONValue {
        var blocks: [TUIJSONValue] = request.attachments.map { attachment in
            .object([
                "type": .string("resource_link"),
                "uri": .string(attachment.url.absoluteString),
                "name": .string(attachment.name),
            ])
        }
        blocks.append(.object(["type": .string("text"), "text": .string(request.promptText)]))
        return .object(["sessionId": .string(sessionID), "prompt": .array(blocks)])
    }

}

/// Pure mapping from ACP `session/update` payloads (and permission requests) to
/// the app's `HermesAgentEvent` / `PermissionOption` types. Kept free of actor
/// state so it can be unit-tested directly.
enum ACPEventMapper {
    static func events(update: [String: TUIJSONValue], sessionID: String) -> [HermesAgentEvent] {
        switch update["sessionUpdate"]?.stringValue {
        case "agent_message_chunk":
            guard let text = update["content"]?["text"]?.stringValue, !text.isEmpty else { return [] }
            return [.messageDelta(sessionID: sessionID, text: text)]
        case "agent_thought_chunk":
            guard let text = update["content"]?["text"]?.stringValue, !text.isEmpty else { return [] }
            return [.thinkingDelta(sessionID: sessionID, text: text)]
        case "tool_call":
            return [.toolStart(sessionID: sessionID, tool: toolEvent(update, state: .running))]
        case "tool_call_update":
            let status = update["status"]?.stringValue
            if status == "completed" || status == "failed" {
                return [.toolComplete(sessionID: sessionID, tool: toolEvent(update, state: .complete))]
            }
            return [.toolGenerating(sessionID: sessionID, tool: toolEvent(update, state: .generating))]
        default:
            return []
        }
    }

    static func permissionOptions(_ params: TUIJSONValue) -> [PermissionOption] {
        (params["options"]?.arrayValue ?? []).compactMap { option in
            guard let optionID = option["optionId"]?.stringValue, !optionID.isEmpty else { return nil }
            return PermissionOption(id: optionID, label: option["name"]?.stringValue ?? optionID)
        }
    }

    static func permissionText(_ params: TUIJSONValue) -> String {
        params["toolCall"]?["title"]?.stringValue.map { "Allow \($0)?" } ?? "Permission requested."
    }

    private static func toolEvent(_ update: [String: TUIJSONValue], state: ToolCallState) -> ToolCallEvent {
        let metaName = update["_meta"]?["claudeCode"]?["toolName"]?.stringValue
        let title = update["title"]?.stringValue
        return ToolCallEvent(
            toolID: update["toolCallId"]?.stringValue,
            name: metaName ?? title ?? "tool",
            state: state,
            context: title,
            summary: contentText(update) ?? update["rawOutput"]?.stringValue
        )
    }

    private static func contentText(_ update: [String: TUIJSONValue]) -> String? {
        guard let items = update["content"]?.arrayValue else { return nil }
        let joined = items
            .compactMap { $0["content"]?["text"]?.stringValue ?? $0["text"]?.stringValue }
            .joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }
}

/// Routes each request to the right backend: the local Hermes gateway by
/// default, or a per-agent `ACPAgentClient` for `.acp` requests.
actor RoutingAgentClient: HermesAgentClient {
    private let hermes: any HermesAgentClient
    private let agy: any HermesAgentClient
    private let claudeCLI: any HermesAgentClient
    private var acpClients: [ACPAgent: ACPAgentClient] = [:]

    // Dependencies are injected (no default arguments): the backing clients are
    // main-actor-isolated actors under the project's default isolation, and
    // default arguments evaluate in a nonisolated context. App.init constructs
    // them on the main actor instead.
    init(
        hermes: any HermesAgentClient,
        agy: any HermesAgentClient,
        claudeCLI: any HermesAgentClient
    ) {
        self.hermes = hermes
        self.agy = agy
        self.claudeCLI = claudeCLI
    }

    private func client(for agent: ACPAgent) -> ACPAgentClient {
        if let existing = acpClients[agent] { return existing }
        let client = ACPAgentClient(agent: agent)
        acpClients[agent] = client
        return client
    }

    func send(_ request: HermesChatRequest) async throws -> HermesChatResponse {
        switch request.backend {
        case .hermes:
            return try await hermes.send(request)
        case .agy:
            return try await agy.send(request)
        case .claudeCLI:
            return try await claudeCLI.send(request)
        case .acp(let agent):
            return try await client(for: agent).send(request)
        }
    }

    func slashExec(_ command: String, for request: HermesChatRequest) async throws -> String {
        // Slash commands are a Hermes gateway feature.
        try await hermes.slashExec(command, for: request)
    }

    func commandsCatalog(for profile: HermesProfile) async throws -> [SlashCommand] {
        try await hermes.commandsCatalog(for: profile)
    }

    nonisolated func eventStream(for request: HermesChatRequest) -> AsyncThrowingStream<HermesAgentEvent, Error> {
        switch request.backend {
        case .hermes:
            return hermes.eventStream(for: request)
        case .agy:
            return agy.eventStream(for: request)
        case .claudeCLI:
            return claudeCLI.eventStream(for: request)
        case .acp(let agent):
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let client = await client(for: agent)
                        for try await event in client.eventStream(for: request) {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    func respondToPermission(requestID: String, optionID: String) async {
        if requestID.hasPrefix("hermes:") {
            await hermes.respondToPermission(requestID: requestID, optionID: optionID)
            return
        }

        // requestID format: "acp:<agent>:<uuid>".
        let parts = requestID.split(separator: ":")
        guard parts.count >= 2, let agent = ACPAgent(rawValue: String(parts[1])) else { return }
        await client(for: agent).respondToPermission(requestID: requestID, optionID: optionID)
    }

    func warmUp(backend: AgentBackend) async {
        guard case .acp(let agent) = backend else { return }
        await client(for: agent).warmUp()
    }

    /// Terminates every spawned ACP adapter process tree and the per-profile
    /// tui_gateway subprocesses. Called on app quit.
    func shutdown() async {
        for client in acpClients.values {
            await client.shutdown()
        }
        await hermes.shutdown()
    }
}
