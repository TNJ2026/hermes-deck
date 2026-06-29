import Foundation

/// `@mention` routing: alias resolution, prompt fan-out to mentioned
/// agents, and single-hop forwarding of addressed agent replies.
extension ChatStore {
    func startDeckRoutingIPC() {
        do {
            try DeckRoutingIPCServer.shared.start { [self] request in
                await MainActor.run {
                    return self.handleDeckRoutingIPCRequest(request)
                }
            }
        } catch {
            if let selectedThreadID {
                append(ChatMessage(role: .system, content: "Deck routing IPC failed to start: \(error.localizedDescription)"), to: selectedThreadID)
            }
        }
    }

    func handleDeckRoutingIPCRequest(_ request: DeckRoutingIPCRequest) -> DeckRoutingIPCResponse {
        if request.type == "reply" {
            return handleDeckPanelReply(request)
        }
        let sessionKey = request.sourceSessionKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sessionKey.isEmpty else {
            return DeckRoutingIPCResponse(ok: false, status: nil, error: "Missing source_session_key")
        }
        guard let sourceThread = deckRoutingSourceThread(for: request, sessionKey: sessionKey) else {
            return DeckRoutingIPCResponse(ok: false, status: nil, error: "No Deck thread is bound to source_session_key \(sessionKey)")
        }
        var target = (request.target ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if target.hasPrefix("@") {
            target.removeFirst()
        }
        let prompt = (request.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !prompt.isEmpty else {
            return DeckRoutingIPCResponse(ok: false, status: nil, error: "Both target and prompt are required")
        }

        let routedText = "@\(target)\n\(prompt)"
        let visibleRoutingBlock = """
        ```\(AgentMentionRouteParser.routingFenceInfo)
        \(routedText)
        ```
        """
        append(
            ChatMessage(role: .assistant, content: visibleRoutingBlock, completedAt: .now),
            to: sourceThread.id
        )
        Task { @MainActor [self] in
            let result = await routePromptIfAllowed(
                routedText,
                from: .hermes(profile: sourceThread.profile),
                sourceThreadID: sourceThread.id,
                appendUserMessage: false,
                closesLoopToSource: true
            )
            if case .denied(let reason) = result {
                append(ChatMessage(role: .system, content: "Deck delegation tool could not route: \(reason)."), to: sourceThread.id)
            } else if result == .notMention {
                append(ChatMessage(role: .system, content: "Deck delegation tool could not route to @\(target)."), to: sourceThread.id)
            }
        }

        return DeckRoutingIPCResponse(ok: true, status: "queued", error: nil)
    }

    /// Handles a panel CLI's `deck-reply`: looks up who delegated into that
    /// panel and feeds the result back to them as a close-the-loop follow-up.
    private func handleDeckPanelReply(_ request: DeckRoutingIPCRequest) -> DeckRoutingIPCResponse {
        let session = request.session?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !session.isEmpty else {
            return DeckRoutingIPCResponse(ok: false, status: nil, error: "Missing panel session")
        }
        guard let base64 = request.messageB64,
              let data = Data(base64Encoded: base64),
              let decoded = String(data: data, encoding: .utf8) else {
            return DeckRoutingIPCResponse(ok: false, status: nil, error: "Invalid reply message")
        }
        let message = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return DeckRoutingIPCResponse(ok: false, status: nil, error: "Empty reply message")
        }
        guard let binding = panelReplyBindings[session] else {
            return DeckRoutingIPCResponse(ok: false, status: nil, error: "No pending delegation is bound to this panel session")
        }
        panelReplyBindings[session] = nil
        panelReplyTimeouts[session]?.cancel()
        panelReplyTimeouts[session] = nil

        setHandoffPhase(.replied(message), itemID: binding.handoffItemID, in: binding.sourceThreadID)
        Task { @MainActor [self] in
            let framed = AgentReplyFraming.framed([(name: binding.targetName, reply: message)])
            _ = await send(framed, in: binding.sourceThreadID, profile: binding.sourceProfile, isAgentReplyFollowUp: true)
        }
        return DeckRoutingIPCResponse(ok: true, status: "delivered", error: nil)
    }

    /// Records who delegated into a panel so its `deck-reply` can close the loop
    /// back to them. Keyed by the panel's thread id (its session key).
    func recordPanelReplyBinding(panelThreadID: UUID, sourceThreadID: UUID, sourceProfile: HermesProfile, handoffItemID: UUID, targetName: String) {
        let key = panelThreadID.uuidString
        panelReplyBindings[key] = PanelReplyBinding(
            sourceThreadID: sourceThreadID,
            sourceProfile: sourceProfile,
            handoffItemID: handoffItemID,
            targetName: targetName
        )
        // Fail the hand-off if the panel never returns a result.
        panelReplyTimeouts[key]?.cancel()
        let timeout = panelReplyTimeout
        panelReplyTimeouts[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.expirePanelReplyBinding(key)
        }
    }

    private func expirePanelReplyBinding(_ key: String) {
        panelReplyTimeouts[key] = nil
        guard let binding = panelReplyBindings[key] else { return }
        panelReplyBindings[key] = nil
        setHandoffPhase(.failed, itemID: binding.handoffItemID, in: binding.sourceThreadID)
    }

    private func deckRoutingSourceThread(for request: DeckRoutingIPCRequest, sessionKey: String) -> ChatThread? {
        if let sourceThread = threads.first(where: { $0.hermesSessionID == sessionKey }) {
            return sourceThread
        }

        let profileID = request.sourceProfileID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !profileID.isEmpty else { return nil }

        let candidates = threads.filter {
            $0.profile.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == profileID
        }
        let sourceThread: ChatThread?
        if let selectedThreadID,
           let selected = candidates.first(where: { $0.id == selectedThreadID }) {
            sourceThread = selected
        } else if candidates.count == 1 {
            sourceThread = candidates[0]
        } else {
            sourceThread = candidates.last
        }

        if let sourceThread,
           let index = threads.firstIndex(where: { $0.id == sourceThread.id }) {
            threads[index].hermesSessionID = sessionKey
        }
        return sourceThread
    }

    var externalAgentMentionTargets: [ExternalAgentMentionTarget] {
        [
            ExternalAgentMentionTarget(
                aliases: ["codex"],
                profile: HermesProfile(id: "acp:codex", displayName: ACPAgent.codex.displayName),
                backend: .acp(.codex),
                probeCommand: "npx"
            ),
            ExternalAgentMentionTarget(
                aliases: ["claude", "claude-code", "claudecode"],
                profile: HermesProfile(id: "claude-cli", displayName: "Claude Code"),
                backend: .claudeCLI,
                probeCommand: "claude"
            ),
            ExternalAgentMentionTarget(
                aliases: ["gemini", "antigravity", "agy"],
                profile: HermesProfile(id: "agy", displayName: "Gemini"),
                backend: .agy,
                probeCommand: "agy"
            ),
        ]
    }

    /// Profile ids of external CLI agents whose launcher isn't on PATH. The
    /// mention autocomplete greys these out. Cached so the lookup doesn't run
    /// on every keystroke; refreshed by `refreshExternalAgentAvailability()`.
    func isExternalAgentUnavailable(_ profileID: String) -> Bool {
        unavailableExternalAgentProfileIDs.contains(profileID)
    }

    /// Re-probes each external CLI's launcher (filesystem only, off the main
    /// actor) and updates the cached unavailable set.
    func refreshExternalAgentAvailability() async {
        let targets = externalAgentMentionTargets
        let unavailable: Set<String> = await Task.detached(priority: .utility) {
            var result: Set<String> = []
            for target in targets where !AgentLaunchEnvironment.isCommandAvailable(target.probeCommand) {
                result.insert(target.profile.id)
            }
            return result
        }.value
        unavailableExternalAgentProfileIDs = unavailable
    }

    /// All `@mention` routes in `text`: each mentioned agent (external targets
    /// first, then Hermes profiles) paired with the prompt segment that follows
    /// its mention. One composed message fans out to every @-mentioned agent,
    /// each receiving only the text after its own mention.
    /// The router's alias table: external CLI groups first, then every
    /// mentionable Hermes profile (id + display name).
    private func mentionRouteGroups() -> [(aliases: [String], target: AgentRouteTarget, isExternal: Bool)] {
        var groups: [(aliases: [String], target: AgentRouteTarget, isExternal: Bool)] = []
        for target in externalAgentMentionTargets {
            groups.append((target.aliases, AgentRouteTarget(profile: target.profile, backend: target.backend), true))
        }
        for profile in mentionableProfiles {
            let aliases = [profile.id, profile.displayName]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            groups.append((aliases, AgentRouteTarget(profile: profile, backend: .hermes), false))
        }
        return groups
    }

    private func resolvedMentionRoutes(
        for text: String,
        codeBlockOnly: Bool = false
    ) -> [(target: AgentRouteTarget, message: String, isExternal: Bool)] {
        let groups = mentionRouteGroups()
        let spans: [(groupIndex: Int, message: String)] = codeBlockOnly
            ? AgentMentionRouteParser.codeBlockRouteSpans(in: text, aliasGroups: groups.map(\.aliases))
                .map { ($0.groupIndex, $0.message) }
            : AgentMentionRouteParser.routeSpans(in: text, aliasGroups: groups.map(\.aliases))
        var seenTargets = Set<String>()
        return spans.compactMap { span in
            guard span.groupIndex < groups.count else { return nil }
            let group = groups[span.groupIndex]
            guard !span.message.isEmpty else { return nil }
            // One agent can only be addressed once per message; later duplicate
            // mentions of the same target would race on its shared thread.
            guard seenTargets.insert(group.target.profile.id).inserted else { return nil }
            return (group.target, span.message, group.isExternal)
        }
    }

    /// The routing primer seeded into a new gateway session for `profile`:
    /// every other mentionable Hermes profile plus the external CLIs, by their
    /// primary alias. `nil` when there is nothing to route to.
    func routingPrimer(for profile: HermesProfile) -> String? {
        let selfID = profile.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let profileAliases = mentionableProfiles
            .map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != selfID }
        let cliAliases = externalAgentMentionTargets.compactMap(\.aliases.first)
        return AgentRoutingPrimer.text(targets: profileAliases + cliAliases)
    }

    private func setHandoffPhase(_ phase: AgentHandoffItem.Phase, itemID: UUID, in threadID: UUID) {
        guard var batch = threadHandoffs[threadID],
              let index = batch.items.firstIndex(where: { $0.id == itemID }) else { return }
        batch.items[index].phase = phase
        threadHandoffs[threadID] = batch
    }

    private func removeHandoffItem(_ itemID: UUID, in threadID: UUID) {
        guard var batch = threadHandoffs[threadID] else { return }
        batch.items.removeAll { $0.id == itemID }
        threadHandoffs[threadID] = batch.items.isEmpty ? nil : batch
    }

    /// Marks the source thread of an in-flight hand-off as busy/idle — on the
    /// per-thread track only. Touching the global track here leaked: release
    /// checked the *current* selection, so switching threads mid-hand-off left
    /// the global state stuck at .sending. The main composer merges this
    /// track in via `ChatDetailView.composerSendState` instead.
    private func setRouteWaitState(_ state: ChatSendState, for sourceThreadID: UUID) {
        agentSendStates[sourceThreadID] = state
    }

    /// Every alias the router recognizes, flattened. The Markdown renderer uses
    /// it (via the environment) to show an AgentRouting block as a forwarding
    /// card only when the block would actually route.
    var routingMentionAliases: [String] {
        var aliases = externalAgentMentionTargets.flatMap(\.aliases)
        for profile in mentionableProfiles {
            aliases.append(profile.id)
            aliases.append(profile.displayName)
        }
        return aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Whether `text` mentions a forwardable agent (external or Hermes profile).
    func hasMentionRoute(_ text: String, codeBlockOnly: Bool = false) -> Bool {
        !resolvedMentionRoutes(for: text, codeBlockOnly: codeBlockOnly).isEmpty
    }

    /// Forwards an `@mention` prompt to its target agent when the source is
    /// allowed to route. Hermes profiles can route to Hermes and external
    /// agents; external agents cannot route to any other agent and should treat
    /// denied prompts as ordinary messages to their current backend.
    @discardableResult
    func routePromptIfAllowed(
        _ text: String,
        from source: PromptRouteSource,
        sourceThreadID: UUID,
        notifiesPanel: Bool = true,
        appendUserMessage: Bool = true,
        closesLoopToSource: Bool = false,
        codeBlockOnly: Bool = false
    ) async -> PromptRouteResult {
        let allRoutes = resolvedMentionRoutes(for: text, codeBlockOnly: codeBlockOnly)
        guard !allRoutes.isEmpty else { return .notMention }
        guard case .hermes(let sourceProfile) = source else { return .denied(.externalSourceCannotRoute) }
        // A route whose target thread is the source thread itself (e.g.
        // `@default` typed in the main chat, or a profile mentioning itself)
        // would loop back into the same thread; treat it as plain text instead.
        let selfFiltered = allRoutes.filter { threadIDForAgentProfile($0.target.profile) != sourceThreadID }
        guard !selfFiltered.isEmpty else { return .notMention }

        // Drop external targets whose launcher isn't installed (re-probed now,
        // not the cached autocomplete state) — fanning out to them only fails
        // after the fact with a "session busy"-style error. A skipped notice
        // goes into the source thread instead.
        await refreshExternalAgentAvailability()
        var skippedNames: [String] = []
        let routes = selfFiltered.filter { route in
            guard route.isExternal, !closesLoopToSource, isExternalAgentUnavailable(route.target.profile.id) else { return true }
            skippedNames.append(route.target.profile.displayName)
            return false
        }

        let sourceAttachments = takePendingAttachmentsForRoute(from: sourceThreadID)
        if appendUserMessage {
            append(ChatMessage(role: .user, content: text, attachments: sourceAttachments), to: sourceThreadID)
        }
        historyThreadIDs.insert(sourceThreadID)
        for name in skippedNames {
            append(ChatMessage(role: .system, content: "⚠️ \(name) is not installed — not routed."), to: sourceThreadID)
        }
        // Every target was unavailable: the notice is shown; do not fall through
        // to sending the raw "@target …" text as an ordinary prompt.
        guard !routes.isEmpty else { return .routed }
        let sourceName = source.displayName

        // The source thread is busy for the whole hand-off — fan-out, waiting
        // on the targets, and the close-the-loop follow-up. Its composer shows
        // the sending state (Stop enabled, no new prompt) instead of silently
        // accepting input that would queue behind the routed replies.
        setRouteWaitState(.sending, for: sourceThreadID)
        defer { setRouteWaitState(.idle, for: sourceThreadID) }

        // Status cards under the triggering bubble: one waiting row per target,
        // flipped to replied/failed as results land. A new hand-off replaces
        // the thread's previous batch.
        let handoffItems = routes.map {
            AgentHandoffItem(id: UUID(), targetName: $0.target.profile.displayName, phase: .waiting)
        }
        threadHandoffs[sourceThreadID] = AgentHandoffBatch(
            anchorMessageID: thread(id: sourceThreadID)?.messages.last?.id,
            items: handoffItems
        )

        // Fan out in parallel: each @mentioned agent gets the segment after its
        // mention, echoes its reply back into the source thread, and (for replies
        // that opt in) returns it for the close-the-loop follow-up below.
        let replies = await withTaskGroup(of: Optional<(name: String, reply: String)>.self) { group in
            for (offset, route) in routes.enumerated() {
                let handoffItemID = handoffItems[offset].id
                let agentThreadID = threadIDForAgentProfile(route.target.profile)
                threadBackends[agentThreadID] = route.target.backend
                // Attachments ride along with the first mention only.
                if offset == 0, !sourceAttachments.isEmpty {
                    agentPendingAttachments[agentThreadID, default: []].append(contentsOf: sourceAttachments)
                }
                if notifiesPanel {
                    if route.isExternal {
                        pendingExternalAgentPanel = route.target.backend
                    } else {
                        latestAgentRouteRequest = AgentRouteRequest(
                            profile: route.target.profile,
                            threadID: agentThreadID,
                            sourceThreadID: sourceThreadID
                        )
                    }
                }

                let message = route.message
                let profile = route.target.profile
                let isExternal = route.isExternal
                let backend = route.target.backend
                group.addTask { @MainActor [self] in
                    // Stagger external agents' first launch: booting several
                    // npx/node/CLI adapters at once spikes CPU/IO and janks the
                    // UI. A short offset spreads the cold-start cost.
                    if isExternal, offset > 0 {
                        try? await Task.sleep(for: .milliseconds(offset * 300))
                    }
                    if isExternal, closesLoopToSource {
                        // Forward into the live panel CLI, primed to return its
                        // result via `deck-reply`. The hand-off stays waiting and
                        // is closed asynchronously when that reply arrives, so we
                        // don't contribute a synchronous close-the-loop entry.
                        let primed = DeckReplyPrimer.wrap(message)
                        let sent = await sendPromptToExternalAgentPanel(primed, backend: backend, threadID: agentThreadID)
                        if sent {
                            recordPanelReplyBinding(
                                panelThreadID: agentThreadID,
                                sourceThreadID: sourceThreadID,
                                sourceProfile: sourceProfile,
                                handoffItemID: handoffItemID,
                                targetName: profile.displayName
                            )
                        } else {
                            setHandoffPhase(.failed, itemID: handoffItemID, in: sourceThreadID)
                        }
                        return nil
                    }
                    let routedResult = await send(
                        message,
                        in: agentThreadID,
                        profile: profile,
                        routedSourceProfileName: sourceName
                    )
                    guard let routedResult, !routedResult.isEmpty else {
                        setHandoffPhase(.failed, itemID: handoffItemID, in: sourceThreadID)
                        return nil
                    }
                    if closesLoopToSource {
                        // The reply lives in the status card (expandable) and is
                        // fed back to the source agent below — no bare echo.
                        setHandoffPhase(.replied(routedResult), itemID: handoffItemID, in: sourceThreadID)
                    } else {
                        // User-initiated mention: the echoed bubble shows the
                        // full reply, so the card would only duplicate it.
                        removeHandoffItem(handoffItemID, in: sourceThreadID)
                        append(
                            ChatMessage(role: .assistant, content: routedResult, completedAt: .now, agentReplyName: profile.displayName),
                            to: sourceThreadID
                        )
                    }
                    return (name: profile.displayName, reply: routedResult)
                }
            }
            var collected: [(name: String, reply: String)] = []
            for await result in group {
                if let result { collected.append(result) }
            }
            return collected
        }

        // Close the loop: when an agent's own reply triggered this routing
        // (`closesLoopToSource`), feed the mentioned agents' replies back to that
        // source agent as a single follow-up turn — so it actually receives them
        // instead of the replies just sitting in its thread as display echoes.
        // Dispatched through the low-level `send` (no forwarding), so this
        // follow-up is terminal and the chain stays single-hop.
        if closesLoopToSource, !replies.isEmpty {
            let framed = AgentReplyFraming.framed(replies)
            _ = await send(framed, in: sourceThreadID, profile: sourceProfile, isAgentReplyFollowUp: true)
        }
        return .routed
    }

    /// Single hop: if a Hermes profile's reply is *deliberately addressed* —
    /// a fenced code block whose content starts with a routing `@mention` —
    /// forward that block's body to the mentioned agent and feed the reply
    /// back into `sourceThreadID`. One block addresses one agent; several
    /// blocks fan out. Mentions in prose ("ask @claude about X") or mid-block
    /// must not trigger an unsolicited fan-out.
    ///
    /// `routePromptIfAllowed` dispatches through the low-level `send`, which does
    /// not itself forward — so a forwarded agent's reply is never re-parsed and
    /// the chain stops after one hop. Keep forwarding out of the low-level `send`
    /// to preserve that invariant.
    func forwardAddressedReply(
        _ reply: String?,
        from profile: HermesProfile,
        sourceThreadID: UUID,
        allowsCorrection: Bool = true
    ) async {
        guard let reply else { return }
        if hasMentionRoute(reply, codeBlockOnly: true) {
            _ = await routePromptIfAllowed(
                reply,
                from: .hermes(profile: profile),
                sourceThreadID: sourceThreadID,
                notifiesPanel: false,
                appendUserMessage: false,
                closesLoopToSource: true,
                codeBlockOnly: true
            )
            return
        }

        // Self-correction (one shot): the reply contains AgentRouting-tagged
        // blocks that failed validation — the agent clearly meant to route but
        // got the format wrong. Tell it why and let it re-emit; the retry runs
        // with correction disabled so a stubborn model can't loop.
        guard allowsCorrection else { return }
        let reasons = AgentMentionRouteParser.malformedRoutingBlockReasons(
            in: reply,
            aliasGroups: mentionRouteGroups().map(\.aliases)
        )
        guard !reasons.isEmpty else { return }
        let correction = """
        [Hermes Deck] Your AgentRouting block was not routed: \(reasons.joined(separator: "; ")).
        Re-emit only corrected \(AgentMentionRouteParser.routingFenceInfo) block(s), or answer normally to skip routing.

        ```\(AgentMentionRouteParser.routingFenceInfo)
        @target
        Write the exact task for that agent here.
        Include all context it needs; the prompt may span multiple lines.
        ```
        """
        let retryReply = await send(
            correction,
            in: sourceThreadID,
            profile: profile,
            isAgentReplyFollowUp: true
        )
        await forwardAddressedReply(retryReply, from: profile, sourceThreadID: sourceThreadID, allowsCorrection: false)
    }

    /// Sends a prompt in a Hermes-profile agent thread (the agent side panels),
    /// then applies the same single-hop reply forwarding the main chat does, so a
    /// profile's reply can `@mention` other profiles/CLIs from within a panel.
    @discardableResult
    func sendAgentProfile(_ rawText: String, in threadID: UUID, profile: HermesProfile) async -> String? {
        let reply = await send(rawText, in: threadID, profile: profile)
        await forwardAddressedReply(reply, from: profile, sourceThreadID: threadID)
        return reply
    }
}
