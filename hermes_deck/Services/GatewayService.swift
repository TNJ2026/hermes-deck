import Foundation

protocol HermesGatewayProvider: Sendable {
    func isRunning(profile: HermesProfile) async -> Bool
    func start(profile: HermesProfile) async throws
    func restart(profile: HermesProfile) async throws
}

actor LocalHermesGatewayProvider: HermesGatewayProvider {
    private let pythonURL: URL
    private let hermesURL: URL
    private let hermesAgentURL: URL
    private let rootURL: URL
    private let baseEnvironment: [String: String]

    init(
        pythonURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/hermes-agent/venv/bin/python"),
        hermesURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/hermes-agent/venv/bin/hermes"),
        hermesAgentURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/hermes-agent"),
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes"),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.pythonURL = pythonURL
        self.hermesURL = hermesURL
        self.hermesAgentURL = hermesAgentURL
        self.rootURL = rootURL
        self.baseEnvironment = baseEnvironment
    }

    func isRunning(profile: HermesProfile) async -> Bool {
        let pythonURL = pythonURL
        let hermesAgentURL = hermesAgentURL
        let environment = await environment(for: profile, includeRouting: false)

        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = pythonURL
            process.currentDirectoryURL = hermesAgentURL
            process.environment = environment
            process.arguments = [
                "-c",
                "from gateway.status import get_running_pid; print(1 if get_running_pid() else 0)",
            ]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return false
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text == "1"
        }.value
    }

    func start(profile: HermesProfile) async throws {
        let hermesURL = hermesURL
        let rootURL = rootURL
        let environment = await environment(for: profile)

        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = hermesURL
            process.currentDirectoryURL = rootURL
            process.environment = environment
            process.arguments = ["gateway", "start"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            // Fire-and-forget: the gateway either daemonizes (start returns) or
            // keeps running; the caller polls status rather than waiting here.
            try process.runTranslatingMissingCommand(named: "Hermes")
        }.value
    }

    func restart(profile: HermesProfile) async throws {
        try await stop(profile: profile)
        try await start(profile: profile)
    }

    private func stop(profile: HermesProfile) async throws {
        let pythonURL = pythonURL
        let hermesAgentURL = hermesAgentURL
        let environment = await environment(for: profile, includeRouting: false)

        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = pythonURL
            process.currentDirectoryURL = hermesAgentURL
            process.environment = environment
            process.arguments = [
                "-c",
                "from hermes_cli.gateway import stop_profile_gateway; stop_profile_gateway()",
            ]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.runTranslatingMissingCommand(named: "Hermes")
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw NSError(
                    domain: "HermesGateway",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Hermes gateway stop failed"]
                )
            }
        }.value
    }

    private func environment(for profile: HermesProfile, includeRouting: Bool = true) async -> [String: String] {
        var environment = baseEnvironment
        let id = profile.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let home = (id == "default" || id.isEmpty)
            ? rootURL
            : rootURL.appendingPathComponent("profiles").appendingPathComponent(id)
        environment["HERMES_HOME"] = home.path(percentEncoded: false)
        // Marks a gateway *started by the Deck* so its agent can tell it is being
        // rendered live in the Deck UI (where the `deck-routing` skill's
        // @target-code-block convention works). Absent when the Deck attaches to
        // a gateway started elsewhere.
        environment["HERMES_DECK"] = "1"
        if includeRouting {
            let routingEnvironment = await MainActor.run {
                DeckRoutingIPCServer.shared
            }
            .environmentVariables(waitingUpTo: 2)
            environment.merge(routingEnvironment) { _, new in new }
            let mcpEnvironment = await DeckMCPServer.shared.environmentVariables(waitingUpTo: 2)
            environment.merge(mcpEnvironment) { _, new in new }
        }
        return environment
    }
}
