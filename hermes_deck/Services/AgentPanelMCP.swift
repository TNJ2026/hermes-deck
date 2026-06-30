import Foundation

/// Wires a panel CLI to the Deck MCP server so it can discover and call Deck
/// tools — no reply instruction pasted into the terminal. Each CLI configures
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

    static func claudeConfigFileURL(sessionID: UUID) -> URL {
        configDirectory.appendingPathComponent("claude-\(sessionID.uuidString).json")
    }

    static var geminiCLISettingsFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini/antigravity-cli/settings.json")
    }

    /// The file agy actually reads MCP servers from.
    static var geminiMCPConfigFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini/config/mcp_config.json")
    }

    static func cleanupClaudeConfig(sessionID: UUID) {
        let file = claudeConfigFileURL(sessionID: sessionID)
        try? FileManager.default.removeItem(at: file)
    }

    static func cleanupGeminiConfig() {
        removeGeminiDeckServer(from: geminiMCPConfigFileURL, removeEmptyFile: true)
        // Older builds wrote the entry into the Antigravity settings file; clear
        // it there too (keep the file — it holds the user's other settings).
        removeGeminiDeckServer(from: geminiCLISettingsFileURL, removeEmptyFile: false)
    }

    private static func removeGeminiDeckServer(from file: URL, removeEmptyFile: Bool) {
        guard var root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]) else { return }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        guard servers.removeValue(forKey: "deck") != nil else { return }
        if servers.isEmpty {
            root.removeValue(forKey: "mcpServers")
        } else {
            root["mcpServers"] = servers
        }
        if removeEmptyFile && root.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else {
            try? JSONSerialization.data(withJSONObject: root, options: .prettyPrinted).write(to: file, options: .atomic)
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
        let file = claudeConfigFileURL(sessionID: sessionID)
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              (try? data.write(to: file, options: .atomic)) != nil else {
            return Launch()
        }
        // The reply convention rides in the system prompt so the delegated
        // prompt itself stays clean in the terminal.
        return Launch(args: ["--mcp-config", file.path, "--append-system-prompt", DeckReplyPrimer.systemPrompt])
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
        // agy reads MCP servers from ~/.gemini/config/mcp_config.json; its schema
        // uses `serverUrl`/`url` (it has no `httpUrl` field, so that is ignored).
        let file = geminiMCPConfigFileURL
        var root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]) ?? [:]
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["deck"] = [
            "serverUrl": url,
            "url": url,
            "headers": ["Authorization": "Bearer \(token)"],
        ]
        root["mcpServers"] = servers
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: root, options: .prettyPrinted).write(to: file)
        return Launch()
    }
}

/// Instruction that drives the `deck_reply` tool call for panel-based
/// delegation. The tool is discoverable via MCP, but a model won't call it
/// unless told the task was delegated and the result must be returned.
enum DeckReplyPrimer {
    /// Whether a backend takes the convention via its system prompt at launch
    /// (so the visible prompt stays clean) rather than a per-turn prefix.
    static func usesSystemPrompt(_ backend: AgentBackend) -> Bool {
        backend == .claudeCLI
    }

    /// Visible, per-turn instruction for CLIs without a clean system-prompt hook
    /// (codex / agy).
    static func wrap(_ prompt: String) -> String {
        """
        [Hermes Deck] When done, return your result via the `deck_reply` tool.

        \(prompt)
        """
    }

    /// System-prompt convention for CLIs that accept one at launch (claude), so
    /// the delegated prompt itself stays clean — nothing is pasted into the
    /// terminal. Applies for the whole session, hence the scoping caveat.
    static let systemPrompt = """
    You are running inside Hermes Deck, where a teammate agent may delegate a \
    task to you. When you finish a task that was delegated to you, return the \
    result to that teammate by calling the `deck_reply` tool with your result as \
    the `message` argument — call it exactly once, when the delegated task is \
    complete. Use `deck_delegate_prompt` only when you need to delegate a \
    focused subtask to another Deck target. Do not call `deck_reply` for the \
    user's own direct messages.
    """
}
