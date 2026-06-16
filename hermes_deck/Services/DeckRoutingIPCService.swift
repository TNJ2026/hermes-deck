import Foundation
import Network

struct DeckRoutingIPCRequest: Decodable, Sendable {
    var token: String
    var target: String
    var prompt: String
    var wait: Bool?
    var sourceSessionKey: String?
    var sourceProfileID: String?

    enum CodingKeys: String, CodingKey {
        case token
        case target
        case prompt
        case wait
        case sourceSessionKey = "source_session_key"
        case sourceProfileID = "source_profile_id"
    }
}

struct DeckRoutingIPCResponse: Encodable, Sendable {
    var ok: Bool
    var status: String?
    var error: String?
}

final class DeckRoutingIPCServer: @unchecked Sendable {
    static let shared = DeckRoutingIPCServer()

    typealias Handler = @Sendable (DeckRoutingIPCRequest) async -> DeckRoutingIPCResponse

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "deck-routing-ipc")
    nonisolated(unsafe) private var listener: NWListener?
    nonisolated(unsafe) private var token = UUID().uuidString
    nonisolated(unsafe) private var port: UInt16?
    nonisolated(unsafe) private var handler: Handler?

    private init() {}

    func start(handler: @escaping Handler) throws {
        lock.lock()
        self.handler = handler
        let alreadyStarted = listener != nil
        lock.unlock()
        guard !alreadyStarted else { return }

        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: 0)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let port = listener.port else { return }
            self?.lock.lock()
            self?.port = port.rawValue
            self?.lock.unlock()
        }
        listener.start(queue: queue)

        lock.lock()
        self.listener = listener
        lock.unlock()
    }

    nonisolated func environmentVariables() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        guard let port else { return [:] }
        return [
            "HERMES_DECK_ROUTE_HOST": "127.0.0.1",
            "HERMES_DECK_ROUTE_PORT": String(port),
            "HERMES_DECK_ROUTE_TOKEN": token,
        ]
    }

    nonisolated func environmentVariablesBlocking(waitingUpTo timeout: TimeInterval) -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let environment = environmentVariables()
            if !environment.isEmpty {
                return environment
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return environmentVariables()
    }

    func environmentVariables(waitingUpTo timeout: TimeInterval) async -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let environment = environmentVariables()
            if !environment.isEmpty {
                return environment
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return environmentVariables()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveLine(from: connection, data: Data())
    }

    private func receiveLine(from connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = data
            if let chunk {
                buffer.append(chunk)
            }
            if let newlineIndex = buffer.firstIndex(of: 10) {
                let line = buffer[..<newlineIndex]
                self.respond(to: Data(line), on: connection)
                return
            }
            if isComplete || error != nil {
                self.respond(to: buffer, on: connection)
                return
            }
            self.receiveLine(from: connection, data: buffer)
        }
    }

    private func respond(to data: Data, on connection: NWConnection) {
        let response: DeckRoutingIPCResponse
        do {
            let request = try JSONDecoder().decode(DeckRoutingIPCRequest.self, from: data)
            lock.lock()
            let expectedToken = token
            let handler = handler
            lock.unlock()
            guard request.token == expectedToken else {
                send(DeckRoutingIPCResponse(ok: false, status: nil, error: "Invalid routing token"), on: connection)
                return
            }
            guard let handler else {
                send(DeckRoutingIPCResponse(ok: false, status: nil, error: "Deck routing handler is not available"), on: connection)
                return
            }
            Task {
                let result = await handler(request)
                self.send(result, on: connection)
            }
            return
        } catch {
            response = DeckRoutingIPCResponse(ok: false, status: nil, error: "Invalid routing request: \(error.localizedDescription)")
        }
        send(response, on: connection)
    }

    private func send(_ response: DeckRoutingIPCResponse, on connection: NWConnection) {
        let data: Data
        do {
            data = try JSONEncoder().encode(response) + Data([10])
        } catch {
            data = Data(#"{"ok":false,"error":"Failed to encode routing response"}"#.utf8) + Data([10])
        }
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
