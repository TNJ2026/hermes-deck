import Foundation

struct TUIGatewayEventParser: Sendable {
    static func parseEvent(_ line: String) throws -> HermesAgentEvent? {
        let data = Data(line.utf8)
        let frame = try JSONDecoder().decode(TUIGatewayFrame.self, from: data)
        guard frame.method == "event", let params = frame.params else { return nil }

        switch params.type {
        case "gateway.ready":
            return .gatewayReady
        case "session.info":
            return .sessionInfo(
                sessionID: params.sessionID ?? "",
                info: HermesSessionInfo(
                    model: params.payload?.model,
                    contextLength: params.payload?.contextLength,
                    usedTokens: params.payload?.usedTokens,
                    cwd: params.payload?.cwd
                )
            )
        case "message.start":
            return .messageStart(sessionID: params.sessionID ?? "")
        case "message.delta":
            return .messageDelta(sessionID: params.sessionID ?? "", text: params.payload?.text ?? "")
        case "message.complete":
            return .messageComplete(
                sessionID: params.sessionID ?? "",
                text: params.payload?.text ?? "",
                status: params.payload?.status ?? "complete",
                usage: params.payload?.tokenUsage
            )
        case "status.update":
            return .statusUpdate(sessionID: params.sessionID ?? "", text: params.payload?.text ?? "")
        case "tool.start":
            return .toolStart(
                sessionID: params.sessionID ?? "",
                tool: params.payload?.toolEvent(state: .running) ?? ToolCallEvent(name: "tool", state: .running)
            )
        case "tool.generating":
            return .toolGenerating(
                sessionID: params.sessionID ?? "",
                tool: params.payload?.toolEvent(state: .generating) ?? ToolCallEvent(name: "tool", state: .generating)
            )
        case "tool.complete":
            return .toolComplete(
                sessionID: params.sessionID ?? "",
                tool: params.payload?.toolEvent(state: .complete) ?? ToolCallEvent(name: "tool", state: .complete)
            )
        case "thinking.delta":
            return .thinkingDelta(sessionID: params.sessionID ?? "", text: params.payload?.text ?? "")
        case "reasoning.delta":
            return .reasoningDelta(sessionID: params.sessionID ?? "", text: params.payload?.text ?? "")
        case "reasoning.available":
            return .reasoningAvailable(sessionID: params.sessionID ?? "", text: params.payload?.text ?? params.payload?.reasoning ?? "")
        case "approval.request":
            let sessionID = params.sessionID ?? ""
            let requestID = sessionID.isEmpty ? nil : "hermes:\(sessionID)"
            return .approvalRequest(
                sessionID: sessionID,
                requestID: requestID,
                text: params.payload?.approvalText ?? "",
                options: params.payload?.approvalOptions ?? EventPayload.defaultApprovalOptions
            )
        case "clarify.request":
            return .clarifyRequest(sessionID: params.sessionID ?? "", question: params.payload?.question ?? "", choices: params.payload?.choices ?? [])
        case "subagent.spawn_requested":
            return .subagentSpawnRequested(sessionID: params.sessionID ?? "", progress: params.payload?.subagentProgressEvent() ?? .fallback)
        case "subagent.start":
            return .subagentStart(sessionID: params.sessionID ?? "", progress: params.payload?.subagentProgressEvent(defaultStatus: .running) ?? .fallback)
        case "subagent.thinking":
            return .subagentThinking(sessionID: params.sessionID ?? "", progress: params.payload?.subagentProgressEvent() ?? .fallback)
        case "subagent.tool":
            return .subagentTool(sessionID: params.sessionID ?? "", progress: params.payload?.subagentProgressEvent() ?? .fallback)
        case "subagent.progress":
            return .subagentProgress(sessionID: params.sessionID ?? "", progress: params.payload?.subagentProgressEvent() ?? .fallback)
        case "subagent.complete":
            return .subagentComplete(sessionID: params.sessionID ?? "", progress: params.payload?.subagentProgressEvent(defaultStatus: .completed) ?? .fallback)
        case "error":
            return .error(sessionID: params.sessionID, message: params.payload?.message ?? "Unknown Hermes gateway error.")
        default:
            return nil
        }
    }
}

/// A tiny lock-guarded holder so a stream's `onTermination` handler can read a
/// session id that is resolved asynchronously inside the producing task.
private final class SessionIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    nonisolated init() {}
    func set(_ newValue: String) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}

actor HermesTUIGatewayClient: HermesAgentClient {
    private let rpc: TUIGatewayRPCClient
    private var sessionsByConversationID: [UUID: String] = [:]

    init(
        profile: HermesProfile = .defaultProfile,
        executableURL: URL = HermesTUIGatewayClient.defaultExecutableURL(),
        arguments: [String] = ["-m", "tui_gateway.entry"],
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.rpc = TUIGatewayRPCClient(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: HermesTUIGatewayClient.environment(for: profile, executableURL: executableURL, base: environment)
        )
    }

    func send(_ request: HermesChatRequest) async throws -> HermesChatResponse {
        var final = ""
        for try await event in eventStream(for: request) {
            if case .messageComplete(_, let text, _, _) = event {
                final = text
            }
        }
        return HermesChatResponse(content: final)
    }

    nonisolated func eventStream(for request: HermesChatRequest) -> AsyncThrowingStream<HermesAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let rpc = self.rpc
            // Captures the resolved session id so the termination handler can
            // interrupt the right turn (set once `sessionID(for:)` returns).
            let activeSession = SessionIDBox()
            let task = Task {
                do {
                    let sessionID = try await sessionID(for: request)
                    activeSession.set(sessionID)
                    for attachment in request.attachments where attachment.contentType.hasPrefix("image/") {
                        _ = try await rpc.call(
                            method: "image.attach",
                            params: [
                                "session_id": .string(sessionID),
                                "path": .string(attachment.url.path(percentEncoded: false)),
                            ]
                        )
                    }

                    let gatewayEvents = await rpc.eventStream()
                    let eventTask = Task {
                        for await event in gatewayEvents {
                            // Surface errors only through the thrown termination so the
                            // consumer handles them once; yielding the event too would
                            // produce a duplicate error message.
                            if case .error(let eventSessionID, let message) = event, eventSessionID == nil || eventSessionID == sessionID {
                                continuation.finish(throwing: HermesAgentError.rpcError(message))
                                break
                            }
                            if event.belongs(to: sessionID) {
                                continuation.yield(event)
                            }
                            if case .messageComplete(let eventSessionID, _, _, _) = event, eventSessionID == sessionID {
                                continuation.finish()
                                break
                            }
                        }
                    }

                    _ = try await rpc.call(
                        method: "prompt.submit",
                        params: [
                            "session_id": .string(sessionID),
                            "text": .string(promptText(for: request)),
                        ]
                    )
                    await eventTask.value
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // On stop, tell the gateway to interrupt the turn. It then emits a
            // terminal `message.complete`, which lets the in-flight event loop
            // finish cleanly — the turn truly halts instead of running to
            // completion server-side while the UI stops listening.
            continuation.onTermination = { reason in
                // Only a consumer-side cancellation (Stop) should interrupt; a
                // normal `.finished` means the turn already completed.
                if case .cancelled = reason, let sessionID = activeSession.get() {
                    rpc.fireAndForgetNonisolated(
                        method: "session.interrupt",
                        params: ["session_id": .string(sessionID)]
                    )
                }
                task.cancel()
            }
        }
    }

    func commandsCatalog(for profile: HermesProfile) async throws -> [SlashCommand] {
        let result = try await rpc.call(method: "commands.catalog", params: [:])
        guard case .object(let object) = result,
              case .array(let pairs)? = object["pairs"] else { return [] }
        return pairs.compactMap { pair -> SlashCommand? in
            guard case .array(let fields) = pair, fields.count >= 1,
                  case .string(let rawName) = fields[0] else { return nil }
            let name = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
            guard !name.isEmpty else { return nil }
            var desc = ""
            if fields.count >= 2, case .string(let d) = fields[1] { desc = d }
            desc = desc.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return SlashCommand(name: name, subtitle: desc)
        }
    }

    func slashExec(_ command: String, for request: HermesChatRequest) async throws -> String {
        let sessionID = try await sessionID(for: request)
        let result = try await rpc.call(
            method: "slash.exec",
            params: [
                "session_id": .string(sessionID),
                "command": .string(command),
            ]
        )
        if case .object(let object) = result, case .string(let output)? = object["output"] {
            // The gateway formats slash output for a terminal pager (ANSI color
            // codes); strip them so it renders as plain text in the app.
            return output.replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*[A-Za-z]",
                with: "",
                options: .regularExpression
            )
        }
        return ""
    }

    func shutdown() async {
        await rpc.shutdown()
    }

    func respondToPermission(requestID: String, optionID: String) async {
        guard requestID.hasPrefix("hermes:") else { return }
        let sessionID = String(requestID.dropFirst("hermes:".count))
        guard !sessionID.isEmpty else { return }
        let choice = optionID.isEmpty ? "deny" : optionID
        _ = try? await rpc.call(
            method: "approval.respond",
            params: [
                "session_id": .string(sessionID),
                "choice": .string(choice),
            ]
        )
    }

    private func sessionID(for request: HermesChatRequest) async throws -> String {
        if let existing = sessionsByConversationID[request.conversationID] {
            return existing
        }

        // A thread loaded from history carries the original gateway session id;
        // resume it so the conversation continues in place instead of forking a
        // brand-new session. Falls back to create if the session is gone.
        let method: String
        let params: [String: TUIJSONValue]
        if let resume = request.resumeSessionID, !resume.isEmpty {
            method = "session.resume"
            params = ["session_id": .string(resume), "cols": .number(100)]
        } else {
            method = "session.create"
            params = ["cols": .number(100), "title": .string(title(for: request))]
        }

        let sessionID: String
        do {
            sessionID = try await createdSessionID(method: method, params: params)
        } catch {
            // Stale/missing session id (e.g. deleted): start a fresh session
            // rather than failing the prompt outright.
            guard request.resumeSessionID != nil else { throw error }
            sessionID = try await createdSessionID(
                method: "session.create",
                params: ["cols": .number(100), "title": .string(title(for: request))]
            )
        }

        sessionsByConversationID[request.conversationID] = sessionID
        return sessionID
    }

    private func createdSessionID(method: String, params: [String: TUIJSONValue]) async throws -> String {
        let result = try await rpc.call(method: method, params: params)
        guard case .object(let object) = result,
              case .string(let sessionID)? = object["session_id"]
        else {
            throw HermesAgentError.missingSession
        }
        return sessionID
    }

    private nonisolated func promptText(for request: HermesChatRequest) -> String {
        request.promptText
    }

    private nonisolated func title(for request: HermesChatRequest) -> String {
        let fallback = request.messages.last?.content ?? "New Chat"
        return String(fallback.replacingOccurrences(of: "\n", with: " ").prefix(44))
    }

    private nonisolated static func defaultExecutableURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermes/hermes-agent/venv/bin/python")
    }

    nonisolated static func environment(
        for profile: HermesProfile,
        executableURL: URL = HermesTUIGatewayClient.defaultExecutableURL(),
        base: [String: String]
    ) -> [String: String] {
        var environment = base
        let profileID = profile.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        environment["HERMES_PROFILE"] = profileID
        environment["HERMES_HOME"] = hermesHomePath(forProfileID: profileID)
        // Same marker `hermes gateway start` gets (GatewayService): tells the
        // agent its replies are rendered live in the Deck UI, where the
        // `deck-routing` @target-code-block convention works.
        environment["HERMES_DECK"] = "1"
        let executableBin = executableURL.deletingLastPathComponent()
        let venvURL = executableBin.deletingLastPathComponent()
        environment["VIRTUAL_ENV"] = normalizedPath(venvURL)
        environment["PATH"] = path(prepending: executableBin, existing: base["PATH"])
        return environment
    }

    private nonisolated static func path(prepending directory: URL, existing: String?) -> String {
        let fallback = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let directoryPath = normalizedPath(directory)
        let components = [directoryPath] + (existing?.isEmpty == false ? existing! : fallback)
            .split(separator: ":")
            .map(String.init)
        var seen: Set<String> = []
        let deduplicated = components.filter { seen.insert($0).inserted }
        return deduplicated.joined(separator: ":")
    }

    private nonisolated static func normalizedPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard path.count > 1 else { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private nonisolated static func hermesHomePath(forProfileID profileID: String) -> String {
        let hermesRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes")
        guard profileID != "default" else { return hermesRoot.path(percentEncoded: false) }
        return hermesRoot
            .appendingPathComponent("profiles")
            .appendingPathComponent(profileID)
            .path(percentEncoded: false)
    }
}

actor HermesProfileGatewayClient: HermesAgentClient {
    private let makeClient: @Sendable (HermesProfile) -> any HermesAgentClient
    private var clientsByProfileID: [String: any HermesAgentClient] = [:]

    init(makeClient: @escaping @Sendable (HermesProfile) -> any HermesAgentClient = { HermesTUIGatewayClient(profile: $0) }) {
        self.makeClient = makeClient
    }

    func send(_ request: HermesChatRequest) async throws -> HermesChatResponse {
        let client = client(for: request.profile)
        return try await client.send(request)
    }

    func slashExec(_ command: String, for request: HermesChatRequest) async throws -> String {
        try await client(for: request.profile).slashExec(command, for: request)
    }

    func commandsCatalog(for profile: HermesProfile) async throws -> [SlashCommand] {
        try await client(for: profile).commandsCatalog(for: profile)
    }

    func respondToPermission(requestID: String, optionID: String) async {
        guard requestID.hasPrefix("hermes:") else { return }
        let clients = clientsByProfileID.values
        for client in clients {
            await client.respondToPermission(requestID: requestID, optionID: optionID)
        }
    }

    /// Terminates every profile's tui_gateway subprocess. Called on app quit.
    func shutdown() async {
        for client in clientsByProfileID.values {
            await client.shutdown()
        }
    }

    nonisolated func eventStream(for request: HermesChatRequest) -> AsyncThrowingStream<HermesAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let client = await client(for: request.profile)
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

    private func client(for profile: HermesProfile) -> any HermesAgentClient {
        let profileID = profile.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let existing = clientsByProfileID[profileID] {
            return existing
        }
        let client = makeClient(profile)
        clientsByProfileID[profileID] = client
        return client
    }
}

private extension HermesAgentEvent {
    func belongs(to sessionID: String) -> Bool {
        switch self {
        case .gatewayReady:
            false
        case .sessionInfo(let id, _),
             .messageStart(let id),
             .messageDelta(let id, _),
             .messageComplete(let id, _, _, _),
             .statusUpdate(let id, _),
             .toolStart(let id, _),
             .toolGenerating(let id, _),
             .toolComplete(let id, _),
             .thinkingDelta(let id, _),
             .reasoningDelta(let id, _),
             .reasoningAvailable(let id, _),
             .subagentSpawnRequested(let id, _),
             .subagentStart(let id, _),
             .subagentThinking(let id, _),
             .subagentTool(let id, _),
             .subagentProgress(let id, _),
             .subagentComplete(let id, _),
             .approvalRequest(let id, _, _, _),
             .clarifyRequest(let id, _, _):
            id == sessionID
        case .error(let id, _):
            id == nil || id == sessionID
        }
    }
}

private actor TUIGatewayRPCClient {
    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let errorPipe: Pipe
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<TUIJSONValue, Error>] = [:]
    private var eventContinuations: [UUID: AsyncStream<HermesAgentEvent>.Continuation] = [:]
    private var isStarted = false
    private var isReady = false

    init(executableURL: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
        self.process = Process()
        self.process.executableURL = executableURL
        self.process.arguments = arguments
        self.process.currentDirectoryURL = workingDirectory
        self.process.environment = environment

        self.input = Pipe()
        self.output = Pipe()
        self.errorPipe = Pipe()
        self.process.standardInput = input
        self.process.standardOutput = output
        self.process.standardError = errorPipe
    }

    func eventStream() -> AsyncStream<HermesAgentEvent> {
        let id = UUID()
        let stream = AsyncStream.makeStream(of: HermesAgentEvent.self)
        eventContinuations[id] = stream.continuation
        stream.continuation.onTermination = { _ in
            Task { await self.removeEventContinuation(id: id) }
        }
        return stream.stream
    }

    func call(method: String, params: [String: TUIJSONValue]) async throws -> TUIJSONValue {
        try startIfNeeded()
        let id = nextID
        nextID += 1
        let request = TUIJSONRequest(jsonrpc: "2.0", id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            input.fileHandleForWriting.write(data)
            input.fileHandleForWriting.write(Data([0x0A]))
        }
    }

    /// Sends a request without awaiting its response. Used to interrupt a turn
    /// on stop, where the reply is irrelevant and the caller is already winding
    /// down a cancelled task.
    func fireAndForget(method: String, params: [String: TUIJSONValue]) {
        guard (try? startIfNeeded()) != nil else { return }
        let id = nextID
        nextID += 1
        let request = TUIJSONRequest(jsonrpc: "2.0", id: id, method: method, params: params)
        guard let data = try? JSONEncoder().encode(request) else { return }
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data([0x0A]))
    }

    /// Synchronous entry point usable from a non-isolated cancellation handler;
    /// hops onto the actor to perform the write.
    nonisolated func fireAndForgetNonisolated(method: String, params: [String: TUIJSONValue]) {
        Task { await self.fireAndForget(method: method, params: params) }
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func yieldEvent(_ event: HermesAgentEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    /// Graceful teardown on app quit: closing stdin delivers the EOF the
    /// gateway's command loop exits on; SIGTERM covers one blocked mid-dispatch
    /// (the EOF is only seen between requests).
    func shutdown() {
        guard isStarted, process.isRunning else { return }
        input.fileHandleForWriting.closeFile()
        process.terminate()
    }

    private func startIfNeeded() throws {
        guard !isStarted else { return }
        isStarted = true

        output.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consume(data: data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            _ = fileHandle.availableData
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.finishAfterExit() }
        }
        try process.runTranslatingMissingCommand(named: "Hermes")
    }

    private var buffer = Data()

    private func consume(data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            handle(line: line)
        }
    }

    private func handle(line: String) {
        if let event = try? TUIGatewayEventParser.parseEvent(line) {
            if event == .gatewayReady { isReady = true }
            yieldEvent(event)
            return
        }

        guard let data = line.data(using: .utf8),
              let response = try? JSONDecoder().decode(TUIJSONResponse.self, from: data)
        else { return }

        guard let continuation = pending.removeValue(forKey: response.id) else { return }
        if let error = response.error {
            continuation.resume(throwing: HermesAgentError.rpcError(error.message))
        } else {
            continuation.resume(returning: response.result ?? .null)
        }
    }

    private func finishAfterExit() {
        for continuation in pending.values {
            continuation.resume(throwing: HermesAgentError.gatewayExited)
        }
        pending.removeAll()
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }
}

private struct TUIGatewayFrame: Decodable {
    var method: String?
    var params: EventParams?
}

private struct EventParams: Decodable {
    var type: String
    var sessionID: String?
    var payload: EventPayload?

    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "session_id"
        case payload
    }
}

private struct EventPayloadCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

private struct EventPayload: Decodable {
    var text: String?
    var status: String?
    var message: String?
    var model: String?
    var cwd: String?
    var contextLength: Int?
    var usedTokens: Int?
    var toolID: String?
    var name: String?
    var context: String?
    var summary: String?
    var durationSeconds: Double?
    var reasoning: String?
    var question: String?
    var command: String?
    var description: String?
    var choices: [String]?
    var goal: String?
    var subagentID: String?
    var parentID: String?
    var taskIndex: Int?
    var taskCount: Int?
    var depth: Int?
    var toolCount: Int?
    var toolName: String?
    var toolPreview: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?
    var apiCalls: Int?
    var costUSD: Double?
    var filesRead: [String]?
    var filesWritten: [String]?
    var outputTail: [SubagentOutputTailPayload]?

    enum CodingKeys: String, CodingKey {
        case text
        case status
        case message
        case model
        case cwd
        case contextLength = "context_length"
        case usedTokens = "used_tokens"
        case toolID = "tool_id"
        case name
        case context
        case summary
        case durationSeconds = "duration_s"
        case reasoning
        case question
        case command
        case description
        case choices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: EventPayloadCodingKey.self)
        let usage = try container.decodeUsage(for: ["usage", "token_usage", "tokenUsage", "tokens"])
        text = try container.decodeString(for: ["text"])
        status = try container.decodeString(for: ["status"])
        message = try container.decodeString(for: ["message"])
        model = try container.decodeString(for: ["model", "mode"]) ?? usage?.model
        cwd = try container.decodeString(for: ["cwd"])
        contextLength = try container.decodeInt(
            for: ["context_length", "contextLength", "context_window", "contextWindow", "context_max", "contextMax"]
        ) ?? usage?.contextLength
        usedTokens = try container.decodeInt(
            for: ["context_used", "contextUsed", "used_tokens", "usedTokens", "tokens_used", "tokensUsed", "total_tokens", "totalTokens"]
        ) ?? usage?.usedTokens
        toolID = try container.decodeString(for: ["tool_id", "toolID"])
        name = try container.decodeString(for: ["name"])
        context = try container.decodeString(for: ["context"])
        summary = try container.decodeString(for: ["summary"])
        durationSeconds = try container.decodeDouble(for: ["duration_s", "duration_seconds", "durationSeconds"])
        reasoning = try container.decodeString(for: ["reasoning"])
        question = try container.decodeString(for: ["question"])
        command = try container.decodeString(for: ["command"])
        description = try container.decodeString(for: ["description"])
        choices = try container.decodeIfPresent([String].self, forKey: EventPayloadCodingKey(stringValue: "choices"))
        goal = try container.decodeString(for: ["goal"])
        subagentID = try container.decodeString(for: ["subagent_id", "subagentID"])
        parentID = try container.decodeString(for: ["parent_id", "parentID"])
        taskIndex = try container.decodeInt(for: ["task_index", "taskIndex"])
        taskCount = try container.decodeInt(for: ["task_count", "taskCount"])
        depth = try container.decodeInt(for: ["depth"])
        toolCount = try container.decodeInt(for: ["tool_count", "toolCount"])
        toolName = try container.decodeString(for: ["tool_name", "toolName"])
        toolPreview = try container.decodeString(for: ["tool_preview", "toolPreview"])
        inputTokens = try container.decodeInt(for: ["input_tokens", "inputTokens"])
        outputTokens = try container.decodeInt(for: ["output_tokens", "outputTokens"])
        reasoningTokens = try container.decodeInt(for: ["reasoning_tokens", "reasoningTokens"])
        apiCalls = try container.decodeInt(for: ["api_calls", "apiCalls"])
        costUSD = try container.decodeDouble(for: ["cost_usd", "costUSD"])
        filesRead = try container.decodeIfPresent([String].self, forKey: EventPayloadCodingKey(stringValue: "files_read"))
        filesWritten = try container.decodeIfPresent([String].self, forKey: EventPayloadCodingKey(stringValue: "files_written"))
        outputTail = try container.decodeIfPresent([SubagentOutputTailPayload].self, forKey: EventPayloadCodingKey(stringValue: "output_tail"))
    }

    var tokenUsage: HermesTokenUsage? {
        guard contextLength != nil || usedTokens != nil else { return nil }
        return HermesTokenUsage(usedTokens: usedTokens, contextLength: contextLength)
    }

    static let defaultApprovalOptions = [
        PermissionOption(id: "once", label: "Allow once"),
        PermissionOption(id: "session", label: "Allow this session"),
        PermissionOption(id: "always", label: "Always allow"),
        PermissionOption(id: "deny", label: "Deny"),
    ]

    var approvalOptions: [PermissionOption] {
        guard let choices, !choices.isEmpty else { return Self.defaultApprovalOptions }
        let options: [PermissionOption] = choices.compactMap { choice in
            let value = choice.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return PermissionOption(id: value, label: value)
        }
        return options.isEmpty ? Self.defaultApprovalOptions : options
    }

    var approvalText: String {
        let explicitText = (text ?? message ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitText.isEmpty { return explicitText }

        let desc = (description ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cmd = (command ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch (desc.isEmpty, cmd.isEmpty) {
        case (false, false):
            return "\(desc)\n\nCommand:\n\(cmd)"
        case (false, true):
            return desc
        case (true, false):
            return "Command:\n\(cmd)"
        case (true, true):
            return ""
        }
    }

    func toolEvent(state: ToolCallState) -> ToolCallEvent {
        ToolCallEvent(
            toolID: toolID,
            name: name ?? "tool",
            state: state,
            context: context,
            summary: summary ?? text ?? message,
            durationSeconds: durationSeconds
        )
    }

    func subagentProgressEvent(defaultStatus: SubagentStatus? = nil) -> SubagentProgressEvent {
        let index = taskIndex ?? 0
        let goalText = text ?? message ?? ""
        let id = subagentID ?? "sa:\(index):\(goal ?? goalText)"
        return SubagentProgressEvent(
            id: id,
            parentID: parentID,
            taskIndex: index,
            taskCount: max(1, taskCount ?? 1),
            depth: max(0, depth ?? 0),
            goal: goal ?? "",
            status: status == nil ? defaultStatus : SubagentStatus(status),
            model: model,
            toolName: toolName ?? name,
            text: toolPreview ?? text ?? message,
            summary: summary,
            durationSeconds: durationSeconds,
            toolCount: toolCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            apiCalls: apiCalls,
            costUSD: costUSD,
            filesRead: filesRead ?? [],
            filesWritten: filesWritten ?? [],
            outputTail: (outputTail ?? []).map(\.item)
        )
    }
}

private extension SubagentProgressEvent {
    static var fallback: SubagentProgressEvent {
        SubagentProgressEvent(
            id: "sa:0:subagent",
            parentID: nil,
            taskIndex: 0,
            taskCount: 1,
            depth: 0,
            goal: "",
            status: nil,
            model: nil,
            toolName: nil,
            text: nil,
            summary: nil,
            durationSeconds: nil,
            toolCount: nil,
            inputTokens: nil,
            outputTokens: nil,
            reasoningTokens: nil,
            apiCalls: nil,
            costUSD: nil,
            filesRead: [],
            filesWritten: [],
            outputTail: []
        )
    }
}

private struct SubagentOutputTailPayload: Decodable {
    var tool: String?
    var preview: String?
    var isError: Bool?

    enum CodingKeys: String, CodingKey {
        case tool
        case preview
        case isError = "is_error"
    }

    var item: SubagentOutputTailItem {
        SubagentOutputTailItem(tool: tool ?? "tool", preview: preview ?? "", isError: isError ?? false)
    }
}

private struct EventTokenUsagePayload: Decodable {
    var model: String?
    var contextLength: Int?
    var usedTokens: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: EventPayloadCodingKey.self)
        model = try container.decodeString(for: ["model", "mode"])
        contextLength = try container.decodeInt(
            for: ["context_max", "contextMax", "context_length", "contextLength", "context_window", "contextWindow"]
        )

        let explicitUsed = try container.decodeInt(
            for: ["context_used", "contextUsed", "used_tokens", "usedTokens", "tokens_used", "tokensUsed", "total_tokens", "totalTokens", "total"]
        )
        let inputTokens = try container.decodeInt(for: ["input_tokens", "inputTokens", "input", "prompt_tokens", "promptTokens", "prompt"])
        let outputTokens = try container.decodeInt(for: ["output_tokens", "outputTokens", "output", "completion_tokens", "completionTokens", "completion"])
        if let explicitUsed {
            usedTokens = explicitUsed
        } else if inputTokens != nil || outputTokens != nil {
            usedTokens = (inputTokens ?? 0) + (outputTokens ?? 0)
        } else {
            usedTokens = nil
        }
    }
}

private extension KeyedDecodingContainer where K == EventPayloadCodingKey {
    func decodeUsage(for keys: [String]) throws -> EventTokenUsagePayload? {
        for key in keys {
            if let value = try decodeIfPresent(EventTokenUsagePayload.self, forKey: K(stringValue: key)) {
                return value
            }
        }
        return nil
    }

    func decodeString(for keys: [String]) throws -> String? {
        for key in keys {
            if let value = try decodeIfPresent(String.self, forKey: K(stringValue: key)) {
                return value
            }
        }
        return nil
    }

    func decodeInt(for keys: [String]) throws -> Int? {
        for key in keys {
            let codingKey = K(stringValue: key)
            if let value = try decodeIfPresent(Int.self, forKey: codingKey) {
                return value
            }
            if let value = try decodeIfPresent(Double.self, forKey: codingKey) {
                return Int(value)
            }
            if let value = try decodeIfPresent(String.self, forKey: codingKey), let intValue = Int(value) {
                return intValue
            }
        }
        return nil
    }

    func decodeDouble(for keys: [String]) throws -> Double? {
        for key in keys {
            let codingKey = K(stringValue: key)
            if let value = try decodeIfPresent(Double.self, forKey: codingKey) {
                return value
            }
            if let value = try decodeIfPresent(Int.self, forKey: codingKey) {
                return Double(value)
            }
            if let value = try decodeIfPresent(String.self, forKey: codingKey), let doubleValue = Double(value) {
                return doubleValue
            }
        }
        return nil
    }
}

private struct TUIJSONRequest: Encodable {
    var jsonrpc: String
    var id: Int
    var method: String
    var params: [String: TUIJSONValue]
}

private struct TUIJSONResponse: Decodable {
    var id: Int
    var result: TUIJSONValue?
    var error: TUIJSONError?
}

private struct TUIJSONError: Decodable {
    var message: String
}

nonisolated enum TUIJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: TUIJSONValue])
    case array([TUIJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: TUIJSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([TUIJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}
