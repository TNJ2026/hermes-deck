import Foundation

/// Library/config loading: profiles, gateways, models, tools, skills,
/// jobs, and kanban list states.
extension ChatStore {
    func loadProfiles() async {
        do {
            let profiles = try await profileProvider.profiles()
            guard !profiles.isEmpty else { return }
            availableProfiles = profiles
            if let refreshed = profiles.first(where: { $0.id == selectedProfile.id }) {
                setProfile(refreshed)
            } else if let first = profiles.first {
                setProfile(first)
            }
            // Refresh main models now that the real profiles are loaded — an
            // earlier load ran against the presets and missed these ids.
            await loadProfileMainModels()
        } catch {
            availableProfiles = HermesProfile.presets
        }
    }

    /// Reads each profile's configured main model (`model.default` in that
    /// profile's config.yaml) for display in the profile picker.
    func refreshAllGatewayStatuses() async {
        var map: [String: Bool] = [:]
        for profile in availableProfiles {
            map[profile.id] = await gatewayProvider.isRunning(profile: profile)
        }
        profileGatewayRunning = map
    }

    func isGatewayStarting(_ profile: HermesProfile) -> Bool {
        startingGatewayProfiles.contains(profile.id)
    }

    func startGateway(for profile: HermesProfile) async {
        guard !startingGatewayProfiles.contains(profile.id) else { return }
        startingGatewayProfiles.insert(profile.id)
        try? await gatewayProvider.start(profile: profile)
        // Poll until the gateway reports running (or give up after ~12s).
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(600))
            if await gatewayProvider.isRunning(profile: profile) {
                profileGatewayRunning[profile.id] = true
                startingGatewayProfiles.remove(profile.id)
                return
            }
        }
        profileGatewayRunning[profile.id] = await gatewayProvider.isRunning(profile: profile)
        startingGatewayProfiles.remove(profile.id)
    }

    func loadProfileMainModels() async {
        let profiles = availableProfiles
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
        profileMainModels = await Task.detached { () -> [String: String] in
            var map: [String: String] = [:]
            for profile in profiles {
                let id = profile.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let home = (id == "default" || id.isEmpty)
                    ? root
                    : root.appendingPathComponent("profiles").appendingPathComponent(id)
                let config = HermesConfigurationFile(url: home.appendingPathComponent("config.yaml"))
                try? config.load()
                if let model = (try? config.string(at: ["model", "default"])) ?? nil, !model.isEmpty {
                    map[profile.id] = model
                }
            }
            return map
        }.value
    }

    func loadConfiguredModels() async {
        modelListState = .loading
        do {
            modelListState = .loaded(try await modelConfigurationProvider.configuredModels())
        } catch {
            modelListState = .failed(error.localizedDescription)
        }
    }

    func loadInstalledTools() async {
        toolListState = .loading
        let profile = selectedProfile
        do {
            toolListState = .loaded(try await pluginProvider.installedTools(profile: profile))
        } catch {
            toolListState = .failed(error.localizedDescription)
        }
    }

    func setTool(_ tool: HermesInstalledTool, enabled: Bool) async {
        let profile = selectedProfile
        do {
            try await pluginProvider.setTool(tool.name, enabled: enabled, profile: profile)
            toolListState = .loaded(try await pluginProvider.installedTools(profile: profile))
        } catch {
            toolListState = .failed(error.localizedDescription)
        }
    }

    func loadInstalledSkills() async {
        skillListState = .loading
        let profile = selectedProfile
        do {
            skillListState = .loaded(try await skillProvider.installedSkills(profile: profile))
        } catch {
            skillListState = .failed(error.localizedDescription)
        }
    }

    func setSkill(_ skill: HermesInstalledSkill, enabled: Bool) async {
        let profile = selectedProfile
        do {
            try await skillProvider.setSkill(skill.name, enabled: enabled, profile: profile)
            skillListState = .loaded(try await skillProvider.installedSkills(profile: profile))
        } catch {
            skillListState = .failed(error.localizedDescription)
        }
    }

    /// The headless/cron routing skill (`route.sh`): not a Deck feature, so the
    /// Skills view hides it. Deck-side routing needs no skill — the
    /// AgentRouting primer is seeded into every new session instead.
    static let agentRoutingSkillName = "agent-routing"

    func loadJobs(for profile: HermesProfile) async {
        jobListState = .loading
        do {
            jobListState = .loaded(try await jobProvider.jobs(for: profile))
        } catch {
            jobListState = .failed(error.localizedDescription)
        }
    }

    /// Picks the profile to show in the Jobs panel: the preferred one if it has
    /// jobs, otherwise the first profile (default-first) that does. Falls back to
    /// the preferred profile when none have jobs.
    func profileWithJobs(preferring preferred: HermesProfile?) async -> HermesProfile {
        var ordered: [HermesProfile] = []
        if let preferred { ordered.append(preferred) }
        if let defaultProfile = availableProfiles.first(where: { $0.id == HermesProfile.defaultProfile.id }),
           !ordered.contains(where: { $0.id == defaultProfile.id }) {
            ordered.append(defaultProfile)
        }
        for profile in availableProfiles where !ordered.contains(where: { $0.id == profile.id }) {
            ordered.append(profile)
        }
        for profile in ordered {
            if let jobs = try? await jobProvider.jobs(for: profile), !jobs.isEmpty {
                return profile
            }
        }
        return preferred ?? availableProfiles.first ?? selectedProfile
    }

    @discardableResult
    func performJobAction(_ action: HermesJobAction, jobID: String, for profile: HermesProfile) async -> String? {
        do {
            try await jobProvider.performJobAction(action, jobID: jobID, profile: profile)
            await reloadJobsPreservingList(for: profile)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Reloads jobs without flipping to `.loading` first, so the panel's rows
    /// (and their transient state like toasts) survive an in-place refresh.
    private func reloadJobsPreservingList(for profile: HermesProfile) async {
        if let jobs = try? await jobProvider.jobs(for: profile) {
            jobListState = .loaded(jobs)
        }
    }

    /// Returns nil on success, or an error message to surface inline.
    @discardableResult
    func updateJob(_ edit: HermesJobEdit, for profile: HermesProfile) async -> String? {
        do {
            try await jobProvider.updateJob(edit, profile: profile)
            await reloadJobsPreservingList(for: profile)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func loadKanbanTasks(silent: Bool = false) async {
        // Silent (polling) refreshes keep the current data on screen — no
        // spinner, and a transient failure doesn't clobber a loaded board.
        if !silent { kanbanListState = .loading }
        do {
            kanbanListState = .loaded(try await kanbanProvider.tasks())
        } catch {
            if !silent { kanbanListState = .failed(error.localizedDescription) }
        }
    }

    /// Refreshes whether the hermes backend CLI is installed.
    func refreshHermesInstalled() {
        hermesInstalled = HermesRuntimeInfoService.isInstalled
    }

    /// Loads the most recent sessions for the selected profile into the sidebar
    /// History, independent of any in-app threads.
}
