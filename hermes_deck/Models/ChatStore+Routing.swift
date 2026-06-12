import Foundation

/// `@mention` routing: alias resolution, prompt fan-out to mentioned
/// agents, and single-hop forwarding of addressed agent replies.
extension ChatStore {
    var externalAgentMentionTargets: [ExternalAgentMentionTarget] {
        [
            ExternalAgentMentionTarget(
                aliases: ["codex"],
                profile: HermesProfile(id: "acp:codex", displayName: ACPAgent.codex.displayName),
                backend: .acp(.codex)
            ),
            ExternalAgentMentionTarget(
                aliases: ["claude", "claude-code", "claudecode"],
                profile: HermesProfile(id: "claude-cli", displayName: "Claude Code"),
                backend: .claudeCLI
            ),
            ExternalAgentMentionTarget(
                aliases: ["gemini", "antigravity", "agy"],
                profile: HermesProfile(id: "agy", displayName: "Gemini"),
                backend: .agy
            ),
        ]
    }

    /// All `@mention` routes in `text`: each mentioned agent (external targets
    /// first, then Hermes profiles) paired with the prompt segment that follows
    /// its mention. One composed message fans out to every @-mentioned agent,
    /// each receiving only the text after its own mention.
    private func resolvedMentionRoutes(
        for text: String,
        codeBlockOnly: Bool = false
    ) -> [(target: AgentRouteTarget, message: String, isExternal: Bool)] {
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

        let spans = codeBlockOnly
            ? AgentMentionRouteParser.codeBlockRouteSpans(in: text, aliasGroups: groups.map(\.aliases))
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
        let routes = allRoutes.filter { threadIDForAgentProfile($0.target.profile) != sourceThreadID }
        guard !routes.isEmpty else { return .notMention }

        let sourceAttachments = takePendingAttachmentsForRoute(from: sourceThreadID)
        if appendUserMessage {
            append(ChatMessage(role: .user, content: text, attachments: sourceAttachments), to: sourceThreadID)
        }
        historyThreadIDs.insert(sourceThreadID)
        let sourceName = source.displayName

        // Fan out in parallel: each @mentioned agent gets the segment after its
        // mention, echoes its reply back into the source thread, and (for replies
        // that opt in) returns it for the close-the-loop follow-up below.
        let replies = await withTaskGroup(of: Optional<(name: String, reply: String)>.self) { group in
            for (offset, route) in routes.enumerated() {
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
                group.addTask { @MainActor [self] in
                    // Stagger external agents' first launch: booting several
                    // npx/node/CLI adapters at once spikes CPU/IO and janks the
                    // UI. A short offset spreads the cold-start cost.
                    if isExternal, offset > 0 {
                        try? await Task.sleep(for: .milliseconds(offset * 300))
                    }
                    let routedResult = await send(
                        message,
                        in: agentThreadID,
                        profile: profile,
                        routedSourceProfileName: sourceName
                    )
                    guard let routedResult, !routedResult.isEmpty else {
                        return nil
                    }
                    // When the loop closes back to the source agent, the framed
                    // "X replied:" follow-up below already surfaces the reply in
                    // the source thread; a bare echo would show it twice.
                    if !closesLoopToSource {
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
            let framed = replies
                .map { "\($0.name) replied:\n\n\($0.reply)" }
                .joined(separator: "\n\n———\n\n")
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
    func forwardAddressedReply(_ reply: String?, from profile: HermesProfile, sourceThreadID: UUID) async {
        guard let reply, hasMentionRoute(reply, codeBlockOnly: true) else { return }
        _ = await routePromptIfAllowed(
            reply,
            from: .hermes(profile: profile),
            sourceThreadID: sourceThreadID,
            notifiesPanel: false,
            appendUserMessage: false,
            closesLoopToSource: true,
            codeBlockOnly: true
        )
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
