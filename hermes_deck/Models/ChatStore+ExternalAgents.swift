import Foundation

/// External CLI agents (codex / claude / gemini): their dedicated threads,
/// send entry points, and per-thread working directories.
extension ChatStore {
    /// Working directory for an agent thread: an explicit in-session override,
    /// else the last value persisted for that backend (claude / codex / gemini),
    /// else the default workspace.
    func agentWorkingDirectory(for threadID: UUID) -> URL {
        if let override = agentWorkingDirectories[threadID] { return override }
        if let key = Self.workdirDefaultsKey(for: threadBackends[threadID]),
           let path = UserDefaults.standard.string(forKey: key) {
            return URL(fileURLWithPath: path)
        }
        return Self.defaultAgentWorkingDirectory()
    }

    /// UserDefaults key under which a backend's chosen working directory is
    /// persisted across cold starts. `nil` for the main Hermes chat, which is
    /// not backed by a dedicated panel directory.
    private static func workdirDefaultsKey(for backend: AgentBackend?) -> String? {
        switch backend {
        case .acp(let agent): "agentWorkdir.acp.\(agent.rawValue)"
        case .agy: "agentWorkdir.agy"
        case .claudeCLI: "agentWorkdir.claude-cli"
        case .hermes, .none: nil
        }
    }

    /// Default agent working directory: a dedicated, non-TCC-protected folder
    /// (`~/.hermes/workspace`) rather than HOME. Running an agent (codex) in HOME
    /// makes it touch ~/Desktop, ~/Documents, ~/Downloads, … each of which
    /// triggers a separate macOS permission prompt.
    static func defaultAgentWorkingDirectory() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/workspace")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func setAgentWorkingDirectory(_ url: URL, for threadID: UUID) {
        agentWorkingDirectories[threadID] = url
        if let key = Self.workdirDefaultsKey(for: threadBackends[threadID]) {
            UserDefaults.standard.set(url.path(percentEncoded: false), forKey: key)
        }
    }

    /// Finds or creates the chat thread bound to an ACP agent and tags it with
    /// the `.acp` backend so sends route to that agent.
    @discardableResult
    func acpThread(for agent: ACPAgent) -> UUID {
        let profile = HermesProfile(id: "acp:\(agent.rawValue)", displayName: agent.displayName)
        if let thread = threads.first(where: { $0.profile.id == profile.id }) {
            threadBackends[thread.id] = .acp(agent)
            return thread.id
        }
        let thread = ChatThread(title: agent.displayName, profile: profile)
        threads.insert(thread, at: 0)
        threadBackends[thread.id] = .acp(agent)
        return thread.id
    }

    /// Boots the ACP agent ahead of the first prompt so its startup latency is
    /// hidden behind the user opening the panel and typing.
    func prewarmACP(_ agent: ACPAgent) async {
        await agentClient.warmUp(backend: .acp(agent))
    }

    func sendToACP(_ rawText: String, agent: ACPAgent, threadID: UUID) async {
        threadBackends[threadID] = .acp(agent)
        let profile = thread(id: threadID)?.profile ?? HermesProfile(id: "acp:\(agent.rawValue)", displayName: agent.displayName)
        await send(rawText, in: threadID, profile: profile)
    }

    /// Finds or creates the chat thread bound to the Antigravity (`agy`) CLI.
    @discardableResult
    func agyThread() -> UUID {
        let profile = HermesProfile(id: "agy", displayName: "Gemini")
        if let thread = threads.first(where: { $0.profile.id == profile.id }) {
            threadBackends[thread.id] = .agy
            return thread.id
        }
        let thread = ChatThread(title: profile.displayName, profile: profile)
        threads.insert(thread, at: 0)
        threadBackends[thread.id] = .agy
        return thread.id
    }

    func sendToAgy(_ rawText: String, threadID: UUID) async {
        threadBackends[threadID] = .agy
        let profile = thread(id: threadID)?.profile ?? HermesProfile(id: "agy", displayName: "Gemini")
        await send(rawText, in: threadID, profile: profile)
    }

    /// Finds or creates the chat thread bound to the local `claude` CLI backend.
    @discardableResult
    func claudeCLIThread() -> UUID {
        let profile = HermesProfile(id: "claude-cli", displayName: "Claude Code")
        if let thread = threads.first(where: { $0.profile.id == profile.id }) {
            threadBackends[thread.id] = .claudeCLI
            return thread.id
        }
        let thread = ChatThread(title: profile.displayName, profile: profile)
        threads.insert(thread, at: 0)
        threadBackends[thread.id] = .claudeCLI
        return thread.id
    }

    func sendToClaudeCLI(_ rawText: String, threadID: UUID) async {
        threadBackends[threadID] = .claudeCLI
        let profile = thread(id: threadID)?.profile ?? HermesProfile(id: "claude-cli", displayName: "Claude Code")
        await send(rawText, in: threadID, profile: profile)
    }
}
