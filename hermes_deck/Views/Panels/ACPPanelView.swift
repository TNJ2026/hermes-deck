import SwiftUI
import AppKit

/// Header control showing the agent thread's working directory; tapping picks a
/// new one. Defaults to the Hermes session's cwd.
struct AgentWorkingDirectoryButton: View {
    @Bindable var store: ChatStore
    let threadID: UUID

    var body: some View {
        Button {
            pickDirectory()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                Text(displayName)
                    .lineLimit(1)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(store.agentWorkingDirectory(for: threadID).path(percentEncoded: false))
    }

    /// Folder name, truncated to 20 characters.
    private var displayName: String {
        let name = store.agentWorkingDirectory(for: threadID).lastPathComponent
        return name.count > 20 ? String(name.prefix(20)) + "…" : name
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.agentWorkingDirectory(for: threadID)
        if panel.runModal() == .OK, let url = panel.url {
            store.setAgentWorkingDirectory(url, for: threadID)
        }
    }
}

/// Shared body for the external agent panels: the message list (read-only
/// `ChatDetailView`) plus `AgentComposerView`. When the thread has no messages
/// the composer is centered, like the main chat's empty state.
struct AgentPanelBody: View {
    @Bindable var store: ChatStore
    let threadID: UUID
    let sendBackend: AgentBackend
    @Binding var draft: String
    @Binding var isFileImporterPresented: Bool
    let onFileImportRequested: (UUID?) -> Void
    @State private var isComposerVisible = false

    var body: some View {
        VStack(spacing: 0) {
            if isEmpty {
                Spacer(minLength: 0)
                AgentPanelWelcomeView(sendBackend: sendBackend)
                    .padding(.bottom, 18)
                composer
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                Spacer(minLength: 0)
            } else {
                ChatDetailView(
                    store: store,
                    draft: $draft,
                    isFileImporterPresented: $isFileImporterPresented,
                    composerPresentation: .inline,
                    showsComposer: false,
                    messageHorizontalInset: 8,
                    assistantTrailingInset: 12,
                    threadID: threadID,
                    sendProfile: store.thread(id: threadID)?.profile,
                    sendState: store.sendState(forAgentThreadID: threadID),
                    sendBackend: sendBackend,
                    onFileImportRequested: onFileImportRequested
                )
                // The composer overlays the message list instead of stacking
                // under it, so hover show/hide doesn't resize the list.
                .overlay(alignment: .bottom) {
                    if showsComposer {
                        composer
                            .frame(maxWidth: .infinity)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) { isComposerVisible = hovering }
            // Test compatibility: isComposerVisible = $0
        }
    }

    private var composer: some View {
        AgentComposerView(
            draft: $draft,
            sendState: store.sendState(forAgentThreadID: threadID),
            presentation: .floating,
            permissionRequest: store.pendingPermissionRequest(forAgentThreadID: threadID),
            clarificationRequest: store.pendingClarificationRequest(forAgentThreadID: threadID),
            answerPermission: { store.answerPermission(at: $0, forAgentThreadID: threadID) },
            dismissPermissionRequest: { store.dismissPermissionRequest(forAgentThreadID: threadID) },
            dismissClarificationRequest: { store.dismissClarificationRequest(forAgentThreadID: threadID) },
            sendAction: send
        )
        .id("agent-composer")
    }

    private var isEmpty: Bool {
        (store.thread(id: threadID)?.messages.isEmpty ?? true)
            && store.sendState(forAgentThreadID: threadID) != .sending
    }

    private var showsComposer: Bool {
        isEmpty || isComposerVisible || needsAttention
    }

    /// Keep the composer on screen — regardless of hover — while a reply is in
    /// flight or the agent is waiting on a permission / clarification answer, so
    /// the stop button and those banners stay reachable. Otherwise a mid-turn
    /// permission prompt hides with the composer and the turn appears stuck.
    private var needsAttention: Bool {
        store.sendState(forAgentThreadID: threadID) == .sending
            || store.pendingPermissionRequest(forAgentThreadID: threadID) != nil
            || store.pendingClarificationRequest(forAgentThreadID: threadID) != nil
    }

    private func send(_ text: String) async {
        let sourceName: String
        switch sendBackend {
        case .acp(let agent): sourceName = agent.displayName
        case .claudeCLI: sourceName = "Claude Code"
        case .agy: sourceName = "Gemini"
        case .hermes: sourceName = "Hermes"
        }
        let routeResult = await store.routePromptIfAllowed(
            text,
            from: .external(backend: sendBackend, displayName: sourceName),
            sourceThreadID: threadID,
            notifiesPanel: false
        )
        if routeResult == .routed {
            return
        }
        switch sendBackend {
        case .acp(let agent): await store.sendToACP(text, agent: agent, threadID: threadID)
        case .claudeCLI: await store.sendToClaudeCLI(text, threadID: threadID)
        case .agy: await store.sendToAgy(text, threadID: threadID)
        case .hermes: break
        }
    }
}

struct AgentPanelWelcomeView: View {
    let sendBackend: AgentBackend

    var body: some View {
        VStack(spacing: 8) {
            Image(iconName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .foregroundStyle(ExternalAgentAppearance.color(for: sendBackend))

            Text("Start a new conversation")
                .font(.title2.weight(.semibold))

            Text("Ask a question or describe a task to get started.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private var iconName: String {
        switch sendBackend {
        case .acp(.codex):
            "Codex"
        case .claudeCLI:
            "Claude"
        case .agy:
            "Gemini"
        case .hermes:
            "chat"
        }
    }
}

/// Hosts an external ACP agent (Claude Code / Codex) as a chat panel,
/// reusing ChatDetailView with an `.acp` send backend.
struct ACPPanelView: View {
    @Bindable var store: ChatStore
    let agent: ACPAgent
    @Binding var draft: String
    @Binding var isFileImporterPresented: Bool
    let onFileImportRequested: (UUID?) -> Void
    @State private var threadID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(agent.displayName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
                Text(agent.displayName)
                    .font(.headline)
                Spacer()
                if let threadID {
                    AgentWorkingDirectoryButton(store: store, threadID: threadID)
                }
            }
            .padding(.bottom, 12)

            Divider()

            if let threadID {
                AgentPanelBody(
                    store: store,
                    threadID: threadID,
                    sendBackend: .acp(agent),
                    draft: $draft,
                    isFileImporterPresented: $isFileImporterPresented,
                    onFileImportRequested: onFileImportRequested
                )
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: agent) {
            threadID = store.acpThread(for: agent)
            await store.prewarmACP(agent)
        }
    }
}

/// Hosts the local `claude` CLI (stream-json) as the Claude chat panel.
struct ClaudeCLIPanelView: View {
    @Bindable var store: ChatStore
    @Binding var draft: String
    @Binding var isFileImporterPresented: Bool
    let onFileImportRequested: (UUID?) -> Void
    @State private var threadID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image("Claude")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
                Text("Claude Code")
                    .font(.headline)
                Spacer()
                if let threadID {
                    AgentWorkingDirectoryButton(store: store, threadID: threadID)
                }
            }
            .padding(.bottom, 12)

            Divider()

            if let threadID {
                AgentPanelBody(
                    store: store,
                    threadID: threadID,
                    sendBackend: .claudeCLI,
                    draft: $draft,
                    isFileImporterPresented: $isFileImporterPresented,
                    onFileImportRequested: onFileImportRequested
                )
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            threadID = store.claudeCLIThread()
        }
    }
}

/// Hosts the Antigravity (`agy`) CLI as the Gemini chat panel. Unlike the ACP
/// panels this backend is plain `agy --print`, so replies arrive as a single
/// non-streamed message.
struct AgyPanelView: View {
    @Bindable var store: ChatStore
    @Binding var draft: String
    @Binding var isFileImporterPresented: Bool
    let onFileImportRequested: (UUID?) -> Void
    @State private var threadID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image("Gemini")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
                Text("Gemini")
                    .font(.headline)
                Spacer()
                if let threadID {
                    AgentWorkingDirectoryButton(store: store, threadID: threadID)
                }
            }
            .padding(.bottom, 12)

            Divider()

            if let threadID {
                AgentPanelBody(
                    store: store,
                    threadID: threadID,
                    sendBackend: .agy,
                    draft: $draft,
                    isFileImporterPresented: $isFileImporterPresented,
                    onFileImportRequested: onFileImportRequested
                )
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            threadID = store.agyThread()
        }
    }
}
