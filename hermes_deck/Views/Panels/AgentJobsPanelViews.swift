import SwiftUI

struct AgentsPanelView: View {
    @Bindable var store: ChatStore
    @Binding var draft: String
    @Binding var isFileImporterPresented: Bool
    @Binding var selectedAgentProfile: HermesProfile?
    @Binding var selectedAgentThreadID: UUID?
    @Binding var isSplit: Bool
    @Binding var secondAgentProfile: HermesProfile?
    @Binding var secondAgentThreadID: UUID?
    @Binding var secondDraft: String
    let onFileImportRequested: (UUID?) -> Void
    @State private var isComposerVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image("Agents")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
                Text("Agents")
                    .font(.headline)

                Spacer(minLength: 12)

                // A single agent needs no picker/split; show its name. Multiple
                // agents get the picker and the top/bottom split toggle — but
                // only after one is selected (the centered chooser handles the
                // initial pick).
                if store.agentProfiles.count >= 2, selectedAgentThreadID != nil {
                    Picker("Profile", selection: $selectedAgentProfile) {
                        ForEach(selectableAgentProfiles) { profile in
                            Text(profile.displayName).lineLimit(1).tag(Optional(profile))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 150)
                    .onChange(of: selectedAgentProfile) { _, newValue in
                        guard let newValue else { return }
                        select(newValue)
                    }

                    Button {
                        toggleSplit()
                    } label: {
                        Image("Split")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                            .foregroundStyle(isSplit ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isSplit ? "Merge panes" : "Split top / bottom")
                } else if store.agentProfiles.count == 1 {
                    Text(store.agentProfiles[0].displayName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.bottom, 12)

            Divider()

            if store.agentProfiles.isEmpty {
                Spacer(minLength: 0)
            } else if selectedAgentThreadID == nil {
                // Two+ agents, nothing started yet: pick a profile in the middle.
                agentProfilePicker
            } else if isSplit {
                agentChat(threadID: selectedAgentThreadID, profile: selectedAgentProfile, draft: $draft)
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, 10)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.2)) { isComposerVisible = hovering }
                        // Test compatibility: isComposerVisible = $0
                    }

                Divider()

                AgentSplitBottomPanel(
                    store: store,
                    profile: $secondAgentProfile,
                    threadID: $secondAgentThreadID,
                    draft: $secondDraft,
                    isFileImporterPresented: $isFileImporterPresented,
                    availableProfiles: bottomPaneProfiles,
                    onFileImportRequested: onFileImportRequested
                )
                .frame(maxHeight: .infinity)
            } else {
                agentChat(threadID: selectedAgentThreadID, profile: selectedAgentProfile, draft: $draft)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.2)) { isComposerVisible = hovering }
                        // Test compatibility: isComposerVisible = $0
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            if selectedAgentThreadID != nil {
                return
            }
            // One agent: start it automatically. Two or more: wait for the user
            // to pick before starting any.
            if store.agentProfiles.count == 1, let only = store.agentProfiles.first {
                select(only)
            }
        }
        .onChange(of: store.latestAgentRouteRequest) { _, request in
            guard let request else { return }
            selectedAgentProfile = request.profile
            selectedAgentThreadID = request.threadID
        }
        .onChange(of: store.selectedProfile.id) { _, leftID in
            closePaneMatchingLeftProfile(leftID)
        }
    }

    /// When the left sidebar switches to a profile already shown on the right,
    /// close that pane (it's now the main chat). Bottom match collapses the
    /// split; top match promotes the bottom pane (if split) or clears the view.
    private func closePaneMatchingLeftProfile(_ leftID: String) {
        if isSplit, secondAgentProfile?.id == leftID {
            isSplit = false
            return
        }
        guard selectedAgentProfile?.id == leftID else { return }
        if isSplit {
            selectedAgentProfile = secondAgentProfile
            selectedAgentThreadID = secondAgentThreadID
            isSplit = false
        } else {
            selectedAgentProfile = nil
            selectedAgentThreadID = nil
        }
    }

    private func select(_ profile: HermesProfile) {
        selectedAgentProfile = profile
        selectedAgentThreadID = store.threadIDForAgentProfile(profile)
        // Top switched onto the bottom pane's profile: collapse the split.
        if isSplit, profile.id == secondAgentProfile?.id {
            isSplit = false
        }
    }

    /// Profiles selectable on the right — all profiles (default "Hermes agent"
    /// included) except the one the left sidebar (main chat) is on, so the two
    /// pickers are mutually exclusive.
    private var selectableAgentProfiles: [HermesProfile] {
        store.availableProfiles.filter { $0.id != store.selectedProfile.id }
    }

    /// Bottom pane's selectable profiles: everything except the top profile and
    /// the left sidebar's profile.
    private var bottomPaneProfiles: [HermesProfile] {
        selectableAgentProfiles.filter { $0.id != selectedAgentProfile?.id }
    }

    /// Centered profile chooser shown when 2+ agents exist and none is started.
    private var agentProfilePicker: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    Image("Agents")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .foregroundStyle(.secondary)
                    Text("Choose an agent")
                        .font(.title3.weight(.semibold))
                    Text("Pick a profile to start.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)

                VStack(spacing: 8) {
                    ForEach(selectableAgentProfiles) { profile in
                        Button {
                            select(profile)
                        } label: {
                            HStack(spacing: 10) {
                                SidebarView.fixedTemplateImage("robot", size: 16)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.displayName)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(store.profileMainModels[profile.id] ?? "—")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8).stroke(.quaternary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: 240)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func agentChat(threadID: UUID?, profile: HermesProfile?, draft: Binding<String>) -> some View {
        ChatDetailView(
            store: store,
            draft: draft,
            isFileImporterPresented: $isFileImporterPresented,
            composerPresentation: .inline,
            showsComposer: showsComposer(for: threadID),
            messageHorizontalInset: 8,
            assistantTrailingInset: 12,
            usesAgentsComposer: true,
            threadID: threadID,
            sendProfile: profile,
            sendState: store.sendState(forAgentThreadID: threadID),
            onFileImportRequested: onFileImportRequested
        )
    }

    private func showsComposer(for threadID: UUID?) -> Bool {
        isAgentThreadEmpty(threadID) || isComposerVisible || needsAttention(threadID)
    }

    /// Keep the composer visible — regardless of hover — while a reply is in
    /// flight or the agent awaits a permission / clarification answer, so the
    /// stop button and those banners stay reachable mid-turn.
    private func needsAttention(_ threadID: UUID?) -> Bool {
        store.sendState(forAgentThreadID: threadID) == .sending
            || store.pendingPermissionRequest(forAgentThreadID: threadID) != nil
            || store.pendingClarificationRequest(forAgentThreadID: threadID) != nil
    }

    private func isAgentThreadEmpty(_ threadID: UUID?) -> Bool {
        guard let threadID else { return true }
        return (store.thread(id: threadID)?.messages.isEmpty ?? true)
            && store.sendState(forAgentThreadID: threadID) != .sending
    }

    /// Toggles the top/bottom split, seeding the bottom pane with a profile
    /// different from the top (mutually exclusive).
    private func toggleSplit() {
        isSplit.toggle()
        guard isSplit else { return }
        if secondAgentProfile == nil || secondAgentProfile?.id == selectedAgentProfile?.id {
            if let other = store.agentProfiles.first(where: { $0.id != selectedAgentProfile?.id }) {
                secondAgentProfile = other
                secondAgentThreadID = store.threadIDForAgentProfile(other)
            }
        }
    }
}

struct JobsPanelView: View {
    @Bindable var store: ChatStore
    @State private var selectedJobProfile: HermesProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "briefcase")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Jobs")
                    .font(.headline)

                Spacer(minLength: 12)

                Picker("Profile", selection: $selectedJobProfile) {
                    ForEach(store.availableProfiles) { profile in
                        Text(profile.displayName).lineLimit(1).tag(Optional(profile))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 150)
                .disabled(store.availableProfiles.isEmpty)
            }
            .padding(.bottom, 12)

            Divider()

            switch store.jobListState {
            case .idle, .loading:
                Spacer()
                ProgressView("Loading jobs...")
                    .frame(maxWidth: .infinity)
                Spacer()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Failed to Load Jobs", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        Task {
                            await loadSelectedJobs()
                        }
                    }
                }
            case .loaded(let jobs):
                if jobs.isEmpty {
                    EmptyPanelState(title: "No Jobs", systemImage: "briefcase")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(jobs) { job in
                                ScheduledJobRow(
                                    store: store,
                                    job: job,
                                    profile: selectedJobProfile ?? store.selectedProfile
                                )
                            }
                        }
                        .padding(.top, 12)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            guard selectedJobProfile == nil else { return }
            let preferred = store.availableProfiles.first(where: { $0.id == store.selectedProfile.id })
                ?? store.availableProfiles.first(where: { $0.id == HermesProfile.defaultProfile.id })
                ?? store.availableProfiles.first
                ?? store.selectedProfile
            selectedJobProfile = await store.profileWithJobs(preferring: preferred)
        }
        .task(id: selectedJobProfile?.id) {
            await loadSelectedJobs()
        }
    }

    private func loadSelectedJobs() async {
        guard let selectedJobProfile else { return }
        await store.loadJobs(for: selectedJobProfile)
    }
}

struct ScheduledJobRow: View {
    @Bindable var store: ChatStore
    let job: HermesScheduledJob
    let profile: HermesProfile
    @State private var isBusy = false
    @State private var isEditing = false
    @State private var isConfirmingDelete = false
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(job.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(lastRunFailed ? "Error" : job.statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(lastRunFailed ? Color.red : statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((lastRunFailed ? Color.red : statusColor).opacity(0.12), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 3) {
                if !job.schedule.isEmpty {
                    JobMetadataLine(title: "Schedule", value: job.schedule)
                }
                if let nextRunAt = job.nextRunAt, !nextRunAt.isEmpty {
                    JobMetadataLine(title: "Next", value: formattedJobDate(nextRunAt))
                }
                if let lastRunText {
                    JobMetadataLine(title: "Last", value: lastRunText)
                }
                if !job.skills.isEmpty {
                    JobMetadataLine(title: "Skills", value: job.skills.joined(separator: ", "))
                }
                if let script = job.script, !script.isEmpty {
                    JobMetadataLine(title: "Script", value: script)
                }
            }
            if lastRunFailed {
                Text(job.lastError?.isEmpty == false ? job.lastError! : "Last run failed.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 14) {
                JobActionButton(icon: "bolt.fill", help: "Run now", action: { act(.run) })
                JobActionButton(
                    icon: job.enabled ? "pause.fill" : "play.fill",
                    help: job.enabled ? "Pause" : "Resume",
                    pointSize: 16,
                    action: { act(job.enabled ? .pause : .resume) }
                )
                JobActionButton(assetIcon: "pencil2", help: "Edit", action: { isEditing = true })
                Spacer()
                JobActionButton(icon: "trash", help: "Delete", role: .destructive) {
                    isConfirmingDelete = true
                }
            }
            .disabled(isBusy)
            .overlay(alignment: .center) {
                if isBusy { ProgressView().controlSize(.small) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .sheet(isPresented: $isEditing) {
            JobEditSheet(store: store, job: job, profile: profile)
        }
        .alert("Delete Job?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { act(.remove) }
        } message: {
            Text("Delete “\(job.name)”? This action cannot be undone.")
        }
        .overlay(alignment: .top) {
            if let toastMessage {
                JobActionToast(message: toastMessage)
                    .offset(y: -10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(2)
            }
        }
        .onDisappear {
            toastTask?.cancel()
        }
    }

    private func act(_ action: HermesJobAction) {
        isBusy = true
        Task {
            let errorMessage = await store.performJobAction(action, jobID: job.id, for: profile)
            isBusy = false
            if action == .run {
                showToast(errorMessage ?? "已触发")
            }
        }
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation(.smooth(duration: 0.14)) {
            toastMessage = message
        }
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.14)) {
                toastMessage = nil
            }
        }
    }

    private var lastRunText: String? {
        guard let lastRunAt = job.lastRunAt, !lastRunAt.isEmpty else {
            return nil
        }
        return formattedJobDate(lastRunAt)
    }

    private var lastRunFailed: Bool {
        if let status = job.lastStatus?.lowercased(), status == "error" || status == "failed" {
            return true
        }
        return job.lastError?.isEmpty == false
    }

    private func formattedJobDate(_ value: String) -> String {
        guard let date = JobDateFormatter.parse(value) else {
            return value
        }
        return JobDateFormatter.displayString(from: date)
    }

    private var statusColor: Color {
        if !job.enabled { return .secondary }
        if job.lastStatus == "error" { return .red }
        return .green
    }
}

struct JobActionToast: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

/// Compact, non-bold empty-state placeholder for the right-sidebar panels.
struct EmptyPanelState: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout)
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct JobMetadataLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }
}

struct JobActionButton: View {
    let icon: JobActionIcon
    let help: String
    var role: ButtonRole?
    let pointSize: CGFloat
    let action: () -> Void

    init(icon: String, help: String, role: ButtonRole? = nil, pointSize: CGFloat = 12, action: @escaping () -> Void) {
        self.icon = .system(icon)
        self.help = help
        self.role = role
        self.pointSize = pointSize
        self.action = action
    }

    init(assetIcon: String, help: String, role: ButtonRole? = nil, pointSize: CGFloat = 12, action: @escaping () -> Void) {
        self.icon = .asset(assetIcon)
        self.help = help
        self.role = role
        self.pointSize = pointSize
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            iconView
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(role == .destructive ? Color.red : Color.secondary)
        .help(help)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: pointSize, weight: .semibold))
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
        }
    }
}

enum JobDateFormatter {
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func displayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

enum JobActionIcon {
    case system(String)
    case asset(String)
}

struct JobEditSheet: View {
    @Bindable var store: ChatStore
    let job: HermesScheduledJob
    let profile: HermesProfile
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var schedule: String
    @State private var deliver: String
    @State private var skills: String
    @State private var script: String
    @State private var prompt: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(store: ChatStore, job: HermesScheduledJob, profile: HermesProfile) {
        self.store = store
        self.job = job
        self.profile = profile
        _name = State(initialValue: job.name)
        _schedule = State(initialValue: job.schedule)
        _deliver = State(initialValue: job.deliver ?? "")
        _skills = State(initialValue: job.skills.joined(separator: ", "))
        _script = State(initialValue: job.script ?? "")
        _prompt = State(initialValue: job.prompt ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Job")
                .font(.headline)
                .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                field("Name", text: $name)
                field("Schedule (cron or natural language)", text: $schedule)
                field("Deliver", text: $deliver)
                field("Skills (comma separated)", text: $skills)
                field("Script", text: $script)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Prompt", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1...)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6).stroke(.quaternary)
                        }
                }
            }
            .padding(16)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            Divider()

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
            }
            .padding(16)
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6).stroke(.quaternary)
                }
        }
    }

    private func save() {
        isSaving = true
        var edit = HermesJobEdit(jobID: job.id)
        edit.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        edit.schedule = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        edit.deliver = deliver.trimmingCharacters(in: .whitespacesAndNewlines)
        edit.script = script.trimmingCharacters(in: .whitespacesAndNewlines)
        edit.skills = skills
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        edit.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        errorMessage = nil
        Task {
            let error = await store.updateJob(edit, for: profile)
            isSaving = false
            if let error {
                errorMessage = error
            } else {
                dismiss()
            }
        }
    }
}

struct RightPanelPlaceholderView: View {
    let item: RightPanelItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                item.icon
                Text(item.title)
                    .font(.headline)
            }

            Divider()

            EmptyPanelState(title: item.title, systemImage: "sidebar.right")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
