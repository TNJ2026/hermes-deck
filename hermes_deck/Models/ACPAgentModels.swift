import Foundation

/// Which backend serves a chat request: the local Hermes gateway (default), an
/// external ACP agent, or the Antigravity (`agy`) CLI.
enum AgentBackend: Equatable, Sendable {
    case hermes
    case acp(ACPAgent)
    case agy
    case claudeCLI
}

/// An external coding agent reachable over the Agent Client Protocol (ACP).
/// Backs the `.codex` right-sidebar panel. (Claude is served by the local
/// `claude` CLI — see `ClaudeCLIClient`; Gemini by the Antigravity `agy` CLI —
/// see `AgyClient`.)
enum ACPAgent: String, CaseIterable, Identifiable, Sendable {
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        }
    }

    /// The launch command for the agent's ACP adapter. `executable` is resolved
    /// through `/usr/bin/env` so the child uses the PATH we build (a GUI app
    /// launched from Finder otherwise has a minimal PATH without node/homebrew).
    nonisolated private var command: (executable: String, arguments: [String]) {
        switch self {
        case .codex:
            // Codex has no native ACP subcommand; the Zed codex-acp adapter
            // wraps the codex CLI and speaks ACP. Needs codex auth (`codex login`).
            ("npx", ["--prefer-offline", "-y", "@zed-industries/codex-acp"])
        }
    }

    nonisolated func launchSpec(
        workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> ACPLaunchSpec {
        let command = command
        return ACPLaunchSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [command.executable] + command.arguments,
            workingDirectory: workingDirectory,
            environment: AgentLaunchEnvironment.make(base: base)
        )
    }

    init?(panelItem: RightPanelItem) {
        switch panelItem {
        case .codex: self = .codex
        default: return nil
        }
    }
}

struct ACPLaunchSpec: Sendable {
    var executableURL: URL
    var arguments: [String]
    var workingDirectory: URL
    var environment: [String: String]

    nonisolated init(executableURL: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

/// Builds the child-process environment for spawned agent CLIs: a PATH that
/// includes the usual node / homebrew / `~/.local/bin` locations, with the
/// nested-session guards stripped so adapters do not refuse to launch when the
/// app itself was started from a Claude Code terminal.
enum AgentLaunchEnvironment {
    nonisolated static func make(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = path(existing: base["PATH"])
        // Marks a CLI agent (codex / gemini / claude) spawned by the Deck, so it
        // can tell it is running inside the Hermes Deck app.
        environment["HERMES_DECK"] = "1"
        return environment
    }

    private static func path(existing: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let preferred = [
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let existingComponents = (existing ?? "").split(separator: ":").map(String.init)
        var seen: Set<String> = []
        return (preferred + existingComponents)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }
}
