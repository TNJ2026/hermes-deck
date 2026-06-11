import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Removes the hairline separator macOS draws under the titlebar/toolbar so the
/// content meets the title bar without a divider line.
private struct TitlebarSeparatorRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            nsView?.window?.titlebarSeparatorStyle = .none
        }
    }
}

struct ContentView: View {
    @Bindable var store: ChatStore
    @State private var searchText = ""
    @State private var draft = ""
    @State private var agentDraft = ""
    @State private var isFileImporterPresented = false
    @State private var fileImportTarget: FileImportTarget = .main
    @State private var layoutState = ChatLayoutState()
    @State private var selectedDestination: SidebarDestination = .chat
    @State private var showProfileMenu = false
    @AppStorage("appTheme") private var appThemeRaw = AppTheme.system.rawValue

    private var appTheme: AppTheme { AppTheme(rawValue: appThemeRaw) ?? .system }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                store: store,
                searchText: $searchText,
                selectedDestination: $selectedDestination,
                showProfileMenu: $showProfileMenu
            )
        } detail: {
            GeometryReader { geometry in
                // Guard the first layout pass where GeometryReader can report a
                // zero width: fall back to an unbounded max so the panel keeps
                // its default width instead of clamping down to the minimum.
                let maxRightWidth = geometry.size.width > 1 ? geometry.size.width / 2 : .greatestFiniteMagnitude

                HStack(spacing: 0) {
                    switch selectedDestination {
                    case .chat:
                        if store.hermesInstalled {
                            ChatDetailView(
                                store: store,
                                draft: $draft,
                                isFileImporterPresented: $isFileImporterPresented,
                                onFileImportRequested: { _ in
                                    fileImportTarget = .main
                                    isFileImporterPresented = true
                                }
                            )
                        } else {
                            HermesNotInstalledView()
                        }
                    case .sessions:
                        SessionListView(
                            store: store,
                            selectedDestination: $selectedDestination
                        )
                    case .tools:
                        ToolsView(store: store)
                    case .skills:
                        SkillsView(store: store)
                    }

                    RightSidebarView(
                        store: store,
                        draft: $agentDraft,
                        isFileImporterPresented: $isFileImporterPresented,
                        isContentVisible: $layoutState.isRightSidebarVisible,
                        width: layoutState.rightSidebarWidth,
                        maxWidth: maxRightWidth,
                        onFileImportRequested: { threadID in
                            guard let threadID else { return }
                            fileImportTarget = .agent(threadID)
                            isFileImporterPresented = true
                        }
                    ) { width in
                        layoutState.setRightSidebarWidth(width, maxWidth: maxRightWidth)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        // Profile display names can be raw lowercase ids (e.g. "researcher");
        // the window title capitalizes the first letter.
        .navigationTitle(windowTitle)
        .onAppear { NSApp.appearance = appTheme.nsAppearance }
        .onChange(of: appThemeRaw) { _, _ in NSApp.appearance = appTheme.nsAppearance }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    withAnimation(.smooth(duration: 0.18)) {
                        layoutState.toggleRightSidebar()
                    }
                } label: {
                    Label(
                        layoutState.isRightSidebarVisible ? "Hide Details" : "Show Details",
                        systemImage: "sidebar.right"
                    )
                }
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.data, .text, .image, .pdf],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                switch fileImportTarget {
                case .main:
                    store.attach(urls: urls)
                case .agent(let threadID):
                    store.attach(urls: urls, toAgentThreadID: threadID)
                }
            }
        }
        .task {
            store.refreshHermesInstalled()
            await store.loadProfiles()
        }
        .task {
            // Poll the kanban board so the rail badge stays current without
            // opening the panel.
            while !Task.isCancelled {
                await store.loadKanbanTasks(silent: true)
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .overlay { profileMenuOverlay }
        .background(TitlebarSeparatorRemover())
        .toastOverlay()
    }

    private var windowTitle: String {
        let name = store.selectedProfile.displayName
        guard let first = name.first else { return name }
        return first.uppercased() + name.dropFirst()
    }

    /// Profile picker popover, hosted at the window's top level so a click
    /// anywhere outside it (including the detail pane) dismisses it. The list is
    /// pinned to the sidebar's lower-left corner to match the picker button.
    @ViewBuilder
    private var profileMenuOverlay: some View {
        if showProfileMenu {
            ZStack(alignment: .bottomLeading) {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.smooth(duration: 0.15)) { showProfileMenu = false }
                    }

                ProfileMenuList(store: store, isPresented: $showProfileMenu) { profile in
                    if selectedDestination == .chat {
                        store.setProfileStartingNewThread(profile)
                    } else {
                        store.setProfile(profile)
                    }
                }
                .frame(width: 260, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 80)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// `nil` for `.system` so the app follows the OS appearance. Driving this
    /// through `NSApp.appearance` (rather than SwiftUI's `preferredColorScheme`)
    /// is the reliable way to switch back to System on macOS — setting
    /// `preferredColorScheme(nil)` after a non-nil value does not restore the
    /// system appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

#Preview {
    ContentView(store: ChatStore(agentClient: StubHermesAgentClient(reply: "Preview reply")))
}
