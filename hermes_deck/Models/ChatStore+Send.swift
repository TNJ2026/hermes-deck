import Foundation

/// The send pipeline: prompt dispatch, slash commands, the agent event
/// stream consumer, and assistant-message assembly.
extension ChatStore {
    func send(_ rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        ensureSelectedThreadMatchesProfile()

        // `@codex` / `@claude` / `@gemini` and `@<hermes-profile>` forward the
        // prompt to that agent and echo its reply back into the current thread.
        if hasMentionRoute(text) {
            if selectedThread == nil {
                createThread(title: title(for: text))
            }
            guard let sourceThreadID = selectedThreadID else { return }
            let routeResult = await routePromptIfAllowed(
                text,
                from: .hermes(profile: selectedProfile),
                sourceThreadID: sourceThreadID,
                notifiesPanel: false
            )
            if routeResult == .routed { return }
        }

        // A leading `/` is a Hermes gateway slash command (e.g. `/help`,
        // `/model`): run it via slash.exec rather than submitting it as a prompt.
        if text.hasPrefix("/") {
            await runSlashCommand(text)
            return
        }

        if selectedThread == nil {
            createThread(title: title(for: text))
        }
        guard let selectedThreadID else { return }

        let reply = await send(
            text,
            in: selectedThreadID,
            profile: selectedProfile,
            usesGlobalSendState: true
        )
        await loadHistorySessions()

        await forwardAddressedReply(reply, from: selectedProfile, sourceThreadID: selectedThreadID)
    }

    /// A profile switched outside the chat page (`setProfile`) leaves the
    /// selected thread tagged with its old profile; continuing there would mix
    /// two gateways' sessions in one thread (the old `hermesSessionID` cannot
    /// resume on the new profile's gateway). An empty thread is simply
    /// retagged; one with history gets a fresh thread under the new profile.
    private func ensureSelectedThreadMatchesProfile() {
        guard let thread = selectedThread, thread.profile.id != selectedProfile.id else { return }
        if thread.messages.isEmpty {
            mutateSelectedThread { $0.profile = selectedProfile }
        } else {
            createThread()
        }
    }

    /// Slash commands handled by the app's own UI (or not meaningful here), so
    /// they are ignored rather than run through the gateway.
    private static let ignoredSlashCommands: Set<String> = ["help", "model", "history", "redraw"]

    /// Slash commands that mean "start a fresh session"; the app maps these to a
    /// new thread (new conversation id → new gateway session on next prompt)
    /// rather than running them on the current session's gateway.
    private static let newSessionSlashCommands: Set<String> = ["clear", "new", "reset"]

    /// Loads the selected profile's slash commands for the composer popup,
    /// dropping the ignored ones.
    func loadHermesSlashCommands() async {
        guard let all = try? await agentClient.commandsCatalog(for: selectedProfile) else { return }
        hermesSlashCommands = all.filter { !Self.ignoredSlashCommands.contains($0.name.lowercased()) }
    }

    /// Runs a Hermes `/slash` command in the current thread and renders its
    /// text output as an assistant message.
    private func runSlashCommand(_ command: String) async {
        let base = command.dropFirst()
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .first
            .map { $0.lowercased() } ?? ""
        if Self.ignoredSlashCommands.contains(base) { return }

        // `/clear`, `/new`, `/reset`: start a fresh conversation in the app.
        if Self.newSessionSlashCommands.contains(base) {
            createThread()
            return
        }

        if selectedThread == nil {
            createThread(title: title(for: command))
        }
        guard let threadID = selectedThreadID else { return }

        append(ChatMessage(role: .user, content: command), to: threadID)
        historyThreadIDs.insert(threadID)
        setSendState(.sending, for: threadID, usesGlobalSendState: true)

        let request = HermesChatRequest(
            conversationID: threadID,
            profile: selectedProfile,
            messages: thread(id: threadID)?.messages ?? [],
            attachments: [],
            backend: .hermes,
            workingDirectory: agentWorkingDirectory(for: threadID),
            resumeSessionID: thread(id: threadID)?.hermesSessionID
        )
        do {
            let output = try await agentClient.slashExec(command, for: request)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            append(
                ChatMessage(role: .assistant, content: output.isEmpty ? "(no output)" : output, completedAt: .now),
                to: threadID
            )
            setSendState(.idle, for: threadID, usesGlobalSendState: true)
        } catch {
            setSendState(.failed(error.localizedDescription), for: threadID, usesGlobalSendState: true)
            append(ChatMessage(role: .system, content: "Slash command failed: \(error.localizedDescription)"), to: threadID)
        }
        await loadHistorySessions()
    }

    @discardableResult
    func send(
        _ rawText: String,
        in threadID: UUID,
        profile: HermesProfile,
        routedSourceProfileName: String? = nil,
        isAgentReplyFollowUp: Bool? = nil
    ) async -> String? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return await send(
            text,
            in: threadID,
            profile: profile,
            usesGlobalSendState: false,
            routedSourceProfileName: routedSourceProfileName,
            isAgentReplyFollowUp: isAgentReplyFollowUp
        )
    }

    @discardableResult
    private func send(
        _ text: String,
        in threadID: UUID,
        profile: HermesProfile,
        usesGlobalSendState: Bool,
        routedSourceProfileName: String? = nil,
        isAgentReplyFollowUp: Bool? = nil
    ) async -> String? {
        guard thread(id: threadID) != nil else { return nil }
        let attachments = pendingAttachments(for: threadID, usesGlobalSendState: usesGlobalSendState)
        clearPendingAttachments(for: threadID, usesGlobalSendState: usesGlobalSendState)
        clearPermissionRequest(for: threadID, usesGlobalSendState: usesGlobalSendState)
        clearClarificationRequest(for: threadID, usesGlobalSendState: usesGlobalSendState)
        activeTaskThreadID = threadID
        taskSubagents = []
        let userMessage = ChatMessage(
            role: .user,
            content: text,
            attachments: attachments,
            routedSourceProfileName: routedSourceProfileName,
            isAgentReplyFollowUp: isAgentReplyFollowUp
        )
        append(userMessage, to: threadID)
        historyThreadIDs.insert(threadID)
        setSendState(.sending, for: threadID, usesGlobalSendState: usesGlobalSendState)

        var assistantMessageID: UUID?
        var finalAssistantText = ""
        defer {
            if let id = assistantMessageID {
                // Freeze any still-running thinking timer on every exit path
                // (normal end, error, cancellation), not just the events that
                // emit output — otherwise a turn that ends on reasoning leaves
                // the timer ticking forever.
                finalizeOpenThinking(messageID: id, in: threadID)
                markCompletedIfNeeded(id: id, in: threadID)
            }
        }

        do {
            let request = HermesChatRequest(
                conversationID: threadID,
                profile: profile,
                messages: thread(id: threadID)?.messages ?? [userMessage],
                attachments: attachments,
                backend: threadBackends[threadID] ?? .hermes,
                workingDirectory: agentWorkingDirectory(for: threadID),
                promptEnvelope: AgentPromptEnvelope(
                    text: text,
                    attachments: attachments,
                    sourceProfileName: routedSourceProfileName
                ),
                resumeSessionID: thread(id: threadID)?.hermesSessionID
            )
            for try await event in agentClient.eventStream(for: request) {
                try Task.checkCancellation()
                switch event {
                case .messageStart:
                    if assistantMessageID == nil {
                        assistantMessageID = appendAssistantDraft(to: threadID)
                    }
                case .messageDelta(_, let text):
                    let id = assistantMessageID ?? appendAssistantDraft(to: threadID)
                    assistantMessageID = id
                    finalizeOpenThinking(messageID: id, in: threadID)
                    appendToMessage(id: id, text: text, in: threadID)
                case .messageComplete(_, let text, let status, let usage):
                    let id = assistantMessageID ?? appendAssistantDraft(to: threadID)
                    assistantMessageID = id
                    finalizeOpenThinking(messageID: id, in: threadID)
                    if !text.isEmpty {
                        replaceMessage(id: id, text: text, in: threadID)
                        finalAssistantText = text
                    }
                    if let usage {
                        updateSessionInfo(
                            HermesSessionInfo(
                                contextLength: usage.contextLength,
                                usedTokens: usage.usedTokens
                            ),
                            for: threadID,
                            usesGlobalSendState: usesGlobalSendState
                        )
                    }
                    if status != "complete" {
                        setSendState(.failed(status), for: threadID, usesGlobalSendState: usesGlobalSendState)
                    }
                    markCompletedIfNeeded(id: id, in: threadID)
                case .error(_, let message):
                    setSendState(.failed(message), for: threadID, usesGlobalSendState: usesGlobalSendState)
                    append(ChatMessage(role: .system, content: message), to: threadID)
                case .toolStart(_, let tool):
                    let id = assistantMessageID ?? appendAssistantDraft(to: threadID)
                    assistantMessageID = id
                    finalizeOpenThinking(messageID: id, in: threadID)
                    upsertToolEvent(messageID: id, tool, in: threadID)
                case .toolGenerating(_, let tool):
                    let id = assistantMessageID ?? appendAssistantDraft(to: threadID)
                    assistantMessageID = id
                    upsertToolEvent(messageID: id, tool, in: threadID)
                case .toolComplete(_, let tool):
                    let id = assistantMessageID ?? appendAssistantDraft(to: threadID)
                    assistantMessageID = id
                    upsertToolEvent(messageID: id, tool, in: threadID)
                case .clarifyRequest(_, let question, let choices):
                    let id = assistantMessageID ?? appendAssistantDraft(to: threadID)
                    assistantMessageID = id
                    finalizeOpenThinking(messageID: id, in: threadID)
                    let clarification = ClarificationRequest(
                        question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                        choices: choices
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    )
                    appendClarification(messageID: id, clarification, in: threadID)
                    showClarificationRequest(clarification, for: threadID, usesGlobalSendState: usesGlobalSendState)
                    setSendState(.idle, for: threadID, usesGlobalSendState: usesGlobalSendState)
                case .thinkingDelta(_, let text):
                    let id = assistantMessageID ?? appendAssistantDraft(to: threadID)
                    assistantMessageID = id
                    appendThinking(messageID: id, text: text, in: threadID)
                case .reasoningDelta(_, let text):
                    let id = assistantMessageID ?? appendAssistantDraft(to: threadID)
                    assistantMessageID = id
                    appendReasoning(messageID: id, text: text, in: threadID)
                case .reasoningAvailable(_, let text):
                    let id = assistantMessageID ?? appendAssistantDraft(to: threadID)
                    assistantMessageID = id
                    replaceReasoning(messageID: id, text: text, in: threadID)
                case .sessionInfo(_, let info):
                    updateSessionInfo(info, for: threadID, usesGlobalSendState: usesGlobalSendState)
                case .subagentSpawnRequested(_, let progress):
                    upsertSubagent(progress, status: .queued)
                case .subagentStart(_, let progress):
                    upsertSubagent(progress, status: .running)
                case .subagentThinking(_, let progress):
                    upsertSubagent(progress) { subagent in
                        if let text = progress.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                            subagent.thinking.append(text)
                        }
                        if subagent.status == .queued {
                            subagent.status = .running
                        }
                    }
                case .subagentTool(_, let progress):
                    upsertSubagent(progress) { subagent in
                        let toolLine = Self.subagentToolLine(progress)
                        if !toolLine.isEmpty {
                            subagent.tools.append(toolLine)
                            subagent.toolCount = max(subagent.toolCount, subagent.tools.count)
                        }
                        if subagent.status == .queued {
                            subagent.status = .running
                        }
                    }
                case .subagentProgress(_, let progress):
                    upsertSubagent(progress) { subagent in
                        if let text = progress.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                            subagent.notes.append(text)
                        }
                        if subagent.status == .queued {
                            subagent.status = .running
                        }
                    }
                case .subagentComplete(_, let progress):
                    upsertSubagent(progress, status: progress.status ?? .completed) { subagent in
                        subagent.summary = progress.summary ?? progress.text ?? subagent.summary
                    }
                case .approvalRequest(_, let requestID, let text, let options):
                    // Note: we intentionally do NOT set sendState to .idle here
                    // (unlike .clarifyRequest which does). The turn is still
                    // in-flight while the backend waits for the permission
                    // answer — the Stop button must remain visible.
                    if let id = assistantMessageID {
                        // Stop the thinking timer while the user decides; the
                        // model has paused reasoning to wait for approval.
                        finalizeOpenThinking(messageID: id, in: threadID)
                    }
                    showPermissionRequest(text, options: options, requestID: requestID, for: threadID, usesGlobalSendState: usesGlobalSendState)
                case .gatewayReady, .statusUpdate:
                    break
                }
            }
            // Streaming backends (Claude CLI, Codex ACP) build the reply from
            // deltas and finish with an empty messageComplete, so fall back to
            // the assistant message's accumulated content for the return value.
            if finalAssistantText.isEmpty,
               let id = assistantMessageID,
               let message = thread(id: threadID)?.messages.first(where: { $0.id == id }) {
                finalAssistantText = message.content
            }
            if sendState(for: threadID, usesGlobalSendState: usesGlobalSendState) == .sending {
                setSendState(.idle, for: threadID, usesGlobalSendState: usesGlobalSendState)
            }
            return finalAssistantText
        } catch is CancellationError {
            setSendState(.idle, for: threadID, usesGlobalSendState: usesGlobalSendState)
            return nil
        } catch {
            setSendState(.failed(error.localizedDescription), for: threadID, usesGlobalSendState: usesGlobalSendState)
            append(ChatMessage(role: .system, content: error.localizedDescription), to: threadID)
            return nil
        }
    }

    private func upsertSubagent(
        _ progress: SubagentProgressEvent,
        status: SubagentStatus? = nil,
        mutate: ((inout SubagentProgress) -> Void)? = nil
    ) {
        let normalizedGoal = progress.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextStatus = status ?? progress.status
        let index = taskSubagents.firstIndex { $0.id == progress.id }
        var subagent = index.map { taskSubagents[$0] } ?? SubagentProgress(
            id: progress.id,
            parentID: progress.parentID,
            taskIndex: progress.taskIndex,
            taskCount: progress.taskCount,
            depth: progress.depth,
            goal: normalizedGoal.isEmpty ? "Subagent \(progress.taskIndex + 1)" : normalizedGoal,
            status: nextStatus ?? .running,
            model: progress.model
        )

        subagent.parentID = progress.parentID ?? subagent.parentID
        subagent.taskIndex = progress.taskIndex
        subagent.taskCount = progress.taskCount
        subagent.depth = progress.depth
        if !normalizedGoal.isEmpty {
            subagent.goal = normalizedGoal
        }
        subagent.status = nextStatus ?? subagent.status
        subagent.model = progress.model ?? subagent.model
        subagent.toolCount = progress.toolCount ?? subagent.toolCount
        subagent.durationSeconds = progress.durationSeconds ?? subagent.durationSeconds
        subagent.inputTokens = progress.inputTokens ?? subagent.inputTokens
        subagent.outputTokens = progress.outputTokens ?? subagent.outputTokens
        subagent.reasoningTokens = progress.reasoningTokens ?? subagent.reasoningTokens
        subagent.apiCalls = progress.apiCalls ?? subagent.apiCalls
        subagent.costUSD = progress.costUSD ?? subagent.costUSD
        if !progress.filesRead.isEmpty {
            subagent.filesRead = progress.filesRead
        }
        if !progress.filesWritten.isEmpty {
            subagent.filesWritten = progress.filesWritten
        }
        if !progress.outputTail.isEmpty {
            subagent.outputTail = progress.outputTail
        }

        mutate?(&subagent)

        if let index {
            taskSubagents[index] = subagent
        } else {
            taskSubagents.append(subagent)
        }
        taskSubagents.sort { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            return lhs.taskIndex < rhs.taskIndex
        }
    }

    private static func subagentToolLine(_ progress: SubagentProgressEvent) -> String {
        let name = (progress.toolName ?? "tool").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (progress.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return name }
        return "\(name): \(text)"
    }

    @discardableResult
    private func appendAssistantDraft(to threadID: UUID) -> UUID {
        let message = ChatMessage(role: .assistant, content: "")
        append(message, to: threadID)
        return message.id
    }

    func append(_ message: ChatMessage, to threadID: UUID) {
        mutateThread(id: threadID) { thread in
            // Safety net: any thinking timer left running on an earlier message
            // is frozen now that a new message has arrived, so no segment ever
            // ticks forever even if its turn missed an explicit finalize.
            let now = Date.now
            for index in thread.messages.indices {
                Self.freezeOpenThinking(in: &thread.messages[index], endingAt: thread.messages[index].completedAt ?? now)
            }
            thread.messages.append(message)
            thread.updatedAt = .now
            if thread.title == "New Chat" {
                thread.title = title(for: message.content)
            }
        }
    }

    /// Freezes every still-running thinking segment in `message`, recording its
    /// elapsed time. Idempotent: segments with a duration already set are left
    /// untouched.
    private static func freezeOpenThinking(in message: inout ChatMessage, endingAt end: Date) {
        for index in message.segments.indices {
            guard case .thinking(var segment) = message.segments[index],
                  segment.durationSeconds == nil,
                  let startedAt = segment.startedAt else { continue }
            segment.durationSeconds = max(0, end.timeIntervalSince(startedAt))
            message.segments[index] = .thinking(segment)
        }
    }

    private func appendToMessage(id: UUID, text: String, in threadID: UUID) {
        mutateThread(id: threadID) { thread in
            guard let index = thread.messages.firstIndex(where: { $0.id == id }) else { return }
            thread.messages[index].content += text
            thread.updatedAt = .now
        }
    }

    private func replaceMessage(id: UUID, text: String, in threadID: UUID) {
        mutateThread(id: threadID) { thread in
            guard let index = thread.messages.firstIndex(where: { $0.id == id }) else { return }
            thread.messages[index].content = text
            thread.updatedAt = .now
        }
    }

    private func markCompletedIfNeeded(id: UUID, in threadID: UUID) {
        mutateThread(id: threadID) { thread in
            guard let index = thread.messages.firstIndex(where: { $0.id == id }) else { return }
            if thread.messages[index].completedAt == nil {
                thread.messages[index].completedAt = .now
            }
        }
    }

    private func upsertToolEvent(messageID: UUID, _ event: ToolCallEvent, in threadID: UUID) {
        mutateThread(id: threadID) { thread in
            guard let messageIndex = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
            if let segmentIndex = matchingToolSegmentIndex(for: event, in: thread.messages[messageIndex].segments),
               case .tool(var existing) = thread.messages[messageIndex].segments[segmentIndex] {
                existing.merge(with: event)
                thread.messages[messageIndex].segments[segmentIndex] = .tool(existing)
            } else {
                thread.messages[messageIndex].segments.append(.tool(event))
            }
            thread.updatedAt = .now
        }
    }

    private func matchingToolSegmentIndex(for event: ToolCallEvent, in segments: [AssistantSegment]) -> Int? {
        if let toolID = event.toolID {
            return segments.firstIndex {
                if case .tool(let existing) = $0 { existing.toolID == toolID } else { false }
            }
        }
        return segments.lastIndex {
            guard case .tool(let existing) = $0 else { return false }
            return existing.toolID == nil
                && existing.name == event.name
                && existing.state != .complete
        }
    }

    private func appendClarification(messageID: UUID, _ clarification: ClarificationRequest, in threadID: UUID) {
        mutateThread(id: threadID) { thread in
            guard let messageIndex = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
            thread.messages[messageIndex].segments.append(.clarify(clarification))
            thread.updatedAt = .now
        }
    }

    private func appendThinking(messageID: UUID, text: String, in threadID: UUID) {
        mutateThread(id: threadID) { thread in
            guard let messageIndex = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
            let segments = thread.messages[messageIndex].segments
            if case .thinking(var segment) = segments.last, segment.durationSeconds == nil {
                segment.text += text
                thread.messages[messageIndex].segments[segments.count - 1] = .thinking(segment)
            } else {
                thread.messages[messageIndex].segments.append(.thinking(ThinkingSegment(text: text, startedAt: .now)))
            }
            thread.updatedAt = .now
        }
    }

    /// Freezes the in-progress thinking segment's duration once reasoning ends
    /// (the model starts emitting output or a tool call). Called before any
    /// non-thinking content is appended to the same message.
    private func finalizeOpenThinking(messageID: UUID, in threadID: UUID) {
        mutateThread(id: threadID) { thread in
            guard let messageIndex = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
            Self.freezeOpenThinking(in: &thread.messages[messageIndex], endingAt: .now)
        }
    }

    private func appendReasoning(messageID: UUID, text: String, in threadID: UUID) {
        mutateThread(id: threadID) { thread in
            guard let messageIndex = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
            thread.messages[messageIndex].reasoningText += text
            thread.updatedAt = .now
        }
    }

    private func replaceReasoning(messageID: UUID, text: String, in threadID: UUID) {
        mutateThread(id: threadID) { thread in
            guard let messageIndex = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
            thread.messages[messageIndex].reasoningText = text
            thread.updatedAt = .now
        }
    }

    func pendingAttachments(for threadID: UUID, usesGlobalSendState: Bool) -> [Attachment] {
        if usesGlobalSendState {
            return pendingAttachments
        }
        return agentPendingAttachments[threadID] ?? []
    }

    func clearPendingAttachments(for threadID: UUID, usesGlobalSendState: Bool) {
        if usesGlobalSendState {
            pendingAttachments = []
        } else {
            agentPendingAttachments[threadID] = []
        }
    }

    func takePendingAttachmentsForRoute(from sourceThreadID: UUID) -> [Attachment] {
        if let attachments = agentPendingAttachments[sourceThreadID], !attachments.isEmpty {
            agentPendingAttachments[sourceThreadID] = []
            return attachments
        }
        guard sourceThreadID == selectedThreadID else { return [] }
        let attachments = pendingAttachments
        pendingAttachments = []
        return attachments
    }

    func updateSessionInfo(_ info: HermesSessionInfo, for threadID: UUID, usesGlobalSendState: Bool) {
        if usesGlobalSendState {
            sessionInfo.merge(info)
        } else {
            var current = agentSessionInfos[threadID] ?? HermesSessionInfo()
            current.merge(info)
            agentSessionInfos[threadID] = current
        }
    }

    func sendState(for threadID: UUID, usesGlobalSendState: Bool) -> ChatSendState {
        if usesGlobalSendState {
            return sendState
        }
        return agentSendStates[threadID] ?? .idle
    }

    func setSendState(_ state: ChatSendState, for threadID: UUID, usesGlobalSendState: Bool) {
        if usesGlobalSendState {
            sendState = state
        } else {
            agentSendStates[threadID] = state
        }
    }

    // MARK: - Send task registry (Stop button)

    /// Registers the task driving a composer send so Stop can cancel it even
    /// after the composer view is recreated mid-turn.
    func registerSendTask(_ task: Task<Void, Never>, forAgentThreadID threadID: UUID?) {
        activeSendTasks[threadID] = task
    }

    func clearSendTask(forAgentThreadID threadID: UUID?) {
        activeSendTasks[threadID] = nil
    }

    /// Cancels the in-flight send for a thread; cancellation propagates down
    /// to the agent client, which interrupts the gateway turn.
    func cancelSendTask(forAgentThreadID threadID: UUID?) {
        activeSendTasks.removeValue(forKey: threadID)?.cancel()
    }
}
