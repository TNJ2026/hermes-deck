import SwiftUI
import AppKit

struct RightSidebarView: View {
    @Bindable var store: ChatStore
    @Binding var draft: String
    @Binding var isFileImporterPresented: Bool
    @Binding var isContentVisible: Bool
    let width: CGFloat
    /// Upper bound for the panel content width — half of the detail area.
    let maxWidth: CGFloat
    let onFileImportRequested: (UUID?) -> Void
    let onResize: (CGFloat) -> Void
    @State private var dragStartWidth: CGFloat?
    @State private var liveWidth: CGFloat?
    @State private var isResizeHandleHovered = false
    @State private var selectedPanelItem: RightPanelItem = .agents
    @State private var selectedRightProfile: HermesProfile?
    // Agents-panel state hoisted here so it survives collapsing / switching the
    // right panel (AgentsPanelView is rebuilt each time it reappears).
    @State private var agentThreadID: UUID?
    @State private var agentIsSplit = false
    @State private var agentSecondProfile: HermesProfile?
    @State private var agentSecondThreadID: UUID?
    @State private var agentSecondDraft = ""
    /// Unsent composer text kept per panel so each agent panel (Agents / Claude /
    /// Codex / Gemini) has its own independent draft instead of sharing one.
    @State private var panelDrafts: [RightPanelItem: String] = [:]

    private func panelDraft(for item: RightPanelItem) -> Binding<String> {
        Binding(
            get: { panelDrafts[item] ?? "" },
            set: { panelDrafts[item] = $0 }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            if isContentVisible {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedPanelItem {
                    case .agents:
                        AgentsPanelView(
                            store: store,
                            draft: panelDraft(for: .agents),
                            isFileImporterPresented: $isFileImporterPresented,
                            selectedAgentProfile: $selectedRightProfile,
                            selectedAgentThreadID: $agentThreadID,
                            isSplit: $agentIsSplit,
                            secondAgentProfile: $agentSecondProfile,
                            secondAgentThreadID: $agentSecondThreadID,
                            secondDraft: $agentSecondDraft,
                            onFileImportRequested: onFileImportRequested
                        )
                    case .jobs:
                        JobsPanelView(store: store)
                    case .task:
                        TaskPanelView(store: store)
                    case .kanban:
                        KanbanPanelView(store: store)
                    case .gemini:
                        AgyPanelView(store: store)
                    case .claude:
                        ClaudeCLIPanelView(store: store)
                    case .codex:
                        if let agent = ACPAgent(panelItem: selectedPanelItem) {
                            ACPPanelView(
                                store: store,
                                agent: agent
                            )
                        } else {
                            RightPanelPlaceholderView(item: selectedPanelItem)
                        }
                    case .settings:
                        SettingsPanelView()
                    }
                }
                .padding(16)
                .frame(width: contentLayoutWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .frame(width: displayedWidth, alignment: .topLeading)
                .clipped()

                Divider()
            }

            RightPanelIconRail(
                selection: $selectedPanelItem,
                isVisible: $isContentVisible,
                items: availablePanelItems,
                badge: { item in
                    switch item {
                    case .kanban: store.activeKanbanTaskCount
                    default: nil
                    }
                }
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: store.agentProfiles.isEmpty) { _, noAgents in
            // Don't leave the user stuck on a hidden Agents panel.
            if noAgents, selectedPanelItem == .agents {
                selectedPanelItem = .task
            }
        }
        .onChange(of: store.pendingExternalAgentPanel) { _, backend in
            guard let backend, let item = RightPanelItem(externalBackend: backend) else { return }
            selectedPanelItem = item
            isContentVisible = true
            store.pendingExternalAgentPanel = nil
        }
        .overlay(alignment: .leading) {
            if isContentVisible {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: isResizeHandleHovered ? 3 : 1)

                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 10)
                        .contentShape(Rectangle())
                        .offset(x: -5)
                        .onHover { isHovering in
                            isResizeHandleHovered = isHovering
                            if isHovering {
                                NSCursor.resizeLeftRight.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if dragStartWidth == nil {
                                        dragStartWidth = displayedWidth
                                    }

                                    liveWidth = clampedWidth((dragStartWidth ?? displayedWidth) - value.translation.width)
                                }
                                .onEnded { _ in
                                    if let liveWidth {
                                        onResize(liveWidth)
                                    }

                                    liveWidth = nil
                                    dragStartWidth = nil
                                }
                        )
                }
            }
        }
    }

    private var displayedWidth: CGFloat {
        min(liveWidth ?? width, max(280, maxWidth))
    }

    /// While resizing a chat-bearing right panel, keep the inner content at the
    /// pre-drag width. The outer sidebar still follows the cursor, but Markdown
    /// in ChatDetailView does not reflow on every drag tick; it re-renders once
    /// the committed `width` updates at the end of the drag.
    private var contentLayoutWidth: CGFloat {
        guard isResizingChatPanel else { return displayedWidth }
        return min(dragStartWidth ?? width, max(280, maxWidth))
    }

    private var isResizingChatPanel: Bool {
        liveWidth != nil && selectedPanelItem.containsChatDetailView
    }

    private func clampedWidth(_ width: CGFloat) -> CGFloat {
        let upper = max(280, maxWidth)
        return min(max(width, 280), upper)
    }

    /// Hide the Agents rail icon when there are no non-default Hermes profiles.
    private var availablePanelItems: [RightPanelItem] {
        RightPanelItem.allCases.filter { $0 != .agents || !store.agentProfiles.isEmpty }
    }
}

struct RightPanelIconRail: View {
    @Binding var selection: RightPanelItem
    @Binding var isVisible: Bool
    var items: [RightPanelItem] = RightPanelItem.allCases
    var badge: (RightPanelItem) -> Int? = { _ in nil }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(items) { item in
                Button {
                    // Same icon while expanded → collapse; otherwise switch + show.
                    if selection == item, isVisible {
                        isVisible = false
                    } else {
                        selection = item
                        isVisible = true
                    }
                } label: {
                    item.icon
                        .frame(width: 28, height: 28)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .background(
                            selection == item ? Color.primary.opacity(0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay(alignment: .topTrailing) {
                            if let count = badge(item) {
                                Text("\(count)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3)
                                    .frame(minWidth: 14, minHeight: 14)
                                    .background(count > 0 ? Color.red : Color.secondary, in: Capsule())
                                    .offset(x: 1, y: -1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(item.title)
            }

            Spacer()
        }
        .padding(.top, 14)
        .padding(.horizontal, 8)
        .frame(width: 48)
        .frame(maxHeight: .infinity)
    }
}

enum RightPanelItem: String, CaseIterable, Identifiable {
    case agents
    case task
    case kanban
    case jobs
    case claude
    case codex
    case gemini
    case settings

    var id: String {
        rawValue
    }

    var containsChatDetailView: Bool {
        switch self {
        case .agents, .claude, .codex, .gemini:
            true
        case .task, .kanban, .jobs, .settings:
            false
        }
    }

    /// The panel that hosts the given external-agent backend, if any.
    init?(externalBackend backend: AgentBackend) {
        switch backend {
        case .acp(.codex): self = .codex
        case .claudeCLI: self = .claude
        case .agy: self = .gemini
        case .hermes: return nil
        }
    }

    var title: String {
        switch self {
        case .agents:
            "Agents"
        case .task:
            "Task"
        case .kanban:
            "Kanban"
        case .jobs:
            "Jobs"
        case .claude:
            "Claude"
        case .codex:
            "Codex"
        case .gemini:
            "Gemini"
        case .settings:
            "Settings"
        }
    }

    @ViewBuilder
    var icon: some View {
        switch self {
        case .agents:
            railImage("Agents", size: 20)
        case .task:
            railImage("Task", size: 16)
        case .kanban:
            railImage("Kanban", size: 18)
        case .jobs:
            railImage("Jobs", size: 18)
        case .claude:
            railImage("Claude", size: 16)
        case .codex:
            railImage("Codex", size: 16)
        case .gemini:
            railImage("Gemini", size: 18)
        case .settings:
            Image(systemName: "gearshape")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
    }

    private func railImage(_ name: String, size: CGFloat) -> some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.secondary)
    }
}
