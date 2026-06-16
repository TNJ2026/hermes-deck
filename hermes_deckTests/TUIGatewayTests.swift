import Foundation
import Testing
@testable import hermes_deck

struct TUIGatewayTests {
    @Test
    func parsesMessageDeltaEvent() throws {
        let line = """
        {"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"abc123","payload":{"text":"hello"}}}
        """

        let event = try TUIGatewayEventParser.parseEvent(line)

        #expect(event == .messageDelta(sessionID: "abc123", text: "hello"))
    }

    @Test
    func parsesMessageCompleteEvent() throws {
        let line = """
        {"jsonrpc":"2.0","method":"event","params":{"type":"message.complete","session_id":"abc123","payload":{"text":"hello world","status":"complete"}}}
        """

        let event = try TUIGatewayEventParser.parseEvent(line)

        #expect(event == .messageComplete(sessionID: "abc123", text: "hello world", status: "complete", usage: nil))
    }

    @Test
    func parsesSessionInfoWithModelContextAndTokens() throws {
        let line = """
        {"jsonrpc":"2.0","method":"event","params":{"type":"session.info","session_id":"abc123","payload":{"model":"Hermes 4 70B","context_length":128000,"used_tokens":2140,"cwd":"/tmp"}}}
        """

        let event = try TUIGatewayEventParser.parseEvent(line)

        #expect(event == .sessionInfo(
            sessionID: "abc123",
            info: HermesSessionInfo(model: "Hermes 4 70B", contextLength: 128000, usedTokens: 2140, cwd: "/tmp")
        ))
    }

    @Test
    func parsesNestedUsageFromSessionInfo() throws {
        let line = """
        {"jsonrpc":"2.0","method":"event","params":{"type":"session.info","session_id":"abc123","payload":{"model":"Hermes 4 70B","cwd":"/tmp","usage":{"context_used":2140,"context_max":128000}}}}
        """

        let event = try TUIGatewayEventParser.parseEvent(line)

        #expect(event == .sessionInfo(
            sessionID: "abc123",
            info: HermesSessionInfo(model: "Hermes 4 70B", contextLength: 128000, usedTokens: 2140, cwd: "/tmp")
        ))
    }

    @Test
    func parsesNestedUsageFromMessageComplete() throws {
        let line = """
        {"jsonrpc":"2.0","method":"event","params":{"type":"message.complete","session_id":"abc123","payload":{"text":"hello world","status":"complete","usage":{"model":"Hermes 4 70B","input":1200,"output":340,"context_max":128000}}}}
        """

        let event = try TUIGatewayEventParser.parseEvent(line)

        #expect(event == .messageComplete(
            sessionID: "abc123",
            text: "hello world",
            status: "complete",
            usage: HermesTokenUsage(usedTokens: 1540, contextLength: 128000)
        ))
    }

    @Test
    func parsesToolEvents() throws {
        let startLine = """
        {"jsonrpc":"2.0","method":"event","params":{"type":"tool.start","session_id":"abc123","payload":{"tool_id":"tool-1","name":"terminal","context":"pwd"}}}
        """
        let completeLine = """
        {"jsonrpc":"2.0","method":"event","params":{"type":"tool.complete","session_id":"abc123","payload":{"tool_id":"tool-1","name":"terminal","summary":"done","duration_s":0.25}}}
        """

        let start = try TUIGatewayEventParser.parseEvent(startLine)
        let complete = try TUIGatewayEventParser.parseEvent(completeLine)

        if case .toolStart(let sessionID, let tool) = start {
            #expect(sessionID == "abc123")
            #expect(tool.toolID == "tool-1")
            #expect(tool.name == "terminal")
            #expect(tool.state == .running)
            #expect(tool.context == "pwd")
        } else {
            Issue.record("Expected tool.start event")
        }

        if case .toolComplete(let sessionID, let tool) = complete {
            #expect(sessionID == "abc123")
            #expect(tool.toolID == "tool-1")
            #expect(tool.name == "terminal")
            #expect(tool.state == .complete)
            #expect(tool.summary == "done")
            #expect(tool.durationSeconds == 0.25)
        } else {
            Issue.record("Expected tool.complete event")
        }
    }

    @Test
    func parsesClarifyRequestEvent() throws {
        let line = """
        {"jsonrpc":"2.0","method":"event","params":{"type":"clarify.request","session_id":"abc123","payload":{"request_id":"req-1","question":"Pick one","choices":["A","B"]}}}
        """

        let event = try TUIGatewayEventParser.parseEvent(line)

        #expect(event == .clarifyRequest(sessionID: "abc123", requestID: "req-1", question: "Pick one", choices: ["A", "B"]))
    }

    @Test
    func parsesApprovalRequestEventWithCommandAndDescription() throws {
        let line = """
        {"jsonrpc":"2.0","method":"event","params":{"type":"approval.request","session_id":"abc123","payload":{"command":"rm -rf build","description":"recursive delete"}}}
        """

        let event = try TUIGatewayEventParser.parseEvent(line)

        #expect(event == .approvalRequest(
            sessionID: "abc123",
            requestID: "hermes:abc123",
            text: "recursive delete\n\nCommand:\nrm -rf build",
            options: [
                PermissionOption(id: "once", label: "Allow once"),
                PermissionOption(id: "session", label: "Allow this session"),
                PermissionOption(id: "always", label: "Always allow"),
                PermissionOption(id: "deny", label: "Deny"),
            ]
        ))
    }

    @Test
    func parsesSubagentProgressEvents() throws {
        let line = """
        {"jsonrpc":"2.0","method":"event","params":{"type":"subagent.complete","session_id":"abc123","payload":{"goal":"Inspect files","subagent_id":"sa-1","parent_id":"root","task_index":1,"task_count":3,"depth":1,"status":"completed","summary":"Found issue","duration_seconds":2.4,"tool_count":2,"input_tokens":1000,"output_tokens":250,"api_calls":2,"files_read":["README.md"],"files_written":["fix.swift"],"output_tail":[{"tool":"read_file","preview":"ok","is_error":false}]}}}
        """

        let event = try TUIGatewayEventParser.parseEvent(line)

        if case .subagentComplete(let sessionID, let progress) = event {
            #expect(sessionID == "abc123")
            #expect(progress.id == "sa-1")
            #expect(progress.parentID == "root")
            #expect(progress.goal == "Inspect files")
            #expect(progress.taskIndex == 1)
            #expect(progress.taskCount == 3)
            #expect(progress.depth == 1)
            #expect(progress.status == .completed)
            #expect(progress.summary == "Found issue")
            #expect(progress.durationSeconds == 2.4)
            #expect(progress.toolCount == 2)
            #expect(progress.inputTokens == 1000)
            #expect(progress.outputTokens == 250)
            #expect(progress.apiCalls == 2)
            #expect(progress.filesRead == ["README.md"])
            #expect(progress.filesWritten == ["fix.swift"])
            #expect(progress.outputTail.first?.tool == "read_file")
        } else {
            Issue.record("Expected subagent.complete event")
        }
    }

    @Test
    func parsesHermesProfileListJSON() throws {
        let data = """
        [{"id":"default","display_name":"default"},{"id":"developer","display_name":"developer"}]
        """.data(using: .utf8)!

        let profiles = try HermesProfileListParser.parse(data)

        #expect(profiles.map(\.id) == ["default", "developer"])
        // The CLI echoes the id as display_name; an echoed name is treated as
        // "no name", so the default profile derives the friendly label.
        #expect(profiles.map(\.displayName) == ["Hermes agent", "developer"])
    }

    @Test
    func profileGatewayClientReusesOneGatewayPerProfile() async throws {
        let recorder = ProfileGatewayFactoryRecorder()
        let client = HermesProfileGatewayClient(makeClient: { recorder.makeClient(profile: $0) })
        let defaultRequest = HermesChatRequest(
            conversationID: UUID(),
            profile: .defaultProfile,
            messages: [ChatMessage(role: .user, content: "hello")],
            attachments: []
        )
        let codingRequest = HermesChatRequest(
            conversationID: UUID(),
            profile: .coding,
            messages: [ChatMessage(role: .user, content: "hello")],
            attachments: []
        )

        _ = try await client.send(defaultRequest)
        _ = try await client.send(codingRequest)
        _ = try await client.send(defaultRequest)

        #expect(recorder.createdProfileIDs == ["default", "coding"])
    }

    @Test
    func profileGatewayClientForwardsHermesApprovalResponsesToRunningGateways() async throws {
        let recorder = ProfileGatewayFactoryRecorder()
        let client = HermesProfileGatewayClient(makeClient: { recorder.makeClient(profile: $0) })
        let request = HermesChatRequest(
            conversationID: UUID(),
            profile: .defaultProfile,
            messages: [ChatMessage(role: .user, content: "hello")],
            attachments: []
        )

        _ = try await client.send(request)
        await client.respondToPermission(requestID: "hermes:s1", optionID: "session")

        #expect(recorder.permissionResponses.count == 1)
        #expect(recorder.permissionResponses.first?.0 == "hermes:s1")
        #expect(recorder.permissionResponses.first?.1 == "session")
    }

    @Test
    func gatewayEnvironmentPrependsHermesVenvBinToPath() throws {
        let executableURL = URL(fileURLWithPath: "/Users/test/.hermes/hermes-agent/venv/bin/python")

        let environment = HermesTUIGatewayClient.environment(
            for: .defaultProfile,
            executableURL: executableURL,
            base: [:]
        )

        let path = try #require(environment["PATH"])
        #expect(path.split(separator: ":").first == "/Users/test/.hermes/hermes-agent/venv/bin")
        #expect(environment["VIRTUAL_ENV"] == "/Users/test/.hermes/hermes-agent/venv")
    }

    @Test
    func gatewayEnvironmentIncludesDeckRoutingIPCVariables() async throws {
        try DeckRoutingIPCServer.shared.start { _ in
            DeckRoutingIPCResponse(ok: true, status: "queued", error: nil)
        }
        _ = await DeckRoutingIPCServer.shared.environmentVariables(waitingUpTo: 2)

        let environment = HermesTUIGatewayClient.environment(
            for: .defaultProfile,
            executableURL: URL(fileURLWithPath: "/Users/test/.hermes/hermes-agent/venv/bin/python"),
            base: [:]
        )

        #expect(environment["HERMES_DECK"] == "1")
        #expect(environment["HERMES_DECK_ROUTE_HOST"] == "127.0.0.1")
        #expect(environment["HERMES_DECK_ROUTE_PORT"]?.isEmpty == false)
        #expect(environment["HERMES_DECK_ROUTE_TOKEN"]?.isEmpty == false)
    }

    @Test
    func appEntitlementsAllowMicrophoneInputWithoutSandboxingGateway() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let entitlementsURL = projectRoot.appending(path: "hermes_deck/hermes_deck.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let entitlements = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool != true)
        #expect(entitlements["com.apple.security.device.audio-input"] as? Bool == true)
    }

    @Test
    func appBuildSettingsDoNotEnableSandboxForGatewayProcess() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let projectURL = projectRoot.appending(path: "hermes_deck.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        #expect(!project.contains("ENABLE_APP_SANDBOX = YES;"))
    }
}

private final class ProfileGatewayFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var profileIDs: [String] = []
    private var responses: [(String, String)] = []

    var createdProfileIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return profileIDs
    }

    var permissionResponses: [(String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return responses
    }

    func makeClient(profile: HermesProfile) -> any HermesAgentClient {
        lock.lock()
        profileIDs.append(profile.id)
        lock.unlock()
        return RecordingProfileGatewayClient(reply: "ok") { [weak self] requestID, optionID in
            guard let self else { return }
            self.lock.lock()
            self.responses.append((requestID, optionID))
            self.lock.unlock()
        }
    }
}

private struct RecordingProfileGatewayClient: HermesAgentClient {
    var reply: String
    var onPermissionResponse: @Sendable (String, String) -> Void

    func send(_ request: HermesChatRequest) async throws -> HermesChatResponse {
        HermesChatResponse(content: reply)
    }

    func respondToPermission(requestID: String, optionID: String) async {
        onPermissionResponse(requestID, optionID)
    }
}
