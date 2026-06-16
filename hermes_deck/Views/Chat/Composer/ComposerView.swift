import SwiftUI

struct ComposerView: View {
    @Bindable var store: ChatStore
    @Binding var draft: String
    @Binding var isFileImporterPresented: Bool
    var presentation: ComposerPresentation = .floating
    var sendState: ChatSendState?
    var attachments: [Attachment]
    var permissionRequest: PermissionRequest?
    var clarificationRequest: ClarificationRequest?
    var sessionInfo: HermesSessionInfo
    var removeAttachment: (Attachment) -> Void
    var dismissPermissionRequest: () -> Void
    var answerPermission: (Int) -> Void = { _ in }
    var dismissClarificationRequest: () -> Void
    var simulatePermissionRequest: () -> Void
    var requestFileImport: () -> Void
    var sendAction: (String) async -> Void = { _ in }
    /// Hermes slash commands for the `/` popup; empty disables it.
    var slashCommands: [SlashCommand] = []
    /// The profile this composer sends as, excluded from the `@mention` list
    /// (no self-mention). `nil` falls back to the main chat's selected profile.
    var composerProfileID: String?
    /// Thread this composer sends into (nil = main chat). Keys the send task
    /// in the store so Stop still works after the view is recreated.
    var composerThreadID: UUID?
    @State private var sendTask: Task<Void, Never>?
    @State private var speechTranscriber = SpeechTranscriber()
    @State private var speechBaselineDraft = ""
    @State private var mentionSelectedIndex = 0
    @State private var suppressedMentionQuery: String?
    @State private var mentionPopupHeight: CGFloat = 0
    @State private var slashSelectedIndex = 0
    @State private var suppressedSlashQuery: String?
    @State private var textHeight: CGFloat = 24
    /// Candidate ids already @-mentioned in the draft; recomputed only when
    /// `draft` changes (not on every popup re-render).
    @State private var mentionedCandidateCache: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(attachments) { attachment in
                        ComposerAttachmentChip(attachment: attachment) {
                            removeAttachment(attachment)
                        }
                    }
                }
            }

            if let request = permissionRequest {
                PermissionRequestBanner(request: request, onAnswer: answerPermission) {
                    dismissPermissionRequest()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let request = clarificationRequest {
                ClarificationRequestBanner(
                    request: request,
                    isSending: isSending,
                    onAnswer: answerClarification,
                    onDismiss: dismissClarificationRequest
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: 4) {
                MentionTextView(
                    text: $draft,
                    placeholder: "Ask anything",
                    aliases: mentionAliases,
                    maxLines: 8,
                    onSubmit: send,
                    onKeyCommand: handleComposerCommand,
                    onHeightChange: { textHeight = $0 }
                )
                .frame(height: textHeight)

                HStack(alignment: .center, spacing: 4) {
                    if speechTranscriber.isRecording {
                        WaveformView(levels: speechTranscriber.audioLevels, tint: .blue)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .allowsHitTesting(false)
                    } else {
                        ComposerIconButton(systemImage: "paperclip", accessibilityLabel: "Attach") {
                            requestFileImport()
                        }

                        Spacer(minLength: 10)

                        if sessionInfo.hasModelInfo {
                            Button {
                            } label: {
                                Text(sessionInfo.displayText)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                                    .frame(height: 28)
                                    .padding(.horizontal, 9)
                            }
                            .buttonStyle(.plain)
                            .disabled(true)
                        }
                    }

                    ComposerIconButton(
                        systemImage: speechTranscriber.isRecording ? "stop.fill" : "mic",
                        accessibilityLabel: speechTranscriber.isRecording ? "Stop Voice Input" : "Voice Input",
                        tint: speechTranscriber.isRecording ? .red : .secondary
                    ) {
                        toggleVoiceInput()
                    }
                    .disabled(isSending || speechTranscriber.isLockedOut)
                    .help(speechTranscriber.helpText)

                    if !speechTranscriber.isRecording {
                        Button(action: sendOrCancel) {
                            Group {
                                if isSending {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                } else {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                            }
                            .frame(width: 34, height: 34)
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(sendButtonForeground)
                        .background(sendButtonBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .shadow(color: sendButtonShadow, radius: 12, x: 0, y: 4)
                        .disabled(!canSend && !isSending)
                        .pointingHandCursor(canSend || isSending)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 10)
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .composerSurface(presentation: presentation, cornerRadius: 13, border: inputBorder)
            .overlay(alignment: .topLeading) {
                if let mention = activeMention {
                    let candidates = filteredCandidates(for: mention.query)
                    if !candidates.isEmpty {
                        MentionAutocompleteList(
                            candidates: candidates,
                            selectedIndex: mentionSelectedIndex
                        ) { candidate in
                            insertMention(candidate, replacing: mention.range)
                        }
                        .readHeight(MentionPopupHeightPreferenceKey.self)
                        .offset(y: -(mentionPopupHeight + 6))
                        .onPreferenceChange(MentionPopupHeightPreferenceKey.self) { mentionPopupHeight = $0 }
                        .onChange(of: mention.query) { _, _ in mentionSelectedIndex = 0 }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if let slash = activeSlash {
                    let commands = filteredSlashCommands(for: slash.query)
                    if !commands.isEmpty {
                        SlashAutocompleteList(
                            commands: commands,
                            selectedIndex: slashSelectedIndex
                        ) { command in
                            insertSlash(command, replacing: slash.range)
                        }
                        .readHeight(MentionPopupHeightPreferenceKey.self)
                        .offset(y: -(mentionPopupHeight + 6))
                        .onPreferenceChange(MentionPopupHeightPreferenceKey.self) { mentionPopupHeight = $0 }
                        .onChange(of: slash.query) { _, _ in slashSelectedIndex = 0 }
                    }
                }
            }

            if case .failed(let message) = currentSendState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(composerPadding)
        .onChange(of: speechTranscriber.transcript) { _, newValue in
            updateDraft(withTranscript: newValue)
        }
        .onChange(of: draft) { _, _ in
            mentionedCandidateCache = computeMentionedCandidateIDs()
        }
        .onDisappear {
            speechTranscriber.stopRecording()
        }
    }

    // MARK: - @ mention autocomplete

    private var mentionCandidates: [MentionCandidate] {
        let hermes = store.mentionableProfiles
            .filter { $0.id != (composerProfileID ?? store.selectedProfile.id) }
            .map { profile in
                MentionCandidate(
                    id: profile.id,
                    label: profile.displayName,
                    subtitle: store.profileMainModels[profile.id] ?? "Hermes profile",
                    alias: profile.id
                )
            }
        let external = store.externalAgentMentionTargets.map { target in
            MentionCandidate(
                id: target.profile.id,
                label: target.profile.displayName,
                subtitle: Self.backendLabel(target.backend),
                alias: target.aliases.first ?? target.profile.id,
                isUnavailable: store.isExternalAgentUnavailable(target.profile.id)
            )
        }
        return hermes + external
    }

    private var mentionAliases: [String] { mentionCandidates.map(\.alias) }

    private static func backendLabel(_ backend: AgentBackend) -> String {
        switch backend {
        case .hermes: "Hermes"
        case .acp(let agent): "\(agent.displayName) (ACP)"
        case .claudeCLI: "Claude CLI"
        case .agy: "Antigravity CLI"
        }
    }

    /// The mention being typed, unless the user pressed Esc on this exact query.
    private var activeMention: (range: Range<String.Index>, query: String)? {
        guard let mention = ComposerMention.activeQuery(in: draft) else { return nil }
        if let suppressed = suppressedMentionQuery, suppressed == mention.query { return nil }
        return mention
    }

    private func filteredCandidates(for query: String) -> [MentionCandidate] {
        let available = mentionCandidates.filter { !mentionedCandidateCache.contains($0.id) }
        guard !query.isEmpty else { return available }
        return available.filter {
            $0.alias.lowercased().contains(query) || $0.label.lowercased().contains(query)
        }
    }

    /// Candidate ids already @-mentioned in the draft (excluding the mention
    /// being typed right now) — so each agent can only be mentioned once.
    /// Cached in `mentionedCandidateCache`; recomputed via `onChange(draft)`.
    private func computeMentionedCandidateIDs() -> Set<String> {
        var text = draft
        if let mention = activeMention {
            text.removeSubrange(mention.range)
        }
        var ids: Set<String> = []
        for target in store.externalAgentMentionTargets {
            if !AgentMentionRouteParser.routeSpans(in: text, aliasGroups: [target.aliases]).isEmpty {
                ids.insert(target.profile.id)
            }
        }
        for profile in store.mentionableProfiles {
            let aliases = [profile.id, profile.displayName]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !AgentMentionRouteParser.routeSpans(in: text, aliasGroups: [aliases]).isEmpty {
                ids.insert(profile.id)
            }
        }
        return ids
    }

    private func insertMention(_ candidate: MentionCandidate, replacing range: Range<String.Index>) {
        draft.replaceSubrange(range, with: "@\(candidate.alias) ")
        suppressedMentionQuery = nil
        mentionSelectedIndex = 0
    }

    private func handleMentionCommand(_ command: MentionKeyCommand) -> Bool {
        guard let mention = activeMention else { return false }
        let candidates = filteredCandidates(for: mention.query)
        guard !candidates.isEmpty else { return false }

        switch command {
        case .moveDown:
            mentionSelectedIndex = (mentionSelectedIndex + 1) % candidates.count
            return true
        case .moveUp:
            mentionSelectedIndex = (mentionSelectedIndex - 1 + candidates.count) % candidates.count
            return true
        case .confirm:
            let index = min(max(mentionSelectedIndex, 0), candidates.count - 1)
            insertMention(candidates[index], replacing: mention.range)
            return true
        case .dismiss:
            suppressedMentionQuery = mention.query
            return true
        }
    }

    // MARK: - / slash-command autocomplete (Hermes)

    private var activeSlash: (range: Range<String.Index>, query: String)? {
        guard !slashCommands.isEmpty else { return nil }
        guard let slash = ComposerSlash.activeQuery(in: draft) else { return nil }
        if let suppressed = suppressedSlashQuery, suppressed == slash.query { return nil }
        return slash
    }

    private func filteredSlashCommands(for query: String) -> [SlashCommand] {
        guard !query.isEmpty else { return slashCommands }
        return slashCommands.filter { $0.name.lowercased().contains(query) }
    }

    private func insertSlash(_ command: SlashCommand, replacing range: Range<String.Index>) {
        draft.replaceSubrange(range, with: "/\(command.name) ")
        suppressedSlashQuery = nil
        slashSelectedIndex = 0
    }

    private func handleSlashCommand(_ command: MentionKeyCommand) -> Bool {
        guard let slash = activeSlash else { return false }
        let commands = filteredSlashCommands(for: slash.query)
        guard !commands.isEmpty else { return false }

        switch command {
        case .moveDown:
            slashSelectedIndex = (slashSelectedIndex + 1) % commands.count
            return true
        case .moveUp:
            slashSelectedIndex = (slashSelectedIndex - 1 + commands.count) % commands.count
            return true
        case .confirm:
            let index = min(max(slashSelectedIndex, 0), commands.count - 1)
            insertSlash(commands[index], replacing: slash.range)
            return true
        case .dismiss:
            suppressedSlashQuery = slash.query
            return true
        }
    }

    /// Routes a key to whichever autocomplete popup is active (mention or slash).
    private func handleComposerCommand(_ command: MentionKeyCommand) -> Bool {
        if activeMention != nil { return handleMentionCommand(command) }
        if activeSlash != nil { return handleSlashCommand(command) }
        return false
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        currentSendState != .sending &&
        hasContentBeyondMentions
    }

    private var hasContentBeyondMentions: Bool {
        let ranges = MentionTextView.mentionRanges(in: draft, sortedAliases: mentionAliases.sorted { $0.count > $1.count })
        var remaining = draft
        for range in ranges.reversed() {
            if let strRange = Range(range, in: remaining) {
                remaining.removeSubrange(strRange)
            }
        }
        return !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSending: Bool {
        currentSendState == .sending
    }

    private var currentSendState: ChatSendState {
        sendState ?? store.sendState
    }

    private var inputBorder: Color {
        canSend ? .accentColor.opacity(0.3) : .secondary.opacity(0.18)
    }

    private var sendButtonBackground: Color {
        if isSending { return .red.opacity(0.88) }
        return canSend ? .accentColor : .secondary.opacity(0.16)
    }

    private var sendButtonForeground: Color {
        canSend || isSending ? .white : .secondary
    }

    private var sendButtonShadow: Color {
        if isSending { return .red.opacity(0.24) }
        if presentation == .inline { return .clear }
        return canSend ? .accentColor.opacity(0.32) : .clear
    }

    private var composerPadding: EdgeInsets {
        switch presentation {
        case .floating:
            EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24)
        case .inline:
            EdgeInsets(top: 10, leading: 0, bottom: 0, trailing: 0)
        }
    }

    private func sendOrCancel() {
        if isSending {
            // The store-registered task survives composer view recreation (the
            // empty-thread composer is swapped out on the first message); the
            // local handle alone would be nil in that case.
            store.cancelSendTask(forAgentThreadID: composerThreadID)
            sendTask?.cancel()
            sendTask = nil
        } else {
            send()
        }
    }

    private func send() {
        guard canSend else { return }
        speechTranscriber.stopRecording()
        let message = draft
        draft = ""
        startSendTask(message: message)
    }

    private func startSendTask(message: String) {
        let threadID = composerThreadID
        let task = Task {
            await sendAction(message)
            await MainActor.run {
                sendTask = nil
                store.clearSendTask(forAgentThreadID: threadID)
            }
        }
        sendTask = task
        store.registerSendTask(task, forAgentThreadID: threadID)
    }

    private func answerClarification(_ answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        dismissClarificationRequest()
        speechTranscriber.stopRecording()
        draft = ""
        startSendTask(message: trimmed)
    }

    private func toggleVoiceInput() {
        if speechTranscriber.isRecording {
            speechTranscriber.stopRecording()
        } else {
            speechBaselineDraft = draft
            Task { @MainActor in
                await speechTranscriber.startRecording()
            }
        }
    }

    private func updateDraft(withTranscript transcript: String) {
        // Not gated on isRecording: by the time the final (isFinal) result
        // arrives, state has already been reset to .idle and SwiftUI delivers
        // onChange in a coalesced view update where isRecording is false.
        guard !transcript.isEmpty else { return }
        let separator = speechBaselineDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " "
        draft = speechBaselineDraft + separator + transcript
    }
}
