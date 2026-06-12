import SwiftUI

struct ChatDetailView: View {
    @Bindable var store: ChatStore
    @Binding var draft: String
    @Binding var isFileImporterPresented: Bool
    var composerPresentation: ComposerPresentation = .floating
    var showsComposer = true
    /// Side inset for the message list. Defaults to the wide main-chat column;
    /// the narrower right-sidebar panels pass a tighter value.
    var messageHorizontalInset: CGFloat = 24
    /// Minimum gap between an assistant bubble and the trailing edge (user
    /// bubbles keep their own). The right-sidebar panels pass a tighter value
    /// so agent replies use more of the narrow column.
    var assistantTrailingInset: CGFloat = 80
    /// The Agents panel and the external CLI panels opt into the single-line
    /// `AgentsComposerView`; the main chat keeps the standard `ComposerView`.
    var usesAgentsComposer = false
    /// External CLI panels hide the agents composer's attachment button.
    var composerShowsAttachmentButton = true
    /// Custom header above the centered empty-thread composer (the external
    /// panels pass their branded welcome); `nil` shows the generic one.
    var emptyStateHeader: AnyView?
    var threadID: UUID?
    var sendProfile: HermesProfile?
    var sendState: ChatSendState?
    var sendBackend: AgentBackend = .hermes
    var onFileImportRequested: (UUID?) -> Void = { _ in }
    private let bottomAnchorID = "chat-bottom-anchor"
    private let scrollSpace = "chat-scroll-space"
    /// How close (pt) the bottom anchor must be to the viewport bottom for the
    /// view to count as "following" and keep auto-scrolling.
    private let bottomFollowThreshold: CGFloat = 120

    @State private var viewportHeight: CGFloat = 0
    @State private var bottomAnchorOffset: CGFloat = 0
    /// Whether the user is parked at the bottom. Auto-scroll is suppressed while
    /// they've scrolled up to read history.
    @State private var isPinnedToBottom = true

    var body: some View {
        VStack(spacing: 0) {
            if let thread = displayedThread {
                if showsComposer && isEmptyThread(thread) {
                    emptyThreadComposer
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(thread.messages) { message in
                                    MessageBubble(message: message, assistantTrailingInset: assistantTrailingInset)
                                        .id(message.id)
                                }
                                if showsThinkingIndicator {
                                    ThinkingIndicatorRow()
                                        .id("thinking-indicator")
                                }
                                Color.clear
                                    .frame(height: 1)
                                    .id(bottomAnchorID)
                                    .background(
                                        GeometryReader { geo in
                                            Color.clear.preference(
                                                key: BottomAnchorOffsetKey.self,
                                                value: geo.frame(in: .named(scrollSpace)).minY
                                            )
                                        }
                                    )
                            }
                            .padding(.vertical, 24)
                            .padding(.horizontal, messageHorizontalInset)
                        }
                        .coordinateSpace(name: scrollSpace)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(key: ViewportHeightKey.self, value: geo.size.height)
                            }
                        )
                        .onPreferenceChange(ViewportHeightKey.self) {
                            viewportHeight = $0
                            recomputePinned()
                        }
                        .onPreferenceChange(BottomAnchorOffsetKey.self) {
                            bottomAnchorOffset = $0
                            recomputePinned()
                        }
                        .fileLinkHandler(baseDirectory: messageBaseDirectory)
                        .onAppear {
                            scrollToBottom(with: proxy, animated: false)
                        }
                        .onChange(of: thread.id) {
                            isPinnedToBottom = true
                            scrollToBottom(with: proxy, animated: false)
                        }
                        // A new message (or a turn boundary) animates into view —
                        // but only if the user is following along at the bottom, so
                        // scrolling up to read history isn't yanked back down.
                        .onChange(of: thread.messages.count) {
                            guard isPinnedToBottom else { return }
                            scrollToBottom(with: proxy, animated: true)
                        }
                        // Streaming growth follows the bottom instantly — animating
                        // each token stacks dozens of springs a second and makes the
                        // view jitter. Suppressed when the user has scrolled up.
                        .onChange(of: streamingTrigger(for: thread)) {
                            guard isPinnedToBottom else { return }
                            scrollToBottom(with: proxy, animated: false)
                        }
                    }
                    if showsComposer {
                        composerView
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            } else {
                ContentUnavailableView("No Chat Selected", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: store.selectedProfile.id) {
            // Load the main chat's slash commands (per selected profile).
            if sendBackend == .hermes, threadID == nil {
                await store.loadHermesSlashCommands()
            }
        }
    }

    @ViewBuilder
    private var composerView: some View {
        if usesAgentsComposer {
            AgentsComposerView(
                store: store,
                draft: $draft,
                isFileImporterPresented: $isFileImporterPresented,
                presentation: composerPresentation,
                sendState: sendState,
                attachments: composerAttachments,
                permissionRequest: composerPermissionRequest,
                clarificationRequest: composerClarificationRequest,
                sessionInfo: composerSessionInfo,
                removeAttachment: removeAttachment,
                dismissPermissionRequest: dismissPermissionRequest,
                answerPermission: answerPermission,
                dismissClarificationRequest: dismissClarificationRequest,
                requestFileImport: requestFileImport,
                sendAction: send,
                composerProfileID: sendProfile?.id,
                showsAttachmentButton: composerShowsAttachmentButton,
                composerThreadID: threadID
            )
        } else {
            standardComposerView
        }
    }

    private var standardComposerView: some View {
        ComposerView(
            store: store,
            draft: $draft,
            isFileImporterPresented: $isFileImporterPresented,
            presentation: composerPresentation,
            sendState: sendState,
            attachments: composerAttachments,
            permissionRequest: composerPermissionRequest,
            clarificationRequest: composerClarificationRequest,
            sessionInfo: composerSessionInfo,
            removeAttachment: removeAttachment,
            dismissPermissionRequest: dismissPermissionRequest,
            answerPermission: answerPermission,
            dismissClarificationRequest: dismissClarificationRequest,
            simulatePermissionRequest: simulatePermissionRequest,
            requestFileImport: requestFileImport,
            sendAction: send,
            // Only the main chat (threadID == nil) executes slash commands.
            slashCommands: (sendBackend == .hermes && threadID == nil) ? store.hermesSlashCommands : [],
            composerProfileID: sendProfile?.id,
            composerThreadID: threadID
        )
    }

    /// A thread with nothing to scroll: no messages and no in-flight reply.
    /// Drives the centered start-of-chat composer.
    private func isEmptyThread(_ thread: ChatThread) -> Bool {
        thread.messages.isEmpty && !showsThinkingIndicator
    }

    /// Centered composer shown when a thread has no messages yet, with a short
    /// prompt inviting the user to start.
    private var emptyThreadComposer: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 18) {
                if let emptyStateHeader {
                    emptyStateHeader
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("Start a new conversation")
                            .font(.title2.weight(.semibold))
                        Text("Ask a question or describe a task to get started.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                }

                composerView
            }
            .frame(maxWidth: 720)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Base directory for resolving relative file-path links in messages: the
    /// agent thread's working directory, the main session's cwd, else home.
    private var messageBaseDirectory: URL? {
        if let threadID {
            return store.agentWorkingDirectory(for: threadID)
        }
        if let cwd = store.sessionInfo.cwd, !cwd.isEmpty {
            return URL(fileURLWithPath: cwd)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private var displayedThread: ChatThread? {
        if let threadID {
            return store.thread(id: threadID)
        }
        return store.selectedThread
    }

    private var isSending: Bool {
        (sendState ?? store.sendState) == .sending
    }

    /// Shows a transient "Thinking…" row while a reply is in flight and nothing
    /// has rendered yet; it disappears once content/segments arrive or the turn
    /// ends.
    private var showsThinkingIndicator: Bool {
        guard sendBackend != .hermes else { return false }  // only ACP/CLI agent panels
        guard isSending, let thread = displayedThread else { return false }
        guard let last = thread.messages.last else { return true }
        guard last.role == .assistant else { return true }
        return last.content.isEmpty && last.segments.isEmpty && last.reasoningText.isEmpty
    }

    private var composerAttachments: [Attachment] {
        if let threadID {
            return store.pendingAttachments(forAgentThreadID: threadID)
        }
        return store.pendingAttachments
    }

    private var composerPermissionRequest: PermissionRequest? {
        if let threadID {
            return store.pendingPermissionRequest(forAgentThreadID: threadID)
        }
        if let activeID = store.activeTaskThreadID, store.sendState == .sending {
            if let req = store.pendingPermissionRequest(forAgentThreadID: activeID) {
                return req
            }
        }
        return store.pendingPermissionRequest
    }

    private var composerClarificationRequest: ClarificationRequest? {
        if let threadID {
            return store.pendingClarificationRequest(forAgentThreadID: threadID)
        }
        return store.pendingClarificationRequest
    }

    private var composerSessionInfo: HermesSessionInfo {
        if let threadID {
            return store.sessionInfo(forAgentThreadID: threadID)
        }
        return store.sessionInfo
    }

    private func removeAttachment(_ attachment: Attachment) {
        if let threadID {
            store.removeAttachment(attachment, fromAgentThreadID: threadID)
        } else {
            store.removeAttachment(attachment)
        }
    }

    private func dismissPermissionRequest() {
        if let threadID {
            store.dismissPermissionRequest(forAgentThreadID: threadID)
        } else if let activeID = store.activeTaskThreadID, store.sendState == .sending, store.pendingPermissionRequest == nil {
            store.dismissPermissionRequest(forAgentThreadID: activeID)
        } else {
            store.dismissPermissionRequest()
        }
    }

    private func answerPermission(_ index: Int) {
        if let threadID {
            store.answerPermission(at: index, forAgentThreadID: threadID)
        } else if let activeID = store.activeTaskThreadID, store.sendState == .sending, store.pendingPermissionRequest == nil {
            store.answerPermission(at: index, forAgentThreadID: activeID)
        } else {
            store.answerPermission(at: index)
        }
    }

    private func dismissClarificationRequest() {
        if let threadID {
            store.dismissClarificationRequest(forAgentThreadID: threadID)
        } else {
            store.dismissClarificationRequest()
        }
    }

    private func simulatePermissionRequest() {
#if DEBUG
        if let threadID {
            store.simulatePermissionRequest(forAgentThreadID: threadID)
        } else {
            store.simulatePermissionRequest()
        }
#endif
    }

    private func requestFileImport() {
        onFileImportRequested(threadID)
    }

    private func send(_ message: String) async {
        guard let threadID else {
            // Main chat: store.send handles @mention routing itself.
            await store.send(message)
            return
        }

        if let sourceProfile = sendProfile, sendBackend == .hermes {
            // Hermes agent panels can forward @mentions. Keep the current panel
            // in view (notifiesPanel: false) and echo the reply here.
            let routeResult = await store.routePromptIfAllowed(
                message,
                from: .hermes(profile: sourceProfile),
                sourceThreadID: threadID,
                notifiesPanel: false
            )
            if routeResult == .routed {
                return
            }
        }

        if case .acp(let agent) = sendBackend {
            await store.sendToACP(message, agent: agent, threadID: threadID)
        } else if case .agy = sendBackend {
            await store.sendToAgy(message, threadID: threadID)
        } else if case .claudeCLI = sendBackend {
            await store.sendToClaudeCLI(message, threadID: threadID)
        } else if let sendProfile {
            await store.sendAgentProfile(message, in: threadID, profile: sendProfile)
        }
    }

    /// Re-evaluates whether the view is parked at the bottom. The bottom anchor's
    /// offset (in scroll-space) sits near the viewport height when at the bottom
    /// and grows larger as the user scrolls up.
    private func recomputePinned() {
        guard viewportHeight > 0 else { return }
        isPinnedToBottom = bottomAnchorOffset <= viewportHeight + bottomFollowThreshold
    }

    private func scrollToBottom(with proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }

        if animated {
            withAnimation(.smooth) {
                action()
            }
        } else {
            action()
        }
    }

    /// Identity of the last message's streaming content. Changes as tokens,
    /// reasoning, or tool segments grow — drives the instant follow-scroll.
    /// Excludes message count (a new message is handled by its own animated
    /// scroll) so streaming never triggers the animated path.
    private func streamingTrigger(for thread: ChatThread) -> ChatScrollTrigger {
        guard let lastMessage = thread.messages.last else {
            return ChatScrollTrigger(threadID: thread.id)
        }

        return ChatScrollTrigger(
            threadID: thread.id,
            lastMessageID: lastMessage.id,
            content: lastMessage.content,
            segments: lastMessage.segments,
            reasoningText: lastMessage.reasoningText,
            attachmentCount: lastMessage.attachments.count
        )
    }
}

private struct ViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct BottomAnchorOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ChatScrollTrigger: Equatable {
    var threadID: UUID
    var lastMessageID: UUID?
    var content: String = ""
    var segments: [AssistantSegment] = []
    var reasoningText: String = ""
    var attachmentCount: Int = 0
}

enum ComposerPresentation {
    case floating
    case inline
}
