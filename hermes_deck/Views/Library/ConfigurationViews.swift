import SwiftUI

struct ChipFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = rows(for: subviews, in: proposal.width ?? .infinity)
        return CGSize(
            width: proposal.width ?? rows.map(\.width).max() ?? 0,
            height: rows.map(\.height).reduce(0, +) + CGFloat(max(rows.count - 1, 0)) * spacing
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = rows(for: subviews, in: bounds.width)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(for subviews: Subviews, in availableWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let nextWidth = current.items.isEmpty ? size.width : current.width + spacing + size.width

            if !current.items.isEmpty, nextWidth > availableWidth {
                rows.append(current)
                current = Row()
            }

            current.append(index: index, size: size, spacing: spacing)
        }

        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        mutating func append(index: Int, size: CGSize, spacing: CGFloat) {
            if !items.isEmpty {
                width += spacing
            }
            items.append((index, size))
            width += size.width
            height = max(height, size.height)
        }
    }
}

struct PluginInfoCapsule: View {
    var text: String
    var systemImage: String

    var body: some View {
        if !text.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .imageScale(.small)
                Text(displayText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .fixedSize(horizontal: true, vertical: false)
                .background(Color.primary.opacity(0.08), in: Capsule())
        }
    }

    private var displayText: String {
        if text.count <= 20 {
            return text
        }
        return "\(text.prefix(20))..."
    }
}

struct ToolsView: View {
    @Bindable var store: ChatStore
    @State private var isRefreshHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Tools")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    Task {
                        await store.loadInstalledTools()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .padding(6)
                        .background(isRefreshHovered ? Color.primary.opacity(0.08) : Color.clear)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { isRefreshHovered = $0 }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            switch store.toolListState {
            case .idle, .loading:
                Spacer()
                ProgressView("Loading tools...")
                Spacer()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Failed to Load Tools", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        Task {
                            await store.loadInstalledTools()
                        }
                    }
                }
            case .loaded(let tools):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        DeckDelegationToolInstallRow(
                            status: store.deckDelegationToolStatus,
                            installState: store.deckDelegationToolInstallState,
                            onInstall: {
                                Task {
                                    await store.installDeckDelegationTool()
                                }
                            }
                        )

                        if tools.isEmpty {
                            ContentUnavailableView("No Tools", systemImage: "wrench.and.screwdriver")
                                .frame(maxWidth: .infinity)
                        } else {
                            ForEach(tools) { tool in
                                InstalledToolRow(
                                    tool: tool,
                                    onEnabledChange: { enabled in
                                        Task {
                                            await store.setTool(tool, enabled: enabled)
                                        }
                                    }
                                )
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task {
            if case .idle = store.toolListState {
                await store.loadInstalledTools()
            }
        }
        .onChange(of: store.selectedProfile.id) { _, _ in
            Task { await store.loadInstalledTools() }
        }
    }
}

struct DeckDelegationToolInstallRow: View {
    var status: DeckDelegationToolStatus
    var installState: DeckDelegationToolInstallState
    var onInstall: @MainActor () -> Void

    private var isInstalling: Bool {
        installState == .installing
    }

    private var didConfirmInstall: Bool {
        installState == .installed
    }

    private var isInstalled: Bool {
        switch status {
        case .missing:
            return false
        case .current, .outdated:
            return true
        }
    }

    private var needsUpdate: Bool {
        if case .outdated = status { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("deck_delegate_agent")
                        .font(.title3.weight(.semibold))
                    PluginInfoCapsule(text: "Hermes Deck", systemImage: "app.connected.to.app.below.fill")
                }

                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onInstall()
            } label: {
                HStack(spacing: 6) {
                    if isInstalling {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: didConfirmInstall || isCurrent ? "checkmark.circle.fill" : (isInstalled ? "arrow.clockwise" : "square.and.arrow.down"))
                    }
                    Text(buttonText)
                }
                .frame(minWidth: 96)
            }
            .disabled(isInstalling || (isCurrent && !needsUpdate))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
                .allowsHitTesting(false)
        }
    }

    private var buttonText: String {
        if isInstalling { return "Installing" }
        if didConfirmInstall { return "Installed" }
        if isCurrent { return "Installed" }
        if isInstalled { return "Update" }
        return "Install"
    }

    private var statusText: String {
        if didConfirmInstall { return "Installed. Restart the gateway to load the latest tool." }
        switch status {
        case .missing:
            break
        case .current(let version):
            return "Installed for the selected profile (v\(version)). Restart the gateway after updating."
        case .outdated(let installedVersion, let bundledVersion):
            let installed = installedVersion ?? "unknown"
            return "Update available: installed v\(installed), bundled v\(bundledVersion). Restart the gateway after updating."
        }
        switch installState {
        case .idle:
            return "Install the Deck delegation tool for the selected profile."
        case .installing:
            return isInstalled ? "Updating for the selected profile..." : "Installing for the selected profile..."
        case .installed:
            return "Installed. Restart the gateway to load the latest tool."
        case .failed(let message):
            return message
        }
    }

    private var statusColor: Color {
        if didConfirmInstall { return .secondary }
        if needsUpdate { return .orange }
        if isInstalled { return .secondary }
        if case .failed = installState { return .red }
        return .secondary
    }

    private var isCurrent: Bool {
        if case .current = status { return true }
        return false
    }
}

struct InstalledToolRow: View {
    let tool: HermesInstalledTool
    var onEnabledChange: @MainActor (Bool) -> Void
    @State private var isEnabled: Bool

    init(tool: HermesInstalledTool, onEnabledChange: @escaping @MainActor (Bool) -> Void) {
        self.tool = tool
        self.onEnabledChange = onEnabledChange
        _isEnabled = State(initialValue: tool.status == "Enabled")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(tool.name)
                        .font(.title3.weight(.semibold))
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 120), spacing: 8, alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    PluginInfoCapsule(text: tool.source, systemImage: "tray.full")
                }

                if !tool.summary.isEmpty {
                    Text(tool.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(
                isEnabled ? "Disable \(tool.name)" : "Enable \(tool.name)",
                isOn: Binding(
                    get: { isEnabled },
                    set: { enabled in
                        isEnabled = enabled
                        Task { @MainActor in
                            onEnabledChange(enabled)
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .scaleEffect(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
                .allowsHitTesting(false)
        }
        .onChange(of: tool.status) { _, status in
            isEnabled = status == "Enabled"
        }
    }
}

struct SkillsView: View {
    @Bindable var store: ChatStore
    @State private var isRefreshHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Skills")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    Task {
                        await store.loadInstalledSkills()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .padding(6)
                        .background(isRefreshHovered ? Color.primary.opacity(0.08) : Color.clear)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { isRefreshHovered = $0 }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            switch store.skillListState {
            case .idle, .loading:
                Spacer()
                ProgressView("Loading skills...")
                Spacer()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Failed to Load Skills", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        Task {
                            await store.loadInstalledSkills()
                        }
                    }
                }
            case .loaded(let skills):
                if skills.isEmpty {
                    ContentUnavailableView("No Skills", systemImage: "wand.and.stars")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            // `agent-routing` is a non-Deck (headless/cron) skill;
                            // the Deck hides it to keep the list Deck-relevant.
                            ForEach(skillGroups(from: skills.filter {
                                $0.name.caseInsensitiveCompare(ChatStore.agentRoutingSkillName) != .orderedSame
                            }), id: \.category) { group in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(group.title)
                                        .font(.headline)
                                        .foregroundStyle(.secondary)

                                    LazyVStack(alignment: .leading, spacing: 12) {
                                        ForEach(group.skills) { skill in
                                            InstalledSkillRow(
                                                skill: skill,
                                                onEnabledChange: { enabled in
                                                    Task {
                                                        await store.setSkill(skill, enabled: enabled)
                                                    }
                                                }
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        .padding(24)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task {
            if case .idle = store.skillListState {
                await store.loadInstalledSkills()
            }
        }
        .onChange(of: store.selectedProfile.id) { _, _ in
            Task { await store.loadInstalledSkills() }
        }
    }

    private func skillGroups(from skills: [HermesInstalledSkill]) -> [(category: String, title: String, skills: [HermesInstalledSkill])] {
        let grouped = Dictionary(grouping: skills) { skill in
            skill.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Uncategorized" : skill.category
        }

        return grouped.keys.sorted {
            if $0 == "Uncategorized" { return false }
            if $1 == "Uncategorized" { return true }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }.compactMap { category in
            guard let items = grouped[category] else { return nil }
            return (
                category,
                category,
                items.sorted { lhs, rhs in
                    lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            )
        }
    }
}

struct InstalledSkillRow: View {
    let skill: HermesInstalledSkill
    var onEnabledChange: @MainActor (Bool) -> Void
    @State private var isEnabled: Bool

    init(skill: HermesInstalledSkill, onEnabledChange: @escaping @MainActor (Bool) -> Void) {
        self.skill = skill
        self.onEnabledChange = onEnabledChange
        _isEnabled = State(initialValue: skill.status.caseInsensitiveCompare("enabled") == .orderedSame)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(skill.name)
                        .font(.title3.weight(.semibold))
                }

                ChipFlowLayout(spacing: 10) {
                    PluginInfoCapsule(text: skill.source, systemImage: "tray.full")
                    PluginInfoCapsule(text: skill.category, systemImage: "folder")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(
                isEnabled ? "Disable \(skill.name)" : "Enable \(skill.name)",
                isOn: Binding(
                    get: { isEnabled },
                    set: { enabled in
                        isEnabled = enabled
                        Task { @MainActor in
                            onEnabledChange(enabled)
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .scaleEffect(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
                .allowsHitTesting(false)
        }
        .onChange(of: skill.status) { _, status in
            isEnabled = status.caseInsensitiveCompare("enabled") == .orderedSame
        }
    }
}
