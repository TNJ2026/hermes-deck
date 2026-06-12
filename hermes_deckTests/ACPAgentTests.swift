import Foundation
import Testing
@testable import hermes_deck

struct ACPAgentTests {
    private func object(_ json: String) throws -> [String: TUIJSONValue] {
        let value = try JSONDecoder().decode(TUIJSONValue.self, from: Data(json.utf8))
        return try #require(value.objectValue)
    }

    @Test
    func mapsAgentMessageChunkToMessageDelta() throws {
        let update = try object(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello"}}"#)
        let events = ACPEventMapper.events(update: update, sessionID: "s1")
        #expect(events == [.messageDelta(sessionID: "s1", text: "Hello")])
    }

    @Test
    func mapsAgentThoughtChunkToThinkingDelta() throws {
        let update = try object(#"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"hmm"}}"#)
        let events = ACPEventMapper.events(update: update, sessionID: "s1")
        #expect(events == [.thinkingDelta(sessionID: "s1", text: "hmm")])
    }

    @Test
    func mapsToolCallUsingClaudeToolName() throws {
        let update = try object(#"""
        {"sessionUpdate":"tool_call","toolCallId":"t1","title":"`ls`","kind":"execute","status":"pending","_meta":{"claudeCode":{"toolName":"Bash"}}}
        """#)
        let events = ACPEventMapper.events(update: update, sessionID: "s1")
        guard case .toolStart(let sessionID, let tool) = try #require(events.first) else {
            Issue.record("expected toolStart"); return
        }
        #expect(sessionID == "s1")
        #expect(tool.toolID == "t1")
        #expect(tool.name == "Bash")
        #expect(tool.context == "`ls`")
        #expect(tool.state == .running)
    }

    @Test
    func mapsCompletedToolUpdateToToolComplete() throws {
        let update = try object(#"""
        {"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","rawOutput":"done","_meta":{"claudeCode":{"toolName":"Bash"}}}
        """#)
        let events = ACPEventMapper.events(update: update, sessionID: "s1")
        guard case .toolComplete(_, let tool) = try #require(events.first) else {
            Issue.record("expected toolComplete"); return
        }
        #expect(tool.state == .complete)
        #expect(tool.name == "Bash")
        #expect(tool.summary == "done")
    }

    @Test
    func ignoresUnknownUpdateKinds() throws {
        let update = try object(#"{"sessionUpdate":"available_commands_update","availableCommands":[]}"#)
        #expect(ACPEventMapper.events(update: update, sessionID: "s1").isEmpty)
    }

    @Test
    func parsesPermissionOptionsAndText() throws {
        let params = try JSONDecoder().decode(TUIJSONValue.self, from: Data(#"""
        {"sessionId":"s1","toolCall":{"title":"Write file"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"reject","name":"Reject","kind":"reject_once"}]}
        """#.utf8))
        #expect(ACPEventMapper.permissionText(params) == "Allow Write file?")
        #expect(ACPEventMapper.permissionOptions(params) == [
            PermissionOption(id: "allow", label: "Allow"),
            PermissionOption(id: "reject", label: "Reject"),
        ])
    }

    @Test
    func permissionResponseResultWrapsSelectedOutcomeForACP() throws {
        #expect(ACPEventMapper.permissionResponseResult(optionID: "allow") == .object([
            "outcome": .object([
                "outcome": .string("selected"),
                "optionId": .string("allow"),
            ]),
        ]))
    }

    @Test
    func permissionResponseResultWrapsCancelledOutcomeForACP() throws {
        #expect(ACPEventMapper.permissionResponseResult(optionID: "") == .object([
            "outcome": .object([
                "outcome": .string("cancelled"),
            ]),
        ]))
    }

    @Test
    func codexLaunchSpecUsesZedAdapter() {
        let spec = ACPAgent.codex.launchSpec(base: ["PATH": "/usr/bin"])
        #expect(spec.executableURL.path == "/usr/bin/env")
        #expect(spec.arguments == ["npx", "--prefer-offline", "-y", "@zed-industries/codex-acp"])
    }

    @Test
    func acpSessionUsesRequestWorkingDirectory() throws {
        let source = try sourceFile("hermes_deck/Services/ACPAgentClient.swift")
        #expect(source.contains("request.workingDirectory.path(percentEncoded: false)"))
        #expect(!source.contains("let cwd = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)"))
    }

    @Test
    func cliBackendsRunFromRequestWorkingDirectory() throws {
        let claude = try sourceFile("hermes_deck/Services/ClaudeCLIClient.swift")
        let agy = try sourceFile("hermes_deck/Services/AgyClient.swift")
        #expect(claude.contains("workingDirectory: request.workingDirectory"))
        #expect(agy.contains("workingDirectory: request.workingDirectory"))
    }

    @Test
    func agyDoesNotUseGlobalContinueForConversationState() throws {
        let source = try sourceFile("hermes_deck/Services/AgyClient.swift")
        #expect(!source.contains("\"--continue\""))
        #expect(!source.contains("seenConversations"))
    }

    @Test
    func acpConnectionMarksStartedOnlyAfterProcessRunSucceeds() throws {
        let source = try sourceFile("hermes_deck/Services/ACPConnection.swift")
        let start = try #require(source.range(of: "private func startIfNeeded() throws")?.lowerBound)
        let end = try #require(source[start...].range(of: "private func consume")?.lowerBound)
        let functionSource = String(source[start..<end])
        let runRange = try #require(functionSource.range(of: "try process.run()"))
        let startedRange = try #require(functionSource.range(of: "isStarted = true"))
        #expect(startedRange.lowerBound > runRange.lowerBound)
    }

    @Test
    func launchEnvironmentStripsGuardsAndExtendsPath() {
        let env = AgentLaunchEnvironment.make(base: ["CLAUDECODE": "1", "PATH": "/usr/bin"])
        #expect(env["CLAUDECODE"] == nil)
        #expect(env["PATH"]?.contains("/opt/homebrew/bin") == true)
    }

    @Test
    func panelItemMapping() {
        #expect(ACPAgent(panelItem: .codex) == .codex)
        #expect(ACPAgent(panelItem: .claude) == nil)
        #expect(ACPAgent(panelItem: .gemini) == nil)
        #expect(ACPAgent(panelItem: .agents) == nil)
    }

    // MARK: - Claude CLI stream-json

    @Test
    func claudeParsesAssistantTextToMessageDelta() {
        let events = ClaudeStreamParser.parse(#"{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}"#, sessionID: "s1")
        #expect(events == [.messageDelta(sessionID: "s1", text: "ok")])
    }

    @Test
    func claudeParsesToolUseToToolStart() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#
        guard case .toolStart(_, let tool)? = ClaudeStreamParser.parse(line, sessionID: "s1").first else {
            Issue.record("expected toolStart"); return
        }
        #expect(tool.toolID == "t1")
        #expect(tool.name == "Bash")
        #expect(tool.context == "ls")
        #expect(tool.state == .running)
    }

    @Test
    func claudeParsesResultToMessageComplete() {
        let events = ClaudeStreamParser.parse(#"{"type":"result","subtype":"success","stop_reason":"end_turn","result":"ok"}"#, sessionID: "s1")
        #expect(events == [.messageComplete(sessionID: "s1", text: "", status: "complete", usage: nil)])
    }

    @Test
    func claudeIgnoresSystemAndRateLimitEvents() {
        #expect(ClaudeStreamParser.parse(#"{"type":"system","subtype":"init"}"#, sessionID: "s1").isEmpty)
        #expect(ClaudeStreamParser.parse(#"{"type":"rate_limit_event"}"#, sessionID: "s1").isEmpty)
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
