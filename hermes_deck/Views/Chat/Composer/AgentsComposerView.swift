import SwiftUI

/// A single-line composer for the in-app **Agents** panel (Hermes profiles).
///
/// Differs from `ComposerView`: the input is one line, the attachment button
/// sits at the far left, and the model/mode name plus a circular token-usage
/// gauge sit on a footer row below the field, right-aligned with it. Keeps the
/// attachment chips, `@mention` autocomplete, voice input, and the permission /
/// clarification banners the agent threads rely on.
struct AgentsComposerView: View {
    @Bindable var store: ChatStore
    @Binding var draft: String
    @Binding var isFileImporterPresented: Bool
    var presentation: ComposerPresentation = .inline
    var sendState: ChatSendState?
    var attachments: [Attachment]
    var permissionRequest: PermissionRequest?
    var clarificationRequest: ClarificationRequest?
    var sessionInfo: HermesSessionInfo
    var removeAttachment: (Attachment) -> Void
    var dismissPermissionRequest: () -> Void
    var answerPermission: (Int) -> Void = { _ in }
    var dismissClarificationRequest: () -> Void
    var requestFileImport: () -> Void
    var sendAction: (String) async -> Void = { _ in }
    /// The profile this composer sends as, excluded from the `@mention` list
    /// (no self-mention). `nil` falls back to the main chat's selected profile.
    var composerProfileID: String?
    /// External CLI panels hide the attachment button (their backends don't
    /// take file attachments); the Agents panel keeps it.
    var showsAttachmentButton = true
    /// Thread this composer sends into (nil = main chat). Keys the send task
    /// in the store so Stop still works after the view is recreated.
    var composerThreadID: UUID?

    @State private var sendTask: Task<Void, Never>?
    @State private var speechTranscriber = SpeechTranscriber()
    @State private var speechBaselineDraft = ""
    @State private var mentionSelectedIndex = 0
    @State private var suppressedMentionQuery: String?
    @State private var mentionPopupHeight: CGFloat = 0
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

            VStack(alignment: .leading, spacing: 6) {
                MentionTextView(
                    text: $draft,
                    placeholder: "Ask anything",
                    aliases: mentionAliases,
                    onSubmit: send,
                    onKeyCommand: handleMentionCommand,
                    onHeightChange: { textHeight = $0 }
                )
                .frame(height: textHeight)

                HStack(alignment: .center, spacing: 7) {
                    if speechTranscriber.isRecording {
                        WaveformView(levels: speechTranscriber.audioLevels, tint: .blue)
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)
                            .allowsHitTesting(false)
                    } else {
                        if showsAttachmentButton {
                            iconButton(systemImage: "paperclip", accessibilityLabel: "Attach") {
                                requestFileImport()
                            }
                        }

                        Spacer(minLength: 8)

                        if sessionInfo.hasModelInfo {
                            if let model = sessionInfo.model, !model.isEmpty {
                                Text(model)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            TokenUsageRing(used: sessionInfo.usedTokens, total: sessionInfo.contextLength)
                        }
                    }

                    iconButton(
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
                                        .font(.system(size: 10, weight: .semibold))
                                } else {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                            }
                            .frame(width: 30, height: 30)
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(sendButtonForeground)
                        .background(sendButtonBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .disabled(!canSend && !isSending)
                        .pointingHandCursor(canSend || isSending)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .composerSurface(presentation: presentation, cornerRadius: 13, border: inputBorder)
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 3)
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

    // MARK: - Controls

    /// A compact icon button for the bottom control row.
    private func iconButton(
        systemImage: String,
        accessibilityLabel: String,
        tint: Color = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
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

    // MARK: - Send state

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
        store.answerClarificationRequest(clarificationRequest, answer: trimmed, forAgentThreadID: composerThreadID)
        speechTranscriber.stopRecording()
        draft = ""
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
        guard !transcript.isEmpty else { return }
        let separator = speechBaselineDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " "
        draft = speechBaselineDraft + separator + transcript
    }
}

/// A compact circular gauge for context-window usage: a faint track plus an arc
/// filled to `used / total`, tinting amber then red as the window fills.
private struct TokenUsageRing: View {
    let used: Int?
    let total: Int?

    private var fraction: Double {
        guard let used, let total, total > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(total)))
    }

    private var tint: Color {
        switch fraction {
        case ..<0.75: .accentColor
        case ..<0.9: .orange
        default: .red
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.25), value: fraction)
        }
        .frame(width: 11, height: 11)
        .help(helpText)
    }

    private var helpText: String {
        guard let used, let total else { return "Context usage" }
        return "\(used) / \(total) tokens (\(Int(fraction * 100))%)"
    }
}
