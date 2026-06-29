import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ChatStore {
    var threads: [ChatThread]
    var selectedThreadID: UUID?
    var selectedProfile: HermesProfile
    var availableProfiles: [HermesProfile]
    var sendState: ChatSendState = .idle
    var agentSendStates: [UUID: ChatSendState] = [:]
    /// True while any thread (main or agent) is still streaming a reply. Used to
    /// lock profile switching until the agent finishes responding.
    var isResponding: Bool {
        sendState == .sending || agentSendStates.values.contains(.sending)
    }
    var pendingAttachments: [Attachment] = []
    var agentPendingAttachments: [UUID: [Attachment]] = [:]
    var pendingPermissionRequest: PermissionRequest?
    var agentPendingPermissionRequests: [UUID: PermissionRequest] = [:]
    var pendingClarificationRequest: ClarificationRequest?
    var agentPendingClarificationRequests: [UUID: ClarificationRequest] = [:]
    var taskSubagents: [SubagentProgress] = []
    var activeTaskThreadID: UUID?
    var sessionInfo = HermesSessionInfo()
    var agentSessionInfos: [UUID: HermesSessionInfo] = [:]
    /// Per-agent-thread working directory overrides (codex/claude/agy). Defaults
    /// to the running Hermes session's cwd.
    var agentWorkingDirectories: [UUID: URL] = [:]
    /// Hermes gateway slash commands for the main composer's `/` popup (ignored
    /// ones excluded). Loaded per selected profile.
    var hermesSlashCommands: [SlashCommand] = []
    var latestAgentRouteRequest: AgentRouteRequest?
    /// Set when a `@codex` / `@claude` / `@gemini` mention routes from the main
    /// chat; the right sidebar opens the matching external-agent panel.
    var pendingExternalAgentPanel: AgentBackend?
    var sessionListState: HermesSessionListState = .idle
    /// Recent sessions for the selected profile, shown in the sidebar History.
    var historySessions: [HermesSessionListItem] = []
    var modelListState: HermesModelListState = .idle
    var toolListState: HermesToolListState = .idle
    var deckDelegationToolInstallState: DeckDelegationToolInstallState = .idle
    var deckDelegationToolStatus: DeckDelegationToolStatus = .missing
    var skillListState: HermesSkillListState = .idle
    var jobListState: HermesJobListState = .idle
    var kanbanListState: HermesKanbanListState = .idle
    var profileMainModels: [String: String] = [:]
    var profileGatewayRunning: [String: Bool] = [:]
    var startingGatewayProfiles: Set<String> = []
    var canLoadMoreSessions = false
    var isLoadingMoreSessions = false
    /// Whether the hermes backend CLI is installed. Drives the "not installed"
    /// placeholder in the main chat area. Optimistic default avoids a flash.
    var hermesInstalled = true

    let agentClient: any HermesAgentClient
    let profileProvider: any HermesProfileProvider
    let sessionProvider: any HermesSessionProvider
    let modelConfigurationProvider: any HermesModelConfigurationProvider
    let pluginProvider: any HermesPluginProvider
    let skillProvider: any HermesSkillProvider
    let jobProvider: any HermesJobProvider
    let kanbanProvider: any HermesKanbanProvider
    let gatewayProvider: any HermesGatewayProvider
    let sessionPageSize: Int
    var sessionLoadGeneration = 0
    var historyThreadIDs: Set<UUID> = []
    var threadBackends: [UUID: AgentBackend] = [:]
    /// In-flight composer send tasks keyed by agent thread (nil = main chat).
    /// Owned here rather than as composer view @State: the empty→non-empty
    /// thread transition recreates the composer view, which would drop a
    /// view-local task and leave the Stop button with nothing to cancel.
    @ObservationIgnored var activeSendTasks: [UUID?: Task<Void, Never>] = [:]
    /// Threads with a turn currently submitted to their gateway session. The
    /// gateway rejects concurrent prompts on one session ("session busy"), so
    /// the send pipeline serializes per thread on this set.
    @ObservationIgnored var runningTurnThreadIDs: Set<UUID> = []
    /// The latest hand-off per source thread, driving the waiting/replied
    /// status cards under the triggering bubble.
    var threadHandoffs: [UUID: AgentHandoffBatch] = [:]
    /// External CLI agent profile ids whose launcher isn't on PATH. Drives the
    /// greyed-out state in mention autocomplete; refreshed off the main actor.
    var unavailableExternalAgentProfileIDs: Set<String> = []
    var sessionSearchQuery = ""
    @ObservationIgnored var externalAgentPanelPromptSender: ((AgentBackend, UUID, String) async -> Bool)?
    /// Who delegated into each CLI panel, so the panel's `deck-reply` can close
    /// the loop back to them. Keyed by the panel's thread id.
    @ObservationIgnored var panelReplyBindings: [String: PanelReplyBinding] = [:]

    var selectedThread: ChatThread? {
        get {
            guard let selectedThreadID else { return nil }
            return threads.first { $0.id == selectedThreadID }
        }
        set {
            guard let newValue, let index = threads.firstIndex(where: { $0.id == newValue.id }) else { return }
            threads[index] = newValue
        }
    }

    var agentProfiles: [HermesProfile] {
        availableProfiles.filter { profile in
            profile.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "default"
        }
    }

    /// Hermes profiles addressable via `@mention`: the agent profiles plus the
    /// main Hermes agent (`default`), which has no side panel but can still be
    /// routed to — its thread is the main chat.
    var mentionableProfiles: [HermesProfile] {
        let defaultProfile = availableProfiles.first {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "default"
        } ?? .defaultProfile
        return agentProfiles + [defaultProfile]
    }

    /// Running subagents — drives the Task rail-icon badge.
    var runningSubagentCount: Int {
        taskSubagents.filter { $0.status == .running }.count
    }

    /// Kanban tasks in an active column (scheduled → review) — drives the Kanban
    /// rail-icon badge.
    var activeKanbanTaskCount: Int {
        let active: Set<KanbanStatus> = [.scheduled, .ready, .running, .blocked, .review]
        return kanbanListState.tasks.filter { task in
            guard let status = task.kanbanStatus else { return false }
            return active.contains(status)
        }.count
    }

    /// External (non-Hermes) agents reachable from the main chat via `@alias`.
    /// Profile ids/backends mirror the dedicated agent panels so a routed thread
    /// is shared with its panel.
    func thread(id: UUID?) -> ChatThread? {
        guard let id else { return nil }
        return threads.first { $0.id == id }
    }

    init(
        agentClient: any HermesAgentClient,
        profileProvider: (any HermesProfileProvider)? = nil,
        sessionProvider: (any HermesSessionProvider)? = nil,
        modelConfigurationProvider: (any HermesModelConfigurationProvider)? = nil,
        pluginProvider: (any HermesPluginProvider)? = nil,
        skillProvider: (any HermesSkillProvider)? = nil,
        jobProvider: (any HermesJobProvider)? = nil,
        kanbanProvider: (any HermesKanbanProvider)? = nil,
        gatewayProvider: (any HermesGatewayProvider)? = nil,
        sessionPageSize: Int = 100,
        threads: [ChatThread] = [],
        externalAgentPanelPromptSender: ((AgentBackend, UUID, String) async -> Bool)? = nil
    ) {
        // Providers are constructed here (in this @MainActor init body) rather
        // than as default arguments: the actor-backed providers are main-actor
        // isolated under the project's default-isolation setting, and default
        // arguments evaluate in a nonisolated context, which would warn.
        self.agentClient = agentClient
        self.profileProvider = profileProvider ?? LocalHermesProfileProvider()
        self.sessionProvider = sessionProvider ?? LocalHermesSessionProvider()
        self.modelConfigurationProvider = modelConfigurationProvider ?? LocalHermesModelConfigurationProvider()
        self.pluginProvider = pluginProvider ?? LocalHermesPluginProvider()
        self.skillProvider = skillProvider ?? LocalHermesSkillProvider()
        self.jobProvider = jobProvider ?? LocalHermesJobProvider()
        self.kanbanProvider = kanbanProvider ?? LocalHermesKanbanProvider()
        self.gatewayProvider = gatewayProvider ?? LocalHermesGatewayProvider()
        self.sessionPageSize = max(1, sessionPageSize)
        self.externalAgentPanelPromptSender = externalAgentPanelPromptSender
        self.selectedProfile = .defaultProfile
        self.availableProfiles = HermesProfile.presets
        self.threads = threads.isEmpty ? [ChatThread(title: "New Chat")] : threads
        self.selectedThreadID = self.threads.first?.id
    }

    func createThread(title: String = "New Chat") {
        let thread = ChatThread(title: title, profile: selectedProfile)
        threads.insert(thread, at: 0)
        selectedThreadID = thread.id
    }

    func openAgentProfile(_ profile: HermesProfile) {
        selectedProfile = profile
        if let thread = threads.first(where: { $0.profile.id == profile.id }) {
            selectedThreadID = thread.id
            return
        }

        let thread = ChatThread(title: profile.displayName, profile: profile)
        threads.insert(thread, at: 0)
        selectedThreadID = thread.id
    }

    @discardableResult
    func threadIDForAgentProfile(_ profile: HermesProfile) -> UUID {
        if let thread = threads.first(where: { $0.profile.id == profile.id }) {
            return thread.id
        }

        let thread = ChatThread(title: profile.displayName, profile: profile)
        threads.insert(thread, at: 0)
        return thread.id
    }

    func select(_ thread: ChatThread) {
        selectedThreadID = thread.id
        selectedProfile = thread.profile
    }

    func setProfile(_ profile: HermesProfile) {
        selectedProfile = profile
    }

    /// Switches the active profile and starts a fresh chat session under it. Used
    /// when the user changes profile while on the chat page.
    func setProfileStartingNewThread(_ profile: HermesProfile) {
        selectedProfile = profile
        createThread()
    }

    func filteredThreads(query: String) -> [ChatThread] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return threads }
        return threads.filter { thread in
            thread.title.localizedCaseInsensitiveContains(trimmed)
                || thread.messages.contains { $0.content.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    func historyThreads(query: String) -> [ChatThread] {
        let historyThreads = threads.filter { historyThreadIDs.contains($0.id) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return historyThreads }
        return historyThreads.filter { thread in
            thread.title.localizedCaseInsensitiveContains(trimmed)
                || thread.messages.contains { $0.content.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    func mutateSelectedThread(_ update: (inout ChatThread) -> Void) {
        guard let selectedThreadID, let index = threads.firstIndex(where: { $0.id == selectedThreadID }) else { return }
        update(&threads[index])
    }

    func mutateThread(id threadID: UUID, _ update: (inout ChatThread) -> Void) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        update(&threads[index])
    }

    func title(for text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        return String(oneLine.prefix(44))
    }
}
