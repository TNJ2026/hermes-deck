import Foundation
import Yams

nonisolated struct AgentPromptEnvelope: Equatable, Sendable {
    var text: String
    var attachments: [Attachment]
    var sourceProfileName: String?

    init(text: String, attachments: [Attachment] = [], sourceProfileName: String? = nil) {
        self.text = text
        self.attachments = attachments
        self.sourceProfileName = sourceProfileName
    }

    var renderedText: String {
        var lines: [String] = []
        if let sourceProfileName, !sourceProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("[Forwarded from \(sourceProfileName)]")
        }
        lines.append(contentsOf: attachments.map(Self.attachmentLine))
        lines.append(text)
        return lines.joined(separator: "\n")
    }

    private static func attachmentLine(_ attachment: Attachment) -> String {
        "[User attached file: \(attachment.name) (\(attachment.url.path(percentEncoded: false)))]"
    }
}

nonisolated struct HermesChatRequest: Sendable {
    var conversationID: UUID
    var profile: HermesProfile
    var messages: [ChatMessage]
    var attachments: [Attachment]
    var backend: AgentBackend
    var workingDirectory: URL
    var promptEnvelope: AgentPromptEnvelope?
    /// When set, the Hermes gateway resumes this existing session id on the
    /// first prompt instead of creating a new one (used for history threads).
    var resumeSessionID: String?

    var promptText: String {
        promptEnvelope?.renderedText ?? messages.last?.content ?? ""
    }

    init(
        conversationID: UUID = UUID(),
        profile: HermesProfile,
        messages: [ChatMessage],
        attachments: [Attachment],
        backend: AgentBackend = .hermes,
        promptEnvelope: AgentPromptEnvelope? = nil,
        resumeSessionID: String? = nil
    ) {
        self.init(
            conversationID: conversationID,
            profile: profile,
            messages: messages,
            attachments: attachments,
            backend: backend,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            promptEnvelope: promptEnvelope,
            resumeSessionID: resumeSessionID
        )
    }

    init(
        conversationID: UUID = UUID(),
        profile: HermesProfile,
        messages: [ChatMessage],
        attachments: [Attachment],
        backend: AgentBackend = .hermes,
        workingDirectory: URL,
        promptEnvelope: AgentPromptEnvelope? = nil,
        resumeSessionID: String? = nil
    ) {
        self.conversationID = conversationID
        self.profile = profile
        self.messages = messages
        self.attachments = attachments
        self.backend = backend
        self.workingDirectory = workingDirectory
        self.promptEnvelope = promptEnvelope
        self.resumeSessionID = resumeSessionID
    }
}

nonisolated struct HermesChatResponse: Decodable, Sendable {
    var content: String
}

struct HermesSessionInfo: Equatable, Sendable {
    var model: String?
    var contextLength: Int?
    var usedTokens: Int?
    var cwd: String?

    nonisolated init(model: String? = nil, contextLength: Int? = nil, usedTokens: Int? = nil, cwd: String? = nil) {
        self.model = model
        self.contextLength = contextLength
        self.usedTokens = usedTokens
        self.cwd = cwd
    }

    /// True only once both the model name and context length are known. Used to
    /// decide whether the composer chip should appear at all.
    var hasModelInfo: Bool {
        model?.isEmpty == false && contextLength != nil
    }

    var displayText: String {
        let modelText = model?.isEmpty == false ? model! : "Hermes"
        guard usedTokens != nil || contextLength != nil else {
            return modelText
        }
        let usedText = usedTokens.map(Self.abbreviatedTokenCount) ?? "?"
        let contextText = contextLength.map(Self.abbreviatedTokenCount) ?? "?"
        return "\(modelText) · \(usedText)/\(contextText)"
    }

    mutating func merge(_ info: HermesSessionInfo) {
        model = info.model ?? model
        contextLength = info.contextLength ?? contextLength
        usedTokens = info.usedTokens ?? usedTokens
        cwd = info.cwd ?? cwd
    }

    private static func abbreviatedTokenCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return abbreviated(value, divisor: 1_000_000, suffix: "M")
        }
        if value >= 1_000 {
            return abbreviated(value, divisor: 1_000, suffix: "K")
        }
        return "\(value)"
    }

    private static func abbreviated(_ value: Int, divisor: Int, suffix: String) -> String {
        let scaled = (Double(value) / Double(divisor) * 10).rounded(.toNearestOrAwayFromZero) / 10
        if scaled.rounded() == scaled {
            return "\(Int(scaled))\(suffix)"
        }
        return "\(String(format: "%.1f", scaled))\(suffix)"
    }
}

struct HermesSessionListItem: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var preview: String
    var source: String
    var messageCount: Int
    var lastActive: String
    var lastActiveDate: Date?

    init(
        id: String,
        title: String,
        preview: String = "",
        source: String = "",
        messageCount: Int = 0,
        lastActive: String = "",
        lastActiveDate: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.source = source
        self.messageCount = messageCount
        self.lastActive = lastActive
        self.lastActiveDate = lastActiveDate
    }
}

struct HermesConfiguredModel: Identifiable, Hashable, Sendable {
    var id: String
    var category: String
    var title: String
    var provider: String
    var model: String
    var baseURL: String
    var apiKeyStatus: String

    init(
        id: String,
        category: String,
        title: String,
        provider: String,
        model: String,
        baseURL: String = "",
        apiKeyStatus: String = ""
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.apiKeyStatus = apiKeyStatus
    }
}

struct HermesInstalledPlugin: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var displayName: String
    var version: String
    var source: String
    var category: String
    var developerName: String
    var summary: String
    var capabilities: [String]
    var status: String
    var path: String

    init(
        id: String,
        name: String,
        displayName: String,
        version: String,
        source: String = "",
        category: String = "",
        developerName: String = "",
        summary: String = "",
        capabilities: [String] = [],
        status: String = "",
        path: String = ""
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.version = version
        self.source = source
        self.category = category
        self.developerName = developerName
        self.summary = summary
        self.capabilities = capabilities
        self.status = status
        self.path = path
    }
}

struct HermesInstalledTool: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var displayName: String
    var source: String
    var status: String
    var summary: String

    init(
        id: String,
        name: String,
        displayName: String = "",
        source: String = "",
        status: String = "",
        summary: String = ""
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName.isEmpty ? name : displayName
        self.source = source
        self.status = status
        self.summary = summary
    }
}

struct HermesInstalledSkill: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var category: String
    var source: String
    var trust: String
    var status: String
}

struct SessionPageRequest: Equatable, Sendable {
    var limit: Int
    var offset: Int
    var query: String?

    init(limit: Int, offset: Int, query: String? = nil) {
        self.limit = max(1, limit)
        self.offset = max(0, offset)
        self.query = query
    }
}

struct HermesTokenUsage: Equatable, Sendable {
    var usedTokens: Int?
    var contextLength: Int?
}

enum HermesAgentEvent: Equatable, Sendable {
    case gatewayReady
    case sessionInfo(sessionID: String, info: HermesSessionInfo)
    case messageStart(sessionID: String)
    case messageDelta(sessionID: String, text: String)
    case messageComplete(sessionID: String, text: String, status: String, usage: HermesTokenUsage?)
    case statusUpdate(sessionID: String, text: String)
    case toolStart(sessionID: String, tool: ToolCallEvent)
    case toolGenerating(sessionID: String, tool: ToolCallEvent)
    case toolComplete(sessionID: String, tool: ToolCallEvent)
    case thinkingDelta(sessionID: String, text: String)
    case reasoningDelta(sessionID: String, text: String)
    case reasoningAvailable(sessionID: String, text: String)
    case subagentSpawnRequested(sessionID: String, progress: SubagentProgressEvent)
    case subagentStart(sessionID: String, progress: SubagentProgressEvent)
    case subagentThinking(sessionID: String, progress: SubagentProgressEvent)
    case subagentTool(sessionID: String, progress: SubagentProgressEvent)
    case subagentProgress(sessionID: String, progress: SubagentProgressEvent)
    case subagentComplete(sessionID: String, progress: SubagentProgressEvent)
    case approvalRequest(sessionID: String, requestID: String?, text: String, options: [PermissionOption])
    case clarifyRequest(sessionID: String, question: String, choices: [String])
    case error(sessionID: String?, message: String)
}

protocol HermesAgentClient: Sendable {
    func send(_ request: HermesChatRequest) async throws -> HermesChatResponse
    func eventStream(for request: HermesChatRequest) -> AsyncThrowingStream<HermesAgentEvent, Error>
    /// Answers a permission request the agent raised mid-turn. Default no-op for
    /// clients whose approval flow is display-only (e.g. the Hermes gateway).
    func respondToPermission(requestID: String, optionID: String) async
    /// Optionally boots a backend ahead of the first prompt. Default no-op.
    func warmUp(backend: AgentBackend) async
    /// Executes a Hermes `/slash` command and returns its text output. Default
    /// throws for backends without slash support.
    func slashExec(_ command: String, for request: HermesChatRequest) async throws -> String
    /// The agent's available slash commands. Default empty.
    func commandsCatalog(for profile: HermesProfile) async throws -> [SlashCommand]
    /// Tears down any long-lived child processes on app quit. Default no-op.
    func shutdown() async
}

protocol HermesProfileProvider: Sendable {
    func profiles() async throws -> [HermesProfile]
}

protocol HermesSessionProvider: Sendable {
    func sessions(page: SessionPageRequest) async throws -> [HermesSessionListItem]
    func sessionThread(id: String) async throws -> ChatThread
    func deleteSession(id: String) async throws
    func sessions(page: SessionPageRequest, profile: HermesProfile) async throws -> [HermesSessionListItem]
    func sessionThread(id: String, profile: HermesProfile) async throws -> ChatThread
    func deleteSession(id: String, profile: HermesProfile) async throws
}

/// Default profile-aware variants delegate to the non-profile methods, so
/// existing conformers (e.g. test stubs) keep working unchanged. Profile-aware
/// providers override these to scope by the profile's HERMES_HOME.
extension HermesSessionProvider {
    func sessions(page: SessionPageRequest, profile: HermesProfile) async throws -> [HermesSessionListItem] {
        try await sessions(page: page)
    }
    func sessionThread(id: String, profile: HermesProfile) async throws -> ChatThread {
        try await sessionThread(id: id)
    }
    func deleteSession(id: String, profile: HermesProfile) async throws {
        try await deleteSession(id: id)
    }
}

protocol HermesModelConfigurationProvider: Sendable {
    func configuredModels() async throws -> [HermesConfiguredModel]
}

protocol HermesPluginProvider: Sendable {
    func installedPlugins() async throws -> [HermesInstalledPlugin]
    func installedTools() async throws -> [HermesInstalledTool]
    func setPlugin(_ name: String, enabled: Bool) async throws
    func setTool(_ name: String, enabled: Bool) async throws
    func installedTools(profile: HermesProfile) async throws -> [HermesInstalledTool]
    func setTool(_ name: String, enabled: Bool, profile: HermesProfile) async throws
}

extension HermesPluginProvider {
    func installedTools(profile: HermesProfile) async throws -> [HermesInstalledTool] {
        try await installedTools()
    }
    func setTool(_ name: String, enabled: Bool, profile: HermesProfile) async throws {
        try await setTool(name, enabled: enabled)
    }
}

protocol HermesSkillProvider: Sendable {
    func installedSkills() async throws -> [HermesInstalledSkill]
    func setSkill(_ name: String, enabled: Bool) async throws
    func installedSkills(profile: HermesProfile) async throws -> [HermesInstalledSkill]
    func setSkill(_ name: String, enabled: Bool, profile: HermesProfile) async throws
}

extension HermesSkillProvider {
    func installedSkills(profile: HermesProfile) async throws -> [HermesInstalledSkill] {
        try await installedSkills()
    }
    func setSkill(_ name: String, enabled: Bool, profile: HermesProfile) async throws {
        try await setSkill(name, enabled: enabled)
    }
}

enum HermesJobAction: String, Sendable {
    case pause
    case resume
    case run
    case remove
}

struct HermesJobEdit: Sendable {
    var jobID: String
    var name: String?
    var schedule: String?
    var prompt: String?
    var deliver: String?
    var script: String?
    var skills: [String]?
}

protocol HermesJobProvider: Sendable {
    func jobs(for profile: HermesProfile) async throws -> [HermesScheduledJob]
    func performJobAction(_ action: HermesJobAction, jobID: String, profile: HermesProfile) async throws
    func updateJob(_ edit: HermesJobEdit, profile: HermesProfile) async throws
}

extension HermesJobProvider {
    func performJobAction(_ action: HermesJobAction, jobID: String, profile: HermesProfile) async throws {}
    func updateJob(_ edit: HermesJobEdit, profile: HermesProfile) async throws {}
}

extension HermesAgentClient {
    func respondToPermission(requestID: String, optionID: String) async {}

    func warmUp(backend: AgentBackend) async {}

    func shutdown() async {}

    func slashExec(_ command: String, for request: HermesChatRequest) async throws -> String {
        throw HermesAgentError.rpcError("Slash commands are not supported for this agent.")
    }

    func commandsCatalog(for profile: HermesProfile) async throws -> [SlashCommand] { [] }

    func eventStream(for request: HermesChatRequest) -> AsyncThrowingStream<HermesAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await send(request)
                    continuation.yield(.messageStart(sessionID: request.conversationID.uuidString))
                    continuation.yield(.messageComplete(sessionID: request.conversationID.uuidString, text: response.content, status: "complete", usage: nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum HermesAgentError: LocalizedError {
    case invalidResponse
    case gatewayNotReady
    case gatewayExited
    case missingSession
    case rpcError(String)
    case commandNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "HermesAgent returned an invalid response."
        case .gatewayNotReady:
            "Hermes TUI gateway is not ready."
        case .gatewayExited:
            "Hermes TUI gateway exited."
        case .missingSession:
            "Hermes TUI gateway did not return a session."
        case .rpcError(let message):
            message
        case .commandNotFound(let name):
            "The “\(name)” command wasn't found. Make sure Hermes is installed."
        }
    }
}

extension HermesAgentError {
    /// True when `error` (or a nested underlying error) indicates the executable
    /// could not be found — i.e. the command isn't installed / not on disk.
    static func isMissingExecutable(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isMissingExecutable(underlying)
        }
        return false
    }
}

extension Process {
    /// Runs the process, translating a "missing executable" failure into a
    /// friendly `HermesAgentError.commandNotFound(name)` rather than surfacing a
    /// raw POSIX/Cocoa file-not-found error to the user.
    func runTranslatingMissingCommand(named name: String) throws {
        do {
            try run()
        } catch {
            if HermesAgentError.isMissingExecutable(error) {
                throw HermesAgentError.commandNotFound(name)
            }
            throw error
        }
    }
}
