import Foundation
import Testing
@testable import hermes_deck

// Serialized: these tests share the `DeckMCPServer.shared` singleton, whose
// `start` overwrites the handler each call — running them in parallel races the
// handler.
@Suite(.serialized)
struct DeckMCPServerTests {
    private func geminiDeckServer(in file: URL) throws -> [String: Any]? {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        return (root?["mcpServers"] as? [String: Any])?["deck"] as? [String: Any]
    }

    @Test func agentPanelMCPWiresEachCLI() throws {
        try DeckMCPServer.shared.start { _, _ in "ok" } // ensure the endpoint is up
        let geminiFiles = [AgentPanelMCP.geminiCLISettingsFileURL, AgentPanelMCP.legacyGeminiMCPConfigFileURL]
        let geminiSnapshots = geminiFiles.reduce(into: [URL: Data?]()) { snapshots, file in
            snapshots[file] = try? Data(contentsOf: file)
        }
        defer {
            AgentPanelMCP.cleanupGeminiConfig()
            for file in geminiFiles {
                if let data = geminiSnapshots[file] ?? nil {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: file)
                } else {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }

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

        // agy/Gemini: Deck goes into Antigravity CLI settings using its MCP
        // HTTP URL fields.
        _ = AgentPanelMCP.configure(backend: .agy, sessionID: UUID())
        let maybeGeminiDeck = try geminiDeckServer(in: AgentPanelMCP.geminiCLISettingsFileURL)
        let geminiDeck = try #require(maybeGeminiDeck)
        #expect(geminiDeck["serverUrl"] as? String == DeckMCPServer.shared.endpointURL())
        #expect(geminiDeck["url"] as? String == DeckMCPServer.shared.endpointURL())
        #expect(geminiDeck["httpUrl"] == nil)
        let geminiAuth = (geminiDeck["headers"] as? [String: Any])?["Authorization"] as? String
        #expect(geminiAuth?.hasPrefix("Bearer ") == true)
    }

    @Test func deckReplyMCPHandshakeAndToolCall() async throws {
        let server = DeckMCPServer.shared
        try server.start(
            replyHandler: { session, message in "received from \(session): \(message)" },
            delegateHandler: { request in
                DeckMCPDelegateResponse(
                    ok: true,
                    status: "queued \(request.target): \(request.prompt)",
                    error: nil
                )
            }
        )
        let endpoint = try #require(server.endpointURL())
        let url = try #require(URL(string: endpoint))
        let panelToken = server.token(forSession: "panel-1")
        let gatewayToken = try #require(server.environmentVariablesBlocking(waitingUpTo: 2)["HERMES_DECK_MCP_TOKEN"])

        func rpc(_ payload: [String: Any], token: String?) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return (code, json)
        }
        func names(_ json: [String: Any]) -> [String] {
            ((json["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        }
        func callText(_ json: [String: Any]) -> String? {
            (((json["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first)?["text"] as? String
        }

        // No token is rejected.
        let (unauthorized, _) = try await rpc(["jsonrpc": "2.0", "id": 1, "method": "initialize"], token: nil)
        #expect(unauthorized == 401)

        // initialize
        let (initCode, initJSON) = try await rpc([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18"],
        ], token: panelToken)
        #expect(initCode == 200)
        #expect(((initJSON["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String == "hermes-deck")

        // A panel token sees and may call deck_reply only.
        let (_, panelList) = try await rpc(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], token: panelToken)
        #expect(names(panelList) == ["deck_reply"])

        let (_, replyJSON) = try await rpc([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "deck_reply", "arguments": ["message": "hi there"]],
        ], token: panelToken)
        #expect(callText(replyJSON) == "received from panel-1: hi there")

        // A panel token must NOT be able to delegate as a Hermes source.
        let (_, panelDelegate) = try await rpc([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "deck_delegate_prompt", "arguments": ["target": "codex", "prompt": "x", "source_session_key": "source-1"]],
        ], token: panelToken)
        #expect((panelDelegate["error"] as? [String: Any]) != nil)

        // A gateway token sees and may call deck_delegate_prompt only.
        let (_, gatewayList) = try await rpc(["jsonrpc": "2.0", "id": 5, "method": "tools/list"], token: gatewayToken)
        #expect(names(gatewayList) == ["deck_delegate_prompt"])

        let (_, delegateJSON) = try await rpc([
            "jsonrpc": "2.0", "id": 6, "method": "tools/call",
            "params": [
                "name": "deck_delegate_prompt",
                "arguments": ["target": "codex", "prompt": "inspect repo", "source_session_key": "source-1", "source_profile_id": "default"],
            ],
        ], token: gatewayToken)
        #expect(callText(delegateJSON)?.contains("queued codex: inspect repo") == true)
    }

    @Test func delegateResponseMarksFallbackOnlyWhenUnavailable() {
        // Unavailable → fallback flag, so the plugin retries the legacy TCP IPC.
        #expect(DeckMCPDelegateResponse(ok: false, status: nil, error: "x", fallback: true)
            .jsonString.contains("\"fallback\":true"))
        // Validation failure → no fallback (IPC routes the same path, same result).
        #expect(!DeckMCPDelegateResponse(ok: false, status: nil, error: "x")
            .jsonString.contains("fallback"))
    }

    @Test func cleanupConfigDeletesFiles() throws {
        let session = UUID()
        _ = AgentPanelMCP.configure(backend: .claudeCLI, sessionID: session)
        let file = AgentPanelMCP.claudeConfigFileURL(sessionID: session)
        #expect(FileManager.default.fileExists(atPath: file.path))

        AgentPanelMCP.cleanupClaudeConfig(sessionID: session)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // Gemini
        let geminiFiles = [AgentPanelMCP.geminiCLISettingsFileURL, AgentPanelMCP.legacyGeminiMCPConfigFileURL]
        let geminiSnapshots = geminiFiles.reduce(into: [URL: Data?]()) { snapshots, file in
            snapshots[file] = try? Data(contentsOf: file)
        }
        defer {
            for file in geminiFiles {
                if let data = geminiSnapshots[file] ?? nil {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: file)
                } else {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        _ = AgentPanelMCP.configure(backend: .agy, sessionID: UUID())
        let geminiFile = AgentPanelMCP.geminiCLISettingsFileURL
        #expect(FileManager.default.fileExists(atPath: geminiFile.path))
        #expect(try geminiDeckServer(in: geminiFile) != nil)

        let legacyFile = AgentPanelMCP.legacyGeminiMCPConfigFileURL
        let legacyRoot: [String: Any] = ["mcpServers": ["deck": ["httpUrl": "http://old.example/mcp"]]]
        try FileManager.default.createDirectory(at: legacyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: legacyRoot, options: .prettyPrinted).write(to: legacyFile)

        AgentPanelMCP.cleanupGeminiConfig()
        #expect(try geminiDeckServer(in: geminiFile) == nil)
        #expect(!FileManager.default.fileExists(atPath: legacyFile.path))
    }
}
