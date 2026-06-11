import Foundation

/// A frame arriving from the ACP agent that is not a response to one of our
/// calls: either a notification (no id) or a server→client request (has id and
/// must be answered with `respond`).
enum ACPInbound: Sendable {
    case notification(method: String, params: TUIJSONValue)
    case request(id: TUIJSONValue, method: String, params: TUIJSONValue)
}

/// Bidirectional newline-delimited JSON-RPC 2.0 transport over a child
/// process's stdio. Mirrors `TUIGatewayRPCClient` but additionally surfaces
/// server→client requests so the client can answer them (ACP needs this for
/// `session/request_permission`).
actor ACPConnection {
    let inbound: AsyncStream<ACPInbound>

    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let errorPipe: Pipe
    private let inboundContinuation: AsyncStream<ACPInbound>.Continuation
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<TUIJSONValue, Error>] = [:]
    private var isStarted = false
    private var buffer = Data()
    /// Accumulated stderr, surfaced when the adapter exits abnormally (e.g. the
    /// launch command — npx / codex-acp — isn't installed), so the user sees the
    /// real reason instead of a generic "gateway exited".
    private var stderrBuffer = Data()
    private var consumeTask: Task<Void, Never>?

    init(spec: ACPLaunchSpec) {
        let stream = AsyncStream.makeStream(of: ACPInbound.self)
        self.inbound = stream.stream
        self.inboundContinuation = stream.continuation

        self.process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments
        process.currentDirectoryURL = spec.workingDirectory
        process.environment = spec.environment

        self.input = Pipe()
        self.output = Pipe()
        self.errorPipe = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe
    }

    func call(method: String, params: TUIJSONValue) async throws -> TUIJSONValue {
        try startIfNeeded()
        let id = nextID
        nextID += 1
        let frame = TUIJSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ])
        let data = try JSONEncoder().encode(frame)
        // Cancellation-aware: when the turn is stopped, the awaiting continuation
        // is resumed with `CancellationError` and dropped from `pending` (a long
        // `session/prompt` never resolves on its own otherwise, so Stop hangs).
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                write(data)
            }
        } onCancel: {
            Task { await self.cancelPending(id) }
        }
    }

    private func cancelPending(_ id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    /// Sends a client→agent notification (no id, no response awaited). Used for
    /// `session/cancel` to truly stop a turn rather than just detaching the UI.
    func notify(method: String, params: TUIJSONValue) {
        send(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ]))
    }

    /// Answers a server→client request with a result.
    func respond(id: TUIJSONValue, result: TUIJSONValue) {
        send(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result,
        ]))
    }

    /// Answers a server→client request with an error.
    func respond(id: TUIJSONValue, errorCode: Int, message: String) {
        send(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .number(Double(errorCode)), "message": .string(message)]),
        ]))
    }

    /// Kills the adapter and its descendants. `process.terminate()` alone only
    /// signals the `npx` wrapper, leaving its `node`/binary grandchildren
    /// orphaned — so kill the whole subtree by PID.
    func shutdown() {
        guard process.isRunning else { return }
        ACPConnection.killTree(pid: process.processIdentifier)
        isStarted = false
    }

    deinit {
        if process.isRunning {
            ACPConnection.killTree(pid: process.processIdentifier)
        }
    }

    /// SIGKILLs `pid` and every descendant (leaves first).
    static func killTree(pid: pid_t) {
        var order: [pid_t] = []
        var frontier: [pid_t] = [pid]
        while let current = frontier.popLast() {
            order.append(current)
            frontier.append(contentsOf: childPIDs(of: current))
        }
        for target in order.reversed() {
            kill(target, SIGKILL)
        }
    }

    private static func childPIDs(of pid: pid_t) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .split(whereSeparator: { $0.isNewline })
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) } ?? []
    }

    private func send(_ frame: TUIJSONValue) {
        guard let data = try? JSONEncoder().encode(frame) else { return }
        write(data)
    }

    private func write(_ data: Data) {
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data([0x0A]))
    }

    private func startIfNeeded() throws {
        guard !isStarted else { return }

        // Stdout chunks are funneled through one per-launch FIFO stream consumed
        // by a single task: a Task per readability callback has no ordering
        // guarantee across hops to this actor, and reordered chunks corrupt the
        // line framing. The stream is intentionally local to this start attempt,
        // so a failed launch cannot permanently finish future stdout delivery.
        let chunkStream = AsyncStream.makeStream(of: Data.self)
        let chunks = chunkStream.stream
        let chunkContinuation = chunkStream.continuation

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // Empty read = EOF (the adapter exited and the pipe drained);
            // finishing here — not in a termination handler, which can fire
            // before the last chunks arrive — keeps the final frames.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                chunkContinuation.finish()
                return
            }
            chunkContinuation.yield(data)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.appendStderr(data) }
        }
        consumeTask = Task { [weak self, chunks] in
            for await data in chunks {
                guard let self else { return }
                await self.consume(data)
            }
            await self?.finishAfterExit()
        }
        do {
            try process.run()
        } catch {
            chunkContinuation.finish()
            throw error
        }
        isStarted = true
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !lineData.isEmpty else { continue }
            handle(Data(lineData))
        }
    }

    private func handle(_ lineData: Data) {
        guard let value = try? JSONDecoder().decode(TUIJSONValue.self, from: lineData),
              case .object(let object) = value else { return }

        let method: String? = {
            if case .string(let value)? = object["method"] { return value }
            return nil
        }()
        let id = object["id"]

        if let method {
            let params = object["params"] ?? .null
            if let id, id != .null {
                inboundContinuation.yield(.request(id: id, method: method, params: params))
            } else {
                inboundContinuation.yield(.notification(method: method, params: params))
            }
            return
        }

        // Otherwise it is a response to one of our calls.
        guard let id, case .number(let idValue) = id,
              let continuation = pending.removeValue(forKey: Int(idValue)) else { return }
        if case .object(let error)? = object["error"] {
            let message: String = {
                // Adapters wrap the real cause in `error.data.message` and leave
                // the top-level message generic ("Internal error"). Prefer the
                // detail so the user sees e.g. a usage-limit notice, not -32603.
                if case .string(let value)? = error["data"]?["message"] { return value }
                if case .string(let value)? = error["message"] { return value }
                return "ACP error"
            }()
            continuation.resume(throwing: HermesAgentError.rpcError(message))
        } else {
            continuation.resume(returning: object["result"] ?? .null)
        }
    }

    private func appendStderr(_ data: Data) {
        stderrBuffer.append(data)
    }

    private func finishAfterExit() {
        isStarted = false
        // A non-zero exit usually means the launch command failed (e.g. npx or
        // the adapter binary isn't installed). Surface stderr so the user sees
        // the actual reason rather than a generic "gateway exited".
        let status = process.terminationStatus
        let stderr = String(data: stderrBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let error: any Error = status == 0
            ? HermesAgentError.gatewayExited
            : HermesAgentError.rpcError(
                stderr.isEmpty ? "The agent process exited with status \(status)." : stderr
            )
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
        inboundContinuation.finish()
    }
}

nonisolated extension TUIJSONValue {
    var objectValue: [String: TUIJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [TUIJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> TUIJSONValue? {
        objectValue?[key]
    }
}
