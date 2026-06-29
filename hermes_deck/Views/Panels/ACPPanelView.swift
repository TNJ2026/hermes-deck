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

/// Shared body for the external agent panels: the same inline
/// `AgentsComposerView` chat the Agents panel uses, minus the attachment
/// button, with the panel's branded welcome above the empty-thread composer.
struct AgentPanelBody: View {
    @Bindable var store: ChatStore
    let threadID: UUID
    let sendBackend: AgentBackend
    @Binding var draft: String
    @Binding var isFileImporterPresented: Bool
    let onFileImportRequested: (UUID?) -> Void

    var body: some View {
        ChatDetailView(
            store: store,
            draft: $draft,
            isFileImporterPresented: $isFileImporterPresented,
            composerPresentation: .inline,
            showsComposer: true,
            messageHorizontalInset: 8,
            assistantTrailingInset: 12,
            usesAgentsComposer: true,
            composerShowsAttachmentButton: false,
            emptyStateHeader: AnyView(AgentPanelWelcomeView(sendBackend: sendBackend)),
            threadID: threadID,
            sendProfile: store.thread(id: threadID)?.profile,
            sendState: store.sendState(forAgentThreadID: threadID),
            sendBackend: sendBackend,
            onFileImportRequested: onFileImportRequested
        )
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
                AgentTerminalView(
                    command: [agent == .codex ? "codex" : agent.rawValue],
                    workingDirectory: store.agentWorkingDirectory(for: threadID)
                )
                .id(store.agentWorkingDirectory(for: threadID))
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
                AgentTerminalView(
                    command: ["claude"],
                    workingDirectory: store.agentWorkingDirectory(for: threadID)
                )
                .id(store.agentWorkingDirectory(for: threadID))
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
                AgentTerminalView(
                    command: ["agy"],
                    workingDirectory: store.agentWorkingDirectory(for: threadID)
                )
                .id(store.agentWorkingDirectory(for: threadID))
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
