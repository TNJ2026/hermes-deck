import Foundation
import Testing
@testable import hermes_deck

struct DeckMCPServerTests {
    @Test func agentPanelMCPWiresEachCLI() throws {
        try DeckMCPServer.shared.start { _, _ in "ok" } // ensure the endpoint is up

        // codex: config overrides on argv + bearer token via env var.
        let codex = AgentPanelMCP.configure(backend: .acp(.codex), sessionID: UUID())
        #expect(codex.args.contains("-c"))
        #expect(codex.args.contains { $0.hasPrefix("mcp_servers.deck.url=") })
        #expect(codex.args.contains("mcp_servers.deck.bearer_token_env_var=\"HERMES_DECK_MCP_TOKEN\""))
        #expect(codex.environment["HERMES_DECK_MCP_TOKEN"]?.isEmpty == false)

        // claude: a written --mcp-config file carrying the bearer header.
        let session = UUID()
        let claude = AgentPanelMCP.configure(backend: .claudeCLI, sessionID: session)
        // The reply convention rides in the system prompt, not the visible prompt.
        #expect(claude.args.contains("--append-system-prompt"))
        let flagIndex = try #require(claude.args.firstIndex(of: "--mcp-config"))
        let path = claude.args[claude.args.index(after: flagIndex)]
        let json = try #require(try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let deck = ((json["mcpServers"] as? [String: Any])?["deck"] as? [String: Any])
        #expect(deck?["type"] as? String == "http")
        let auth = (deck?["headers"] as? [String: Any])?["Authorization"] as? String
        #expect(auth?.hasPrefix("Bearer ") == true)
        // Token matches the one minted for this session.
        #expect(auth == "Bearer \(DeckMCPServer.shared.token(forSession: session.uuidString))")
    }

    @Test func deckReplyMCPHandshakeAndToolCall() async throws {
        let server = DeckMCPServer.shared
        try server.start { session, message in "received from \(session): \(message)" }
        let endpoint = try #require(server.endpointURL())
        let url = try #require(URL(string: endpoint))
        let token = server.token(forSession: "panel-1")

        func rpc(_ payload: [String: Any], auth: Bool = true) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return (code, json)
        }

        // Missing/wrong bearer token is rejected.
        let (unauthorized, _) = try await rpc(["jsonrpc": "2.0", "id": 1, "method": "initialize"], auth: false)
        #expect(unauthorized == 401)

        // initialize
        let (initCode, initJSON) = try await rpc([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18"],
        ])
        #expect(initCode == 200)
        let serverInfo = (initJSON["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        #expect(serverInfo?["name"] as? String == "hermes-deck")

        // tools/list advertises deck_reply
        let (_, listJSON) = try await rpc(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = (listJSON["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        #expect(tools?.contains { $0["name"] as? String == "deck_reply" } == true)

        // tools/call reaches the handler and returns its text
        let (_, callJSON) = try await rpc([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "deck_reply", "arguments": ["message": "hi there"]],
        ])
        let content = ((callJSON["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first
        #expect(content?["text"] as? String == "received from panel-1: hi there")
    }

    @Test func cleanupConfigDeletesFiles() throws {
        let session = UUID()
        _ = AgentPanelMCP.configure(backend: .claudeCLI, sessionID: session)
        let file = AgentPanelMCP.claudeConfigFileURL(sessionID: session)
        #expect(FileManager.default.fileExists(atPath: file.path))

        AgentPanelMCP.cleanupClaudeConfig(sessionID: session)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // Gemini
        _ = AgentPanelMCP.configure(backend: .agy, sessionID: UUID())
        let geminiFile = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini/config/mcp_config.json")
        #expect(FileManager.default.fileExists(atPath: geminiFile.path))
        let textBefore = try String(contentsOf: geminiFile)
        #expect(textBefore.contains("deck"))

        AgentPanelMCP.cleanupGeminiConfig()
        let fileExists = FileManager.default.fileExists(atPath: geminiFile.path)
        if fileExists {
            let textAfter = try String(contentsOf: geminiFile)
            #expect(!textAfter.contains("deck"))
        } else {
            #expect(!fileExists)
        }
    }
}

