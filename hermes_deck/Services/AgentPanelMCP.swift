import Foundation

/// Wires a panel CLI to the Deck MCP server so it can discover and call
/// `deck_reply` — no instruction pasted into the terminal. Each CLI configures
/// streamable-HTTP MCP differently, so this returns the extra launch args and
/// environment (and writes any config files) for one panel.
enum AgentPanelMCP {
    struct Launch {
        var args: [String] = []
        var environment: [String: String] = [:]
    }

    /// Directory for per-session MCP config files.
    private static var configDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("HermesDeck/mcp", isDirectory: true)
    }

    /// Mints the panel's token and returns the launch additions for its CLI.
    /// Returns nothing when the MCP endpoint isn't up yet (the loop then just
    /// times out, rather than blocking the launch).
    static func configure(backend: AgentBackend, sessionID: UUID) -> Launch {
        guard let url = DeckMCPServer.shared.endpointURL() else { return Launch() }
        let token = DeckMCPServer.shared.token(forSession: sessionID.uuidString)
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        switch backend {
        case .claudeCLI:
            return claude(url: url, token: token, sessionID: sessionID)
        case .acp(.codex):
            return codex(url: url, token: token)
        case .agy:
            return gemini(url: url, token: token)
        case .acp, .hermes:
            return Launch()
        }
    }

    private static func claude(url: String, token: String, sessionID: UUID) -> Launch {
        let config: [String: Any] = [
            "mcpServers": [
                "deck": [
                    "type": "http",
                    "url": url,
                    "headers": ["Authorization": "Bearer \(token)"],
                ],
            ],
        ]
        let file = configDirectory.appendingPathComponent("claude-\(sessionID.uuidString).json")
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              (try? data.write(to: file)) != nil else {
            return Launch()
        }
        return Launch(args: ["--mcp-config", file.path])
    }

    private static func codex(url: String, token: String) -> Launch {
        // codex takes config overrides as `-c key=<toml-value>` and reads the
        // bearer token from an env var.
        return Launch(
            args: [
                "-c", "mcp_servers.deck.url=\"\(url)\"",
                "-c", "mcp_servers.deck.bearer_token_env_var=\"HERMES_DECK_MCP_TOKEN\"",
            ],
            environment: ["HERMES_DECK_MCP_TOKEN": token]
        )
    }

    private static func gemini(url: String, token: String) -> Launch {
        // agy/Gemini reads a global mcp config file; merge rather than clobber.
        let file = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini/config/mcp_config.json")
        var root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]) ?? [:]
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["deck"] = [
            "httpUrl": url,
            "headers": ["Authorization": "Bearer \(token)"],
        ]
        root["mcpServers"] = servers
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: root, options: .prettyPrinted).write(to: file)
        return Launch()
    }
}
