import Foundation
import Testing
@testable import hermes_deck

@MainActor
struct ChatStoreTests {
    private func sourceFile(_ relativePath: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test
    func chatLayoutStateHidesRightSidebarByDefaultAndTogglesVisibility() {
        var layoutState = ChatLayoutState()

        #expect(layoutState.isRightSidebarVisible == false)

        layoutState.toggleRightSidebar()

        #expect(layoutState.isRightSidebarVisible == true)
    }

    @Test
    func rightSidebarViewIsRenderedOutsideContentVisibilityCondition() throws {
        let source = try sourceFile("hermes_deck/Views/ContentView.swift")

        #expect(!source.contains("if layoutState.isRightSidebarVisible {\n                    RightSidebarView("))
    }

    @Test
    func rightPanelItemsUseRequestedIconOrder() throws {
        let source = try sourceFile("hermes_deck/Views/Layout/RightSidebarView.swift")

        #expect(source.contains("""
enum RightPanelItem: String, CaseIterable, Identifiable {
    case agents
    case task
    case kanban
    case jobs
    case claude
    case codex
    case gemini
"""))
    }

    @Test
    func rightSidebarFreezesChatLayoutWidthWhileResizing() throws {
        let source = try sourceFile("hermes_deck/Views/Layout/RightSidebarView.swift")

        #expect(source.contains(".frame(width: contentLayoutWidth, alignment: .topLeading)"))
        #expect(source.contains(".frame(width: displayedWidth, alignment: .topLeading)"))
        #expect(source.contains("liveWidth != nil && selectedPanelItem.containsChatDetailView"))
        #expect(source.contains("case .agents, .claude, .codex, .gemini:"))
    }

    @Test
    func jobsPanelHasOwnProfilePickerIncludingDefault() throws {
        let rightSidebarSource = try sourceFile("hermes_deck/Views/Layout/RightSidebarView.swift")
        let jobsSource = try sourceFile("hermes_deck/Views/Panels/AgentJobsPanelViews.swift")

        #expect(rightSidebarSource.contains("@State private var selectedRightProfile: HermesProfile?"))
        #expect(rightSidebarSource.contains("selectedAgentProfile: $selectedRightProfile"))
        #expect(rightSidebarSource.contains("JobsPanelView(store: store)"))

        let jobsPanelStart = try #require(jobsSource.range(of: "struct JobsPanelView: View")?.lowerBound)
        let jobsPanelEnd = try #require(jobsSource[jobsPanelStart...].range(of: "struct ScheduledJobRow")?.lowerBound)
        let jobsPanelSource = String(jobsSource[jobsPanelStart..<jobsPanelEnd])

        #expect(jobsPanelSource.contains("@State private var selectedJobProfile: HermesProfile?"))
        #expect(jobsPanelSource.contains("Picker(\"Profile\", selection: $selectedJobProfile)"))
        #expect(jobsPanelSource.contains("ForEach(store.availableProfiles)"))
        #expect(jobsPanelSource.contains("HermesProfile.defaultProfile.id"))
        #expect(jobsPanelSource.contains(".task(id: selectedJobProfile?.id)"))
        #expect(!jobsPanelSource.contains("store.agentProfiles"))
    }

    @Test
    func agentProfilesExcludeDefaultProfile() {
        let store = ChatStore(agentClient: StubHermesAgentClient(reply: "ok"))
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Default"),
            HermesProfile(id: "coding", displayName: "Coding"),
            HermesProfile(id: "research", displayName: "Research"),
        ]

        #expect(store.agentProfiles.map(\.id) == ["coding", "research"])
        // The mention list adds the main Hermes agent back, keeping its loaded
        // display name.
        #expect(store.mentionableProfiles.map(\.id) == ["coding", "research", "default"])
        #expect(store.mentionableProfiles.last?.displayName == "Default")
    }

    @Test
    func scheduledJobParserReadsCronJobs() throws {
        let json = """
        {
          "jobs": [
            {
              "id": "job-2",
              "name": "Later",
              "schedule_display": "0 9 * * *",
              "enabled": true,
              "state": "scheduled",
              "next_run_at": "2026-06-06T09:00:00+08:00",
              "last_run_at": "2026-06-05T09:00:00+08:00",
              "last_status": "ok",
              "deliver": "local",
              "skills": ["web-access"],
              "profile": "researcher"
            },
            {
              "id": "job-1",
              "name": "Earlier",
              "schedule_display": "0 8 * * *",
              "enabled": false,
              "state": "paused",
              "next_run_at": "2026-06-06T08:00:00+08:00",
              "last_status": "error",
              "last_error": "timeout",
              "script": "daily.sh"
            }
          ]
        }
        """

        let jobs = try HermesScheduledJobParser.parse(Data(json.utf8))

        #expect(jobs.map(\.id) == ["job-1", "job-2"])
        #expect(jobs[0].name == "Earlier")
        #expect(jobs[0].statusText == "paused")
        #expect(jobs[0].lastError == "timeout")
        #expect(jobs[0].script == "daily.sh")
        #expect(jobs[1].skills == ["web-access"])
    }

    @Test
    func loadingJobsUpdatesStoreStateForProfile() async throws {
        let profile = HermesProfile(id: "researcher", displayName: "Researcher")
        let provider = StubHermesJobProvider(jobs: [
            HermesScheduledJob(
                id: "job-1",
                name: "Daily",
                schedule: "0 8 * * *",
                state: "scheduled",
                enabled: true,
                nextRunAt: nil,
                lastRunAt: nil,
                lastStatus: nil,
                lastError: nil,
                deliver: "local",
                skills: [],
                script: nil,
                profile: "researcher"
            ),
        ])
        let store = ChatStore(agentClient: StubHermesAgentClient(reply: "ok"), jobProvider: provider)

        await store.loadJobs(for: profile)

        if case .loaded(let jobs) = store.jobListState {
            #expect(jobs.map(\.id) == ["job-1"])
        } else {
            Issue.record("Expected loaded jobs")
        }
        #expect(provider.requestedProfiles == ["researcher"])
    }

    @Test
    func agentsPanelUsesFilteredAgentProfiles() throws {
        let source = try sourceFile("hermes_deck/Views/Panels/AgentJobsPanelViews.swift")

        #expect(source.contains("store.agentProfiles.first"))
        #expect(source.contains("store.threadIDForAgentProfile(profile)"))
    }

    @Test
    func agentsPanelEmbedsInlineChatDetailView() throws {
        let agentsSource = try sourceFile("hermes_deck/Views/Panels/AgentJobsPanelViews.swift")
        let composerChromeSource = try sourceFile("hermes_deck/Views/Chat/Composer/ComposerChrome.swift")

        #expect(agentsSource.contains("ChatDetailView("))
        #expect(agentsSource.contains("composerPresentation: .inline"))
        // The Agents panel composer is always visible — no hover show/hide.
        #expect(agentsSource.contains("showsComposer: true"))
        #expect(!agentsSource.contains("isComposerVisible"))
        #expect(!agentsSource.contains(".onHover"))
        #expect(composerChromeSource.contains("func composerSurface(presentation: ComposerPresentation"))
    }

    @Test
    func agentsPanelRendersHeaderPickerAndHidesComposer() throws {
        let source = try sourceFile("hermes_deck/Views/ContentView.swift")
        let agentsSource = try sourceFile("hermes_deck/Views/Panels/AgentJobsPanelViews.swift")

        let toolbarStart = try #require(source.range(of: ".toolbar {")?.lowerBound)
        let toolbarEnd = try #require(source[toolbarStart...].range(of: ".fileImporter(")?.lowerBound)
        let toolbarSource = String(source[toolbarStart..<toolbarEnd])

        #expect(!toolbarSource.contains("Picker(\"Profile\""))
        #expect(agentsSource.contains("struct AgentsPanelView: View"))
        #expect(agentsSource.contains("Text(\"Agents\")"))
        #expect(agentsSource.contains("Picker(\"Profile\", selection: $selectedAgentProfile)"))
        #expect(agentsSource.contains("selectableAgentProfiles"))
        #expect(agentsSource.contains("ChatDetailView("))
        #expect(agentsSource.contains("showsComposer: true"))
        #expect(!agentsSource.contains("struct AgentProfileRow: View"))
        #expect(!agentsSource.contains("store.setProfile"))
    }

    @Test
    func agentsSplitClearsBottomPaneWhenTopSelectsBottomProfile() throws {
        let source = try sourceFile("hermes_deck/Views/Panels/AgentJobsPanelViews.swift")

        #expect(source.contains("let matchesBottomPane = isSplit && profile.id == secondAgentProfile?.id"))
        #expect(source.contains("private func clearBottomPaneSelection()"))
        #expect(source.contains("secondAgentProfile = nil"))
        #expect(source.contains("secondAgentThreadID = nil"))
        #expect(source.contains("secondDraft = \"\""))
        #expect(source.contains("if let other = bottomPaneProfiles.first"))
    }

    @Test
    func openingAgentProfileCreatesProfileThread() {
        let store = ChatStore(agentClient: StubHermesAgentClient(reply: "ok"))
        let profile = HermesProfile(id: "coding", displayName: "Coding")

        store.openAgentProfile(profile)

        #expect(store.selectedProfile.id == "coding")
        #expect(store.selectedThread?.profile.id == "coding")
        #expect(store.selectedThread?.title == "Coding")
    }

    @Test
    func openingAgentProfileReusesExistingProfileThread() {
        let profile = HermesProfile(id: "research", displayName: "Research")
        let existingThread = ChatThread(title: "Existing Research", profile: profile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            threads: [existingThread]
        )

        store.openAgentProfile(profile)

        #expect(store.selectedThreadID == existingThread.id)
        #expect(store.threads.count == 1)
    }

    @Test
    func threadIDForAgentProfileDoesNotChangeMainSelection() {
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            threads: [defaultThread]
        )
        let originalSelectedThreadID = store.selectedThreadID
        let profile = HermesProfile(id: "coding", displayName: "Coding")

        let agentThreadID = store.threadIDForAgentProfile(profile)

        #expect(store.selectedThreadID == originalSelectedThreadID)
        #expect(store.selectedProfile.id == "default")
        #expect(store.thread(id: agentThreadID)?.profile.id == "coding")
    }

    @Test
    func settingProfileDoesNotRetagSelectedThread() {
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            threads: [defaultThread]
        )

        store.setProfile(.coding)

        #expect(store.selectedProfile.id == "coding")
        #expect(store.selectedThreadID == defaultThread.id)
        #expect(store.thread(id: defaultThread.id)?.profile.id == "default")
    }

    @Test
    func sendAfterProfileSwitchStartsThreadUnderNewProfile() async throws {
        // A profile switched outside the chat page leaves the selected thread
        // tagged with the old profile; the next send must not mix the new
        // profile's session into that history.
        let mainThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            threads: [mainThread]
        )

        await store.send("hello")
        store.setProfile(.coding)
        await store.send("continue")

        // The original thread kept its profile and got no new messages …
        #expect(store.thread(id: mainThread.id)?.profile.id == "default")
        #expect(store.thread(id: mainThread.id)?.messages.count == 2)
        // … and the second send went to a fresh thread under the new profile.
        let newID = try #require(store.selectedThreadID)
        #expect(newID != mainThread.id)
        #expect(store.thread(id: newID)?.profile.id == "coding")
        #expect(store.thread(id: newID)?.messages.map(\.role) == [.user, .assistant])
    }

    @Test
    func sendAfterProfileSwitchRetagsEmptySelectedThread() async throws {
        // An empty selected thread has no history to protect — retag it
        // instead of leaving an orphaned "New Chat" behind.
        let mainThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            threads: [mainThread]
        )

        store.setProfile(.coding)
        await store.send("hello")

        #expect(store.threads.count == 1)
        #expect(store.thread(id: mainThread.id)?.profile.id == "coding")
        #expect(store.thread(id: mainThread.id)?.messages.map(\.role) == [.user, .assistant])
    }

    @Test
    func sendingToAgentThreadDoesNotMutateMainSelectedThread() async throws {
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "agent ok"),
            threads: [defaultThread]
        )
        let originalSelectedThreadID = try #require(store.selectedThreadID)
        let profile = HermesProfile(id: "coding", displayName: "Coding")
        let agentThreadID = store.threadIDForAgentProfile(profile)

        await store.send("hello agent", in: agentThreadID, profile: profile)

        #expect(store.selectedThreadID == originalSelectedThreadID)
        #expect(store.thread(id: originalSelectedThreadID)?.messages.isEmpty == true)
        #expect(store.thread(id: agentThreadID)?.messages.map(\.role) == [.user, .assistant])
        #expect(store.sendState == .idle)
        #expect(store.sendState(forAgentThreadID: agentThreadID) == .idle)
    }

    @Test
    func agentComposerAttachmentsAreSeparateFromMainComposer() async throws {
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "agent ok"),
            threads: [defaultThread]
        )
        let profile = HermesProfile(id: "coding", displayName: "Coding")
        let agentThreadID = store.threadIDForAgentProfile(profile)
        let attachmentURL = URL(fileURLWithPath: "/tmp/agent-note.txt")

        store.attach(urls: [attachmentURL], toAgentThreadID: agentThreadID)

        #expect(store.pendingAttachments.isEmpty)
        #expect(store.pendingAttachments(forAgentThreadID: agentThreadID).map(\.name) == ["agent-note.txt"])

        await store.send("hello agent", in: agentThreadID, profile: profile)

        #expect(store.pendingAttachments.isEmpty)
        #expect(store.pendingAttachments(forAgentThreadID: agentThreadID).isEmpty)
        #expect(store.thread(id: agentThreadID)?.messages.first?.attachments.map(\.name) == ["agent-note.txt"])
    }

    @Test
    func agentPermissionRequestsAreSeparateFromMainComposer() async throws {
        let client = StubStreamingHermesAgentClient(events: [
            .approvalRequest(sessionID: "agent", requestID: nil, text: "Allow agent command?", options: [PermissionOption(id: "Yes", label: "Yes"), PermissionOption(id: "No", label: "No")]),
            .messageComplete(sessionID: "agent", text: "Waiting", status: "complete", usage: nil),
        ])
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(agentClient: client, threads: [defaultThread])
        let profile = HermesProfile(id: "coding", displayName: "Coding")
        let agentThreadID = store.threadIDForAgentProfile(profile)

        await store.send("run agent command", in: agentThreadID, profile: profile)

        #expect(store.pendingPermissionRequest == nil)
        #expect(store.pendingPermissionRequest(forAgentThreadID: agentThreadID)?.message == "Allow agent command?")
        #expect(store.pendingPermissionRequest(forAgentThreadID: agentThreadID)?.choices == ["Yes", "No"])
    }

    @Test
    func agentSessionInfoIsSeparateFromMainComposer() async throws {
        let client = StubStreamingHermesAgentClient(events: [
            .sessionInfo(
                sessionID: "agent",
                info: HermesSessionInfo(model: "Agent Model", contextLength: 64000, usedTokens: 3200)
            ),
            .messageComplete(sessionID: "agent", text: "Ready", status: "complete", usage: nil),
        ])
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(agentClient: client, threads: [defaultThread])
        let profile = HermesProfile(id: "coding", displayName: "Coding")
        let agentThreadID = store.threadIDForAgentProfile(profile)

        await store.send("hi agent", in: agentThreadID, profile: profile)

        #expect(store.sessionInfo.displayText == "Hermes")
        #expect(store.sessionInfo(forAgentThreadID: agentThreadID).displayText == "Agent Model · 3.2K/64K")
    }

    @Test
    func agentMentionParserMatchesProfileIDAndRemovesMention() throws {
        let route = try #require(AgentMentionRouteParser.parse(
            "Please check this @coding",
            profiles: [HermesProfile(id: "coding", displayName: "Coding")]
        ))

        #expect(route.profile.id == "coding")
        #expect(route.message == "Please check this")
    }

    @Test
    func agentMentionParserMatchesDisplayNameCaseInsensitively() throws {
        let route = try #require(AgentMentionRouteParser.parse(
            "@Research Agent summarize this",
            profiles: [HermesProfile(id: "researcher", displayName: "Research Agent")]
        ))

        #expect(route.profile.id == "researcher")
        #expect(route.message == "summarize this")
    }

    @Test
    func mainComposerMentionRoutesMessageToAgentAndReturnsResultToMainThread() async throws {
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "agent ok"),
            threads: [defaultThread]
        )
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Default"),
            HermesProfile(id: "coding", displayName: "Coding"),
        ]
        let originalSelectedThreadID = try #require(store.selectedThreadID)

        await store.send("@coding inspect this")

        if let routeRequest = store.latestAgentRouteRequest {
            Issue.record("Expected no agent panel route request, got \(routeRequest)")
        }
        #expect(store.pendingExternalAgentPanel == nil)
        #expect(store.selectedThreadID == originalSelectedThreadID)
        #expect(store.thread(id: originalSelectedThreadID)?.messages.map(\.role) == [.user, .assistant])
        #expect(store.thread(id: originalSelectedThreadID)?.messages.first?.content == "@coding inspect this")
        // The echoed reply carries clean body text; attribution is out-of-band.
        #expect(store.thread(id: originalSelectedThreadID)?.messages.last?.content == "agent ok")
        #expect(store.thread(id: originalSelectedThreadID)?.messages.last?.agentReplyName == "Coding")
        let codingThread = try #require(store.threads.first { $0.profile.id == "coding" })
        #expect(codingThread.messages.first?.content == "inspect this")
        #expect(codingThread.messages.first?.routedSourceProfileName == "Hermes agent")
        #expect(codingThread.messages.map(\.role) == [.user, .assistant])
    }

    @Test
    func multipleProfileMentionsFanOutEachSegmentToItsProfile() async throws {
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            threads: [defaultThread]
        )
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Hermes agent"),
            HermesProfile(id: "coding", displayName: "Coding"),
            HermesProfile(id: "research", displayName: "Research"),
        ]

        await store.send("@coding do A @research do B")

        // Each mentioned profile receives only the segment after its mention.
        let coding = try #require(store.threads.first { $0.profile.id == "coding" })
        #expect(coding.messages.first?.content == "do A")
        let research = try #require(store.threads.first { $0.profile.id == "research" })
        #expect(research.messages.first?.content == "do B")
    }

    @Test
    func agentPanelProfileReplyForwardsAddressedMention() async throws {
        // A profile in an agent side panel whose reply addresses coding via a
        // fenced `@coding` code block forwards that block (single hop) and
        // feeds coding's reply back into the panel thread.
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "```AgentRouting\n@coding investigate\n```"),
            threads: [defaultThread]
        )
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Hermes agent"),
            HermesProfile(id: "researcher", displayName: "Researcher"),
            HermesProfile(id: "coding", displayName: "Coding"),
        ]
        let researcher = HermesProfile(id: "researcher", displayName: "Researcher")
        let researcherThreadID = store.threadIDForAgentProfile(researcher)

        await store.sendAgentProfile("dig in", in: researcherThreadID, profile: researcher)

        // Coding got only the segment after its mention, exactly once (single hop:
        // coding's own "@coding …" reply is not re-forwarded).
        let coding = try #require(store.threads.first { $0.profile.id == "coding" })
        #expect(coding.messages.filter { $0.role == .user }.map(\.content) == ["investigate"])

        let researcherMsgs = try #require(store.thread(id: researcherThreadID)?.messages)
        // Coding's reply is fed back to the researcher as a follow-up turn
        // (close the loop), so the source agent actually receives it …
        #expect(researcherMsgs.contains { $0.role == .user && $0.content.hasPrefix("Coding replied:") })
        #expect(researcherMsgs.contains { $0.role == .user && $0.isAgentReplyFollowUp == true })
        // … and there is no bare echo on top of it — the framed follow-up is
        // the only copy of the reply shown in the source thread.
        #expect(!researcherMsgs.contains { $0.agentReplyName == "Coding" })
    }

    @Test
    func agentReplyForwardsExternalMentionToAgentPanelTerminal() async throws {
        struct PanelPrompt: Equatable {
            let backend: AgentBackend
            let threadID: UUID
            let prompt: String
        }

        var panelPrompts: [PanelPrompt] = []
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "```AgentRouting\n@codex inspect repo\n```"),
            threads: [defaultThread],
            externalAgentPanelPromptSender: { backend, threadID, prompt in
                panelPrompts.append(PanelPrompt(backend: backend, threadID: threadID, prompt: prompt))
                return true
            }
        )
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Hermes agent"),
            HermesProfile(id: "researcher", displayName: "Researcher"),
        ]
        let researcher = HermesProfile(id: "researcher", displayName: "Researcher")
        let researcherThreadID = store.threadIDForAgentProfile(researcher)

        await store.sendAgentProfile("dig in", in: researcherThreadID, profile: researcher)

        let codexThread = try #require(store.threads.first { $0.profile.id == "acp:codex" })
        #expect(panelPrompts == [
            PanelPrompt(backend: .acp(.codex), threadID: codexThread.id, prompt: DeckReplyPrimer.wrap("inspect repo"))
        ])
        #expect(store.threadBackends[codexThread.id] == .acp(.codex))
        #expect(store.threadHandoffs[researcherThreadID]?.items.first?.phase == .waiting)
    }

    @Test
    func externalPanelForwardingResolvesExecutableOnPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("toolx")
        FileManager.default.createFile(atPath: tool.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let env = ["PATH": dir.path]
        #expect(ChatStore.isExecutableAvailable("toolx", environment: env))
        #expect(!ChatStore.isExecutableAvailable("missing-tool", environment: env))
        // No PATH → nothing resolves; an absolute path is checked directly.
        #expect(!ChatStore.isExecutableAvailable("toolx", environment: [:]))
        #expect(ChatStore.isExecutableAvailable(tool.path, environment: [:]))
    }

    @Test
    func panelDeckReplyClosesLoopBackToSource() async throws {
        let source = ChatThread(title: "Researcher", profile: HermesProfile(id: "researcher", displayName: "Researcher"))
        let store = ChatStore(agentClient: StubHermesAgentClient(reply: ""), threads: [source])
        let panelThreadID = UUID()
        let itemID = UUID()
        store.threadHandoffs[source.id] = AgentHandoffBatch(
            anchorMessageID: nil,
            items: [AgentHandoffItem(id: itemID, targetName: "Codex", phase: .waiting)]
        )
        store.recordPanelReplyBinding(
            panelThreadID: panelThreadID,
            sourceThreadID: source.id,
            sourceProfile: source.profile,
            handoffItemID: itemID,
            targetName: "Codex"
        )

        let message = "done: inspected the repo"
        let request = DeckRoutingIPCRequest(
            token: "",
            type: "reply",
            target: nil,
            prompt: nil,
            wait: nil,
            sourceSessionKey: nil,
            sourceProfileID: nil,
            session: panelThreadID.uuidString,
            messageB64: Data(message.utf8).base64EncodedString()
        )
        let response = store.handleDeckRoutingIPCRequest(request)

        #expect(response.ok)
        #expect(store.threadHandoffs[source.id]?.items.first?.phase == .replied(message))
        // The binding is consumed; a second reply finds nothing pending.
        #expect(!store.handleDeckRoutingIPCRequest(request).ok)

        // The follow-up to the source agent is dispatched asynchronously.
        try await Task.sleep(for: .milliseconds(300))
        let messages = try #require(store.thread(id: source.id)?.messages)
        #expect(messages.contains {
            $0.role == .user
                && $0.isAgentReplyFollowUp == true
                && $0.content == "Codex replied:\n\n\(message)"
        })
    }

    @Test
    func panelDelegationTimesOutWhenNoReply() async throws {
        let source = ChatThread(title: "Researcher", profile: HermesProfile(id: "researcher", displayName: "Researcher"))
        let store = ChatStore(agentClient: StubHermesAgentClient(reply: ""), threads: [source])
        store.panelReplyTimeout = .milliseconds(50)
        let panelThreadID = UUID()
        let itemID = UUID()
        store.threadHandoffs[source.id] = AgentHandoffBatch(
            anchorMessageID: nil,
            items: [AgentHandoffItem(id: itemID, targetName: "Codex", phase: .waiting)]
        )
        store.recordPanelReplyBinding(
            panelThreadID: panelThreadID,
            sourceThreadID: source.id,
            sourceProfile: source.profile,
            handoffItemID: itemID,
            targetName: "Codex"
        )

        try await Task.sleep(for: .milliseconds(250))
        #expect(store.threadHandoffs[source.id]?.items.first?.phase == .failed)

        // A reply arriving after the timeout finds nothing pending.
        let request = DeckRoutingIPCRequest(
            token: "",
            type: "reply",
            target: nil,
            prompt: nil,
            wait: nil,
            sourceSessionKey: nil,
            sourceProfileID: nil,
            session: panelThreadID.uuidString,
            messageB64: Data("late".utf8).base64EncodedString()
        )
        #expect(!store.handleDeckRoutingIPCRequest(request).ok)
    }

    @Test
    func agentPanelReplyMentioningDefaultRoutesToMainHermesAgent() async throws {
        // `@default` (the main Hermes agent) is addressable from an agent's
        // reply: the segment routes into the main chat thread and the reply is
        // fed back to the source agent.
        let mainThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "```AgentRouting\n@default summarize findings\n```"),
            threads: [mainThread]
        )
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Hermes agent"),
            HermesProfile(id: "researcher", displayName: "Researcher"),
        ]
        let researcher = HermesProfile(id: "researcher", displayName: "Researcher")
        let researcherThreadID = store.threadIDForAgentProfile(researcher)

        await store.sendAgentProfile("dig in", in: researcherThreadID, profile: researcher)

        // The main chat thread received the routed segment, attributed to the
        // source agent.
        let mainMsgs = try #require(store.thread(id: mainThread.id)?.messages)
        let routed = try #require(mainMsgs.first { $0.role == .user && $0.content == "summarize findings" })
        #expect(routed.routedSourceProfileName == "Researcher")
        // The default agent's reply closed the loop back to the researcher.
        let researcherMsgs = try #require(store.thread(id: researcherThreadID)?.messages)
        #expect(researcherMsgs.contains { $0.role == .user && $0.content.hasPrefix("Hermes agent replied:") })
        #expect(researcherMsgs.contains { $0.role == .user && $0.isAgentReplyFollowUp == true })
    }

    @Test
    func mainChatDefaultSelfMentionIsTreatedAsPlainPrompt() async throws {
        // `@default` typed in the main chat targets the thread it was typed in;
        // routing there would loop, so it falls through to a normal send.
        let mainThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            threads: [mainThread]
        )

        await store.send("@default hi")

        #expect(store.threads.count == 1)
        let messages = try #require(store.thread(id: mainThread.id)?.messages)
        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(messages.first?.content == "@default hi")
        #expect(messages.last?.content == "ok")
    }

    @Test
    func profileReplyWithMentionCodeBlockAfterProseForwards() async throws {
        // The addressed code block does not have to open the reply — prose may
        // precede it.
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "Here is my analysis.\n```AgentRouting\n@coding investigate the crash\n```"),
            threads: [defaultThread]
        )
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Hermes agent"),
            HermesProfile(id: "researcher", displayName: "Researcher"),
            HermesProfile(id: "coding", displayName: "Coding"),
        ]
        let researcher = HermesProfile(id: "researcher", displayName: "Researcher")
        let researcherThreadID = store.threadIDForAgentProfile(researcher)

        await store.sendAgentProfile("dig in", in: researcherThreadID, profile: researcher)

        let coding = try #require(store.threads.first { $0.profile.id == "coding" })
        #expect(coding.messages.filter { $0.role == .user }.map(\.content) == ["investigate the crash"])
    }

    @Test
    func profileReplyWithBareLineLeadingMentionDoesNotForward() async throws {
        // A mention outside a fenced code block — even one leading a line —
        // is conversational; only `@target` opening its own block routes.
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "@coding investigate the crash"),
            threads: [defaultThread]
        )
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Hermes agent"),
            HermesProfile(id: "researcher", displayName: "Researcher"),
            HermesProfile(id: "coding", displayName: "Coding"),
        ]
        let researcher = HermesProfile(id: "researcher", displayName: "Researcher")
        let researcherThreadID = store.threadIDForAgentProfile(researcher)

        await store.sendAgentProfile("dig in", in: researcherThreadID, profile: researcher)

        #expect(store.threads.first { $0.profile.id == "coding" } == nil)
    }

    @Test
    func profileReplyWithMidProseMentionDoesNotForward() async throws {
        // "ask @coding about X" inside a sentence is conversational, not an
        // address — it must not fan out.
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "You should ask @coding about the crash."),
            threads: [defaultThread]
        )
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Hermes agent"),
            HermesProfile(id: "researcher", displayName: "Researcher"),
            HermesProfile(id: "coding", displayName: "Coding"),
        ]
        let researcher = HermesProfile(id: "researcher", displayName: "Researcher")
        let researcherThreadID = store.threadIDForAgentProfile(researcher)

        await store.sendAgentProfile("dig in", in: researcherThreadID, profile: researcher)

        #expect(store.threads.first { $0.profile.id == "coding" } == nil)
    }

    @Test
    func codeBlockRouteSpansFollowOneBlockOneTargetRule() throws {
        let aliasGroups = [["coding"], ["research"]]

        // One AgentRouting block per target; prose mentions, plain code blocks,
        // and blocks that don't *start* with a mention never route.
        let text = """
        Summary first, ping @research later.
        ```AgentRouting
        @coding fix the crash
        in the parser
        ```
        ```AgentRouting
        prefix @research verify
        ```
        ```
        @research this plain block must not route
        ```
        ```AgentRouting
        @research verify the fix
        ```
        """
        let spans = AgentMentionRouteParser.codeBlockRouteSpans(in: text, aliasGroups: aliasGroups)
        #expect(spans.map(\.groupIndex) == [0, 1])
        #expect(spans.map(\.alias) == ["coding", "research"])
        #expect(spans.first?.message == "fix the crash\nin the parser")
        #expect(spans.last?.message == "verify the fix")

        let newlineFormat = "```AgentRouting\n@coding\nfix the crash\nin the parser\n```"
        #expect(
            AgentMentionRouteParser.codeBlockRouteSpans(in: newlineFormat, aliasGroups: aliasGroups).first?.message
            == "fix the crash\nin the parser"
        )

        // A block holding a second known mention is ambiguous — rejected.
        let twoTargets = "```AgentRouting\n@coding fix it, then ping @research\n```"
        #expect(AgentMentionRouteParser.codeBlockRouteSpans(in: twoTargets, aliasGroups: aliasGroups).isEmpty)

        // An unclosed fence is not a block.
        let unclosed = "```AgentRouting\n@coding fix it"
        #expect(AgentMentionRouteParser.codeBlockRouteSpans(in: unclosed, aliasGroups: aliasGroups).isEmpty)
    }

    @Test
    func forwardedAgentReplyIsNotReForwarded() async throws {
        // Single-hop guarantee: the forwarded agent's own reply (which itself
        // leads with `@research`) must NOT route again — otherwise research would
        // receive a second prompt.
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "```AgentRouting\n@research go\n```"),
            threads: [defaultThread]
        )
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Hermes agent"),
            HermesProfile(id: "research", displayName: "Research"),
        ]

        await store.send("kick off")

        let research = try #require(store.threads.first { $0.profile.id == "research" })
        #expect(research.messages.filter { $0.role == .user }.map(\.content) == ["go"])
    }

    @Test
    func hermesRequestsCarryRoutingPrimerListingOtherTargets() async throws {
        // A new gateway session is seeded with the AgentRouting primer: fence
        // format plus the live target list, excluding the session's own
        // profile. The chat thread itself stays clean.
        let client = RecordingHermesAgentClient(reply: "ok")
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(agentClient: client, threads: [defaultThread])
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Hermes agent"),
            HermesProfile(id: "coding", displayName: "Coding"),
            HermesProfile(id: "researcher", displayName: "Researcher"),
        ]

        await store.send("hi")

        let request = try #require(await client.requests.last)
        let primer = try #require(request.routingPrimer)
        #expect(primer.contains("[Hermes Deck capability: delegate_to_agent]"))
        #expect(primer.contains("You have a built-in delegation capability"))
        #expect(primer.contains("Available delegation targets:"))
        #expect(primer.contains("```AgentRouting"))
        #expect(primer.contains("@coding\nInspect the parser failure"))
        #expect(primer.contains("the prompt may span multiple lines"))
        #expect(primer.contains("Use one block per target"))
        #expect(primer.contains("available target alias from the list above"))
        #expect(primer.contains("Do not put a second target alias inside the same block"))
        #expect(primer.contains("action request, not as a Markdown example"))
        #expect(primer.contains("not wrap it inside another code block or quote block"))
        #expect(primer.contains("Do not place a plain ``` fence before or after the AgentRouting"))
        #expect(primer.contains("before the target alias"))
        #expect(primer.contains("more than one available target alias"))
        #expect(primer.contains("nested code block that contains an AgentRouting block"))
        #expect(primer.contains("answer normally without a routing block"))
        #expect(primer.contains("- @coding: code changes, debugging, tests"))
        #expect(primer.contains("- @researcher: investigation, comparison"))
        #expect(primer.contains("- @codex: repository work, implementation"))
        #expect(primer.contains("@coding"))
        #expect(primer.contains("@researcher"))
        #expect(primer.contains("@codex"))
        #expect(!primer.contains("@default"))
        #expect(store.selectedThread?.messages.allSatisfy { !$0.content.contains("[Hermes Deck routing]") } == true)
    }

    @Test
    func externalAgentAvailabilityProbesLauncherOnPath() async throws {
        let store = ChatStore(agentClient: StubHermesAgentClient(reply: "ok"))

        // Default: nothing probed yet → treated as available.
        #expect(store.isExternalAgentUnavailable("agy") == false)

        await store.refreshExternalAgentAvailability()

        // `npx` (Codex) is on PATH in this dev environment; a missing launcher
        // would flip its profile id into the unavailable set. We assert the
        // mechanism, not a specific machine's install state: the set only ever
        // contains known external profile ids.
        let externalIDs = Set(store.externalAgentMentionTargets.map(\.profile.id))
        #expect(store.unavailableExternalAgentProfileIDs.isSubset(of: externalIDs))
        // A bogus command is never available; a ubiquitous one always is.
        #expect(AgentLaunchEnvironment.isCommandAvailable("definitely-not-a-real-cmd-xyz") == false)
        #expect(AgentLaunchEnvironment.isCommandAvailable("/bin/sh"))
    }

    @Test
    func malformedRoutingBlockReasonsDiagnoseEachFailure() {
        let aliasGroups = [["coding"], ["research"]]
        func reasons(_ text: String) -> [String] {
            AgentMentionRouteParser.malformedRoutingBlockReasons(in: text, aliasGroups: aliasGroups)
        }

        #expect(reasons("```AgentRouting\nplease @coding fix it\n```").first?.contains("start with @<target>") == true)
        #expect(reasons("```AgentRouting\n@nosuch fix it\n```").first?.contains("not one of the available targets") == true)
        #expect(reasons("```AgentRouting\n@coding\n```").first?.contains("no prompt") == true)
        #expect(reasons("```AgentRouting\n@coding fix, ping @research\n```").first?.contains("second @target") == true)
        // Valid blocks and non-routing blocks produce no reasons.
        #expect(reasons("```AgentRouting\n@coding fix it\n```").isEmpty)
        #expect(reasons("```swift\n@State var x = 1\n```").isEmpty)
    }

    @Test
    func malformedRoutingBlockTriggersOneCorrectionThenRoutes() async throws {
        // Turn 1: malformed block → Deck sends a correction notice; turn 2 (the
        // retry) emits a valid block, which routes.
        let mainThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: SequencedHermesAgentClient(replies: [
                "```AgentRouting\nplease @coding fix it\n```",   // researcher, malformed
                "```AgentRouting\n@coding fix it\n```",          // researcher retry, valid
                "done",                                          // coding's reply
                "thanks",                                        // researcher close-the-loop
            ]),
            threads: [mainThread]
        )
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Hermes agent"),
            HermesProfile(id: "researcher", displayName: "Researcher"),
            HermesProfile(id: "coding", displayName: "Coding"),
        ]
        let researcher = HermesProfile(id: "researcher", displayName: "Researcher")
        let researcherThreadID = store.threadIDForAgentProfile(researcher)

        await store.sendAgentProfile("dig in", in: researcherThreadID, profile: researcher)

        let msgs = try #require(store.thread(id: researcherThreadID)?.messages)
        let corrections = msgs.filter { $0.role == .user && $0.content.contains("was not routed") }
        #expect(corrections.count == 1)
        #expect(corrections.first?.isAgentReplyFollowUp == true)
        // The retry's valid block reached coding.
        let coding = try #require(store.threads.first { $0.profile.id == "coding" })
        #expect(coding.messages.filter { $0.role == .user }.map(\.content) == ["fix it"])
    }

    @Test
    func malformedRoutingBlockCorrectionRunsOnlyOnce() async throws {
        // A model that re-emits a malformed block gets no second correction.
        let mainThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: SequencedHermesAgentClient(replies: [
                "```AgentRouting\nplease @coding fix it\n```",
                "```AgentRouting\nstill @coding broken\n```",
            ]),
            threads: [mainThread]
        )
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Hermes agent"),
            HermesProfile(id: "researcher", displayName: "Researcher"),
            HermesProfile(id: "coding", displayName: "Coding"),
        ]
        let researcher = HermesProfile(id: "researcher", displayName: "Researcher")
        let researcherThreadID = store.threadIDForAgentProfile(researcher)

        await store.sendAgentProfile("dig in", in: researcherThreadID, profile: researcher)

        let msgs = try #require(store.thread(id: researcherThreadID)?.messages)
        let corrections = msgs.filter { $0.role == .user && $0.content.contains("was not routed") }
        #expect(corrections.count == 1)
        #expect(store.threads.first { $0.profile.id == "coding" } == nil)
    }

    @Test
    func handoffStatusTracksWaitingThenRepliedForLoopClosingRoutes() async throws {
        // Agent-initiated hand-off: a waiting card appears under the
        // triggering bubble, then flips to replied carrying the target's text.
        let mainThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "```AgentRouting\n@coding investigate\n```"),
            threads: [mainThread]
        )
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Hermes agent"),
            HermesProfile(id: "researcher", displayName: "Researcher"),
            HermesProfile(id: "coding", displayName: "Coding"),
        ]
        let researcher = HermesProfile(id: "researcher", displayName: "Researcher")
        let researcherThreadID = store.threadIDForAgentProfile(researcher)

        await store.sendAgentProfile("dig in", in: researcherThreadID, profile: researcher)

        let batch = try #require(store.threadHandoffs[researcherThreadID])
        #expect(batch.items.map(\.targetName) == ["Coding"])
        // Coding's stub reply is the routing block itself; that text came back.
        #expect(batch.items.first?.phase == .replied("```AgentRouting\n@coding investigate\n```"))
        // Anchored to a message that is still displayed (not the hidden framed
        // follow-up).
        let anchorID = try #require(batch.anchorMessageID)
        let anchor = try #require(store.thread(id: researcherThreadID)?.messages.first { $0.id == anchorID })
        #expect(anchor.isAgentReplyFollowUp != true)
    }

    @Test
    func userInitiatedRouteRemovesHandoffCardOnceEchoArrives() async throws {
        // User-typed mention: the echoed bubble shows the reply, so the card
        // disappears instead of duplicating it.
        let mainThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            threads: [mainThread]
        )
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Hermes agent"),
            HermesProfile(id: "coding", displayName: "Coding"),
        ]

        await store.send("@coding hi")

        #expect(store.threadHandoffs[mainThread.id] == nil)
    }

    @Test
    func sourceThreadShowsBusyWhileRoutedTargetsRun() async throws {
        // While a hand-off waits on its targets, the source thread is busy on
        // its per-thread track (the main composer merges that track in). The
        // global track is left alone — releasing it used to depend on the
        // current selection and leaked .sending when the user switched
        // threads mid-hand-off.
        let client = GatedHermesAgentClient()
        let mainThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(agentClient: client, threads: [mainThread])
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Hermes agent"),
            HermesProfile(id: "coding", displayName: "Coding"),
        ]

        async let routed: Void = store.send("@coding hi")
        while await client.started < 1 { try await Task.sleep(for: .milliseconds(10)) }

        #expect(store.sendState(forAgentThreadID: mainThread.id) == .sending)
        #expect(store.sendState == .idle)

        // Switching away mid-hand-off must not strand any busy state.
        store.createThread()

        await client.releaseNext()
        await routed

        #expect(store.sendState == .idle)
        #expect(store.sendState(forAgentThreadID: mainThread.id) == .idle)
    }

    @Test
    func agentReplyFramingRoundTripsAndRejectsProse() {
        let framed = AgentReplyFraming.framed([
            (name: "Coding", reply: "done"),
            (name: "Researcher", reply: "sources:\n- a\n- b"),
        ])
        let sections = AgentReplyFraming.sections(in: framed)
        #expect(sections?.map(\.name) == ["Coding", "Researcher"])
        #expect(sections?.map(\.reply) == ["done", "sources:\n- a\n- b"])

        // Ordinary prose (or a partially matching mix) is not a framed receipt.
        #expect(AgentReplyFraming.sections(in: "just some text") == nil)
        #expect(AgentReplyFraming.sections(in: framed + AgentReplyFraming.sectionSeparator + "trailing prose") == nil)
    }

    @Test
    func concurrentTurnsOnOneThreadSerialize() async throws {
        // One gateway session runs one turn at a time; a second prompt on the
        // same thread must wait out the in-flight turn instead of colliding
        // ("session busy" would silently drop it — the routed close-the-loop
        // reply being the main casualty).
        let client = GatedHermesAgentClient()
        let mainThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(agentClient: client, threads: [mainThread])
        let threadID = mainThread.id

        async let first: String? = store.send("first", in: threadID, profile: .defaultProfile)
        while await client.started < 1 { try await Task.sleep(for: .milliseconds(10)) }

        async let second: String? = store.send("second", in: threadID, profile: .defaultProfile)
        try await Task.sleep(for: .milliseconds(150))
        // The second turn is parked: nothing new reached the gateway and its
        // user message is not in the thread yet.
        #expect(await client.started == 1)
        #expect(store.thread(id: threadID)?.messages.filter { $0.role == .user }.count == 1)

        await client.releaseNext()
        while await client.started < 2 { try await Task.sleep(for: .milliseconds(10)) }
        await client.releaseNext()

        _ = await first
        _ = await second
        #expect(store.thread(id: threadID)?.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(store.thread(id: threadID)?.messages.map(\.content) == ["first", "ok", "second", "ok"])
    }

    @Test
    func externalBackendRequestsCarryNoRoutingPrimer() async throws {
        // External CLIs cannot route, so their sessions get no primer.
        let client = RecordingHermesAgentClient(reply: "ok")
        let store = ChatStore(agentClient: client)
        let threadID = store.agyThread()

        await store.sendToAgy("hi", threadID: threadID)

        let request = try #require(await client.requests.last)
        #expect(request.routingPrimer == nil)
    }

    @Test
    func forwardedHermesPromptIncludesSourceInRequestEnvelopeButKeepsThreadMessageClean() async throws {
        let client = RecordingHermesAgentClient(reply: "agent ok")
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(agentClient: client, threads: [defaultThread])
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Hermes agent"),
            HermesProfile(id: "coding", displayName: "Coding"),
        ]

        await store.send("@coding inspect this")

        if let routeRequest = store.latestAgentRouteRequest {
            Issue.record("Expected no agent panel route request, got \(routeRequest)")
        }
        #expect(store.pendingExternalAgentPanel == nil)
        let codingThread = try #require(store.threads.first { $0.profile.id == "coding" })
        #expect(codingThread.messages.first?.content == "inspect this")

        let request = try #require(await client.requests.last)
        #expect(request.promptText.contains("[Forwarded from Hermes agent]"))
        #expect(request.promptText.contains("inspect this"))
        #expect(request.messages.last?.content == "inspect this")
    }

    @Test
    func mainComposerMentionForwardsToExternalACPAgentAndEchoesReply() async throws {
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "codex ok"),
            threads: [defaultThread]
        )
        let originalSelectedThreadID = try #require(store.selectedThreadID)

        await store.send("@codex refactor this")

        #expect(store.selectedThreadID == originalSelectedThreadID)
        if let routeRequest = store.latestAgentRouteRequest {
            Issue.record("Expected no agent panel route request, got \(routeRequest)")
        }
        #expect(store.pendingExternalAgentPanel == nil)
        let mainMessages = try #require(store.thread(id: originalSelectedThreadID)?.messages)
        #expect(mainMessages.map(\.role) == [.user, .assistant])
        #expect(mainMessages.first?.content == "@codex refactor this")
        #expect(mainMessages.last?.content == "codex ok")
        #expect(mainMessages.last?.agentReplyName == "Codex")

        let codexThread = try #require(store.threads.first { $0.profile.id == "acp:codex" })
        #expect(codexThread.messages.first?.content == "refactor this")
        #expect(codexThread.messages.first?.routedSourceProfileName == "Hermes agent")
        #expect(codexThread.messages.map(\.role) == [.user, .assistant])
    }

    @Test
    func forwardedExternalPromptIncludesSourceAndAttachmentNotesInRequestEnvelope() async throws {
        let client = RecordingHermesAgentClient(reply: "codex ok")
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(agentClient: client, threads: [defaultThread])
        let attachment = Attachment(
            name: "notes.txt",
            url: URL(fileURLWithPath: "/tmp/notes.txt"),
            contentType: "text/plain"
        )
        store.addAttachments([attachment])

        await store.send("@codex refactor this")

        let codexThread = try #require(store.threads.first { $0.profile.id == "acp:codex" })
        #expect(codexThread.messages.first?.content == "refactor this")

        let request = try #require(await client.requests.last)
        #expect(request.backend == .acp(.codex))
        #expect(request.promptText.contains("[Forwarded from Hermes agent]"))
        #expect(request.promptText.contains("[User attached file: notes.txt (/tmp/notes.txt)]"))
        #expect(request.promptText.contains("refactor this"))
        #expect(request.attachments == [attachment])
    }

    @Test
    func composerMentionDetectsActiveQueryAtWordBoundary() throws {
        // No mention.
        #expect(ComposerMention.activeQuery(in: "") == nil)
        #expect(ComposerMention.activeQuery(in: "hello world") == nil)
        // Mid-word @ is not a mention.
        #expect(ComposerMention.activeQuery(in: "email a@b") == nil)
        // A completed mention (trailing space) dismisses.
        #expect(ComposerMention.activeQuery(in: "@codex ") == nil)

        // Active mention at start; range covers @…end for replacement.
        var bareDraft = "@co"
        let bare = try #require(ComposerMention.activeQuery(in: bareDraft))
        #expect(bare.query == "co")
        bareDraft.replaceSubrange(bare.range, with: "@codex ")
        #expect(bareDraft == "@codex ")

        // Active mention after whitespace; query is lowercased.
        var midDraft = "please ask @Cod"
        let mid = try #require(ComposerMention.activeQuery(in: midDraft))
        #expect(mid.query == "cod")
        midDraft.replaceSubrange(mid.range, with: "@codex ")
        #expect(midDraft == "please ask @codex ")
    }

    @Test
    func externalAgentStreamingReplyIsEchoedBackToSourceThread() async throws {
        // Streaming backends build the reply from deltas and end with an empty
        // messageComplete; the echo must still capture the accumulated text.
        let client = StubStreamingHermesAgentClient(events: [
            .messageStart(sessionID: "codex"),
            .messageDelta(sessionID: "codex", text: "hello "),
            .messageDelta(sessionID: "codex", text: "world"),
            .messageComplete(sessionID: "codex", text: "", status: "complete", usage: nil),
        ])
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(agentClient: client, threads: [defaultThread])
        let sourceID = try #require(store.selectedThreadID)

        await store.send("@codex hi")

        let mainMessages = try #require(store.thread(id: sourceID)?.messages)
        #expect(mainMessages.map(\.role) == [.user, .assistant])
        #expect(mainMessages.last?.content == "hello world")
        #expect(mainMessages.last?.agentReplyName == "Codex")
    }

    @Test
    func externalAgentSourceCannotRouteMentions() async throws {
        let panelThread = ChatThread(
            title: "Codex",
            profile: HermesProfile(id: "acp:codex", displayName: "Codex")
        )
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "should not route"),
            threads: [panelThread]
        )
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Hermes agent"),
            HermesProfile(id: "coding", displayName: "Coding"),
        ]

        let routed = await store.routePromptIfAllowed(
            "@coding fix this",
            from: .external(backend: .acp(.codex), displayName: "Codex"),
            sourceThreadID: panelThread.id,
            notifiesPanel: false
        )

        #expect(routed == .denied(.externalSourceCannotRoute))
        if let routeRequest = store.latestAgentRouteRequest {
            Issue.record("Expected no agent panel route request, got \(routeRequest)")        // panel not switched
        }
        #expect(store.pendingExternalAgentPanel == nil)
        #expect(store.thread(id: panelThread.id)?.messages.isEmpty == true)
        #expect(store.threads.first { $0.profile.id == "coding" } == nil)
    }

    @Test
    func deckRoutingIPCFallsBackToSourceProfileWhenSessionIsNotBoundYet() async throws {
        let coding = HermesProfile(id: "coding", displayName: "Coding")
        let sourceThread = ChatThread(title: "Coding", profile: coding)
        let store = ChatStore(agentClient: StubHermesAgentClient(reply: "ok"), threads: [sourceThread])
        store.availableProfiles = [
            HermesProfile(id: "default", displayName: "Hermes agent"),
            coding,
        ]
        store.selectedThreadID = sourceThread.id

        let response = store.handleDeckRoutingIPCRequest(DeckRoutingIPCRequest(
            token: "token",
            target: "default",
            prompt: "please check this",
            wait: false,
            sourceSessionKey: "gateway-session",
            sourceProfileID: "coding"
        ))

        #expect(response.ok == true)
        #expect(response.status == "queued")
        #expect(store.thread(id: sourceThread.id)?.hermesSessionID == "gateway-session")
        let messages = try #require(store.thread(id: sourceThread.id)?.messages)
        #expect(messages.last?.role == .assistant)
        #expect(messages.last?.content.contains("```AgentRouting\n@default\nplease check this\n```") == true)
    }

    @Test
    func externalAgentReplyAttributionParsesKnownSourcesOnly() throws {
        #expect(ExternalAgentReplyAttribution.parse("Claude Code:\n\nDone")?.source == .claude)
        #expect(ExternalAgentReplyAttribution.parse("Codex:\n\nDone")?.source == .codex)
        #expect(ExternalAgentReplyAttribution.parse("Gemini (Antigravity):\n\nDone")?.source == .gemini)
        #expect(ExternalAgentReplyAttribution.parse("Gemini:\n\nDone")?.source == .gemini)

        // Anything that is not a known external brand must NOT be read as an
        // attribution from content alone — Hermes-profile echoes carry their name
        // out-of-band via `ChatMessage.agentReplyName` instead. This is the
        // regression guard against ordinary prose like "Summary:\n\n…" being
        // swallowed into an attribution pill.
        #expect(ExternalAgentReplyAttribution.parse("Research Agent:\n\nDone") == nil)
        #expect(ExternalAgentReplyAttribution.parse("Summary:\n\nbody") == nil)
        #expect(ExternalAgentReplyAttribution.parse("Note:\n\nbody") == nil)
        #expect(ExternalAgentReplyAttribution.parse("# Heading:\n\nbody") == nil)
    }

    @Test
    func equalLengthAliasesResolveDeterministicallyToEarlierGroup() throws {
        // Two groups share the same-length alias "codex" (group 0 = external,
        // group 1 = a Hermes profile). `sort` is not stable, so without an
        // explicit group tiebreak the winner would be undefined — assert the
        // earlier (external) group wins every time.
        let spans = AgentMentionRouteParser.routeSpans(
            in: "@codex do it",
            aliasGroups: [["codex"], ["codex"]]
        )
        #expect(spans.count == 1)
        #expect(spans.first?.groupIndex == 0)
        #expect(spans.first?.message == "do it")
    }

    @Test
    func externalAgentReplySourceHeaderUsesAgentColors() throws {
        let source = try sourceFile("hermes_deck/Views/Chat/Message/MessageBubble.swift")

        #expect(source.contains("ExternalAgentReplyAttribution.parse(trimmedContent)"))
        // Close-the-loop follow-ups are hidden from the list (the hand-off
        // status cards display the replies instead).
        let detailSource = try sourceFile("hermes_deck/Views/Chat/ChatDetailView.swift")
        #expect(detailSource.contains("$0.isAgentReplyFollowUp != true"))
        #expect(detailSource.contains("AgentHandoffStatusView(items: batch.items)"))
        #expect(source.contains("ExternalAgentReplyContent(attribution: attribution, isComplete: message.completedAt != nil)"))
        #expect(source.contains("ExternalAgentAppearance.color(for: attribution.source)"))
        #expect(source.contains("Color(red: 217 / 255, green: 119 / 255, blue: 86 / 255)"))
        #expect(source.contains("Color(red: 130 / 255, green: 163 / 255, blue: 255 / 255)"))
        #expect(source.contains("Color(red: 150 / 255, green: 100 / 255, blue: 160 / 255)"))
    }

    @Test
    func streamingAssistantMarkdownRenderingIsDebounced() throws {
        let source = try sourceFile("hermes_deck/Views/Chat/Message/MessageBubble.swift")

        #expect(source.contains("StreamingMarkdownContent(source: trimmedContent, isComplete: message.completedAt != nil)"))
        #expect(source.contains("StreamingMarkdownContent(source: attribution.body, isComplete: isComplete)"))
        #expect(source.contains("try? await Task.sleep(nanoseconds: 2_000_000_000)"))
        #expect(source.contains("guard !isComplete, !source.isEmpty else { return }"))
        #expect(source.contains("if isComplete {\n                MarkdownView(source)"))
        #expect(source.contains("} else if renderedSource == source {\n                MarkdownView(renderedSource)"))
        #expect(source.contains("} else if !renderedSource.isEmpty {"))
        #expect(source.contains("Text(streamingTail)"))
        #expect(source.contains("source.hasPrefix(renderedSource)"))
    }

    @Test
    func chatDetailScrollsWhenUserPromptIsAppended() throws {
        let source = try sourceFile("hermes_deck/Views/Chat/ChatDetailView.swift")

        #expect(source.contains("visibleMessages(in: thread).count"))
        #expect(source.contains("didAppendUserPrompt"))
        #expect(source.contains("visibleMessages(in: thread).last?.role == .user"))
        #expect(source.contains("endUserScrollHold()"))
    }

    @Test
    func toolMessageContentDisclosureCollapsesToOneLineByDefault() {
        var disclosure = ToolMessageContentDisclosureState()

        #expect(disclosure.isExpanded == false)
        #expect(disclosure.lineLimit == 1)
        #expect(disclosure.indicatorText == "▸")

        disclosure.toggle()

        #expect(disclosure.isExpanded == true)
        #expect(disclosure.lineLimit == nil)
        #expect(disclosure.indicatorText == "▾")
    }

    @Test
    func historyTimestampFormatterUsesCompactRelativeLabels() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 14, minute: 30)))

        #expect(HistoryTimestampFormatter.displayText(for: try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 9, minute: 5))), now: now, calendar: calendar) == "09:05")
        #expect(HistoryTimestampFormatter.displayText(for: try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 22, minute: 0))), now: now, calendar: calendar) == "Yesterday")
        #expect(HistoryTimestampFormatter.displayText(for: try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 31))), now: now, calendar: calendar) == "3 days ago")
        #expect(HistoryTimestampFormatter.displayText(for: try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 13))), now: now, calendar: calendar) == "3 weeks ago")
        #expect(HistoryTimestampFormatter.displayText(for: try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 3))), now: now, calendar: calendar) == "3 months ago")
        #expect(HistoryTimestampFormatter.displayText(for: try #require(calendar.date(from: DateComponents(year: 2025, month: 6, day: 3))), now: now, calendar: calendar) == "Last year")
        #expect(HistoryTimestampFormatter.displayText(for: try #require(calendar.date(from: DateComponents(year: 2024, month: 6, day: 3))), now: now, calendar: calendar) == "2 years ago")
    }

    @Test
    func sessionDateGrouperSeparatesTodayYesterdayAndOlderMonths() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 14, minute: 30)))
        let sessions = [
            HermesSessionListItem(id: "today", title: "Today", lastActiveDate: try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 9, minute: 0)))),
            HermesSessionListItem(id: "yesterday", title: "Yesterday", lastActiveDate: try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 20, minute: 0)))),
            HermesSessionListItem(id: "may", title: "May", lastActiveDate: try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 31)))),
            HermesSessionListItem(id: "april", title: "April", lastActiveDate: try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 12)))),
        ]

        let groups = SessionDateGrouper.groups(for: sessions, now: now, calendar: calendar)

        #expect(groups.map(\.title) == ["Today", "Yesterday", "2026-05", "2026-04"])
        #expect(groups.map { $0.sessions.map(\.id) } == [["today"], ["yesterday"], ["may"], ["april"]])
    }

    @Test
    func sessionDateGrouperUsesOnlyMonthGroupsWhenTodayAndYesterdayAreEmpty() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 14, minute: 30)))
        let sessions = [
            HermesSessionListItem(id: "may", title: "May", lastActiveDate: try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 31)))),
            HermesSessionListItem(id: "april", title: "April", lastActiveDate: try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 12)))),
        ]

        let groups = SessionDateGrouper.groups(for: sessions, now: now, calendar: calendar)

        #expect(groups.map(\.title) == ["2026-05", "2026-04"])
    }

    @Test
    func sendingMessageCreatesUserAndAssistantMessages() async throws {
        let client = StubHermesAgentClient(reply: "收到：Hello Hermes")
        let store = ChatStore(agentClient: client)

        await store.send("Hello Hermes")

        #expect(store.selectedThread?.messages.map(\.role) == [.user, .assistant])
        #expect(store.selectedThread?.messages.last?.content == "收到：Hello Hermes")
    }

    @Test
    func streamingMessageDeltasUpdateSingleAssistantMessage() async throws {
        let client = StubStreamingHermesAgentClient(events: [
            .messageStart(sessionID: "s1"),
            .messageDelta(sessionID: "s1", text: "Hello"),
            .messageDelta(sessionID: "s1", text: " Hermes"),
            .messageComplete(sessionID: "s1", text: "Hello Hermes", status: "complete", usage: nil),
        ])
        let store = ChatStore(agentClient: client)

        await store.send("Hi")

        #expect(store.selectedThread?.messages.map(\.role) == [.user, .assistant])
        #expect(store.selectedThread?.messages.last?.content == "Hello Hermes")
    }

    @Test
    func toolEventsAttachToAssistantMessage() async throws {
        let client = StubStreamingHermesAgentClient(events: [
            .toolStart(sessionID: "s1", tool: ToolCallEvent(toolID: "tool-1", name: "terminal", state: .running, context: "pwd")),
            .toolComplete(sessionID: "s1", tool: ToolCallEvent(toolID: "tool-1", name: "terminal", state: .complete, summary: "/tmp", durationSeconds: 0.2)),
            .messageComplete(sessionID: "s1", text: "Done", status: "complete", usage: nil),
        ])
        let store = ChatStore(agentClient: client)

        await store.send("Run pwd")

        let assistant = store.selectedThread?.messages.last
        #expect(assistant?.role == .assistant)
        #expect(assistant?.content == "Done")
        #expect(assistant?.toolEvents.count == 1)
        #expect(assistant?.toolEvents.first?.state == .complete)
        #expect(assistant?.toolEvents.first?.context == "pwd")
        #expect(assistant?.toolEvents.first?.summary == "/tmp")
        #expect(assistant?.toolEvents.first?.durationSeconds == 0.2)
    }

    @Test
    func toolEventsWithoutIDsMergeByActiveToolName() async throws {
        let client = StubStreamingHermesAgentClient(events: [
            .toolStart(sessionID: "s1", tool: ToolCallEvent(name: "terminal", state: .running, context: "ls")),
            .toolComplete(sessionID: "s1", tool: ToolCallEvent(name: "terminal", state: .complete, summary: "README.md", durationSeconds: 0.4)),
            .messageComplete(sessionID: "s1", text: "Done", status: "complete", usage: nil),
        ])
        let store = ChatStore(agentClient: client)

        await store.send("List files")

        let toolEvents = store.selectedThread?.messages.last?.toolEvents
        #expect(toolEvents?.count == 1)
        #expect(toolEvents?.first?.state == .complete)
        #expect(toolEvents?.first?.context == "ls")
        #expect(toolEvents?.first?.summary == "README.md")
        #expect(toolEvents?.first?.durationSeconds == 0.4)
    }

    @Test
    func clarifyRequestsAttachToAssistantMessage() async throws {
        let client = StubStreamingHermesAgentClient(events: [
            .clarifyRequest(sessionID: "s1", requestID: "clarify-1", question: "Pick one", choices: ["A", "B"]),
            .messageComplete(sessionID: "s1", text: "", status: "complete", usage: nil),
        ])
        let store = ChatStore(agentClient: client)

        await store.send("Need a choice")

        let assistant = store.selectedThread?.messages.last
        #expect(assistant?.role == .assistant)
        #expect(assistant?.clarifications.count == 1)
        #expect(assistant?.clarifications.first?.question == "Pick one")
        #expect(assistant?.clarifications.first?.choices == ["A", "B"])
        #expect(store.pendingClarificationRequest?.question == "Pick one")
        #expect(store.pendingClarificationRequest?.choices == ["A", "B"])
        #expect(store.pendingClarificationRequest?.requestID == "clarify-1")
        #expect(store.sendState == .idle)
    }

    @Test
    func agentClarifyRequestsAreSeparateFromMainComposer() async throws {
        let client = StubStreamingHermesAgentClient(events: [
            .clarifyRequest(sessionID: "agent", requestID: "agent-clarify", question: "Need target?", choices: []),
            .messageComplete(sessionID: "agent", text: "", status: "complete", usage: nil),
        ])
        let defaultThread = ChatThread(title: "Main", profile: .defaultProfile)
        let store = ChatStore(agentClient: client, threads: [defaultThread])
        let profile = HermesProfile(id: "coding", displayName: "Coding")
        let agentThreadID = store.threadIDForAgentProfile(profile)

        await store.send("ask", in: agentThreadID, profile: profile)

        #expect(store.pendingClarificationRequest == nil)
        #expect(store.pendingClarificationRequest(forAgentThreadID: agentThreadID)?.question == "Need target?")
        #expect(store.pendingClarificationRequest(forAgentThreadID: agentThreadID)?.choices == [])
        #expect(store.pendingClarificationRequest(forAgentThreadID: agentThreadID)?.requestID == "agent-clarify")
    }

    @Test
    func clarificationBannerSupportsChoiceConfirmationAndFreeformInputs() throws {
        let composerSource = try sourceFile("hermes_deck/Views/Chat/Composer/ComposerView.swift")
        let bannersSource = try sourceFile("hermes_deck/Views/Chat/Composer/ComposerBanners.swift")
        let jobsSource = try sourceFile("hermes_deck/Views/Panels/AgentJobsPanelViews.swift")

        #expect(composerSource.contains("ClarificationRequestBanner("))
        #expect(composerSource.contains("var clarificationRequest: ClarificationRequest?"))
        #expect(bannersSource.contains("case confirmation"))
        #expect(bannersSource.contains("case choice"))
        #expect(bannersSource.contains("case freeform"))
        #expect(bannersSource.contains("TextField(\"Type a reply...\""))
        #expect(jobsSource.contains("Picker(\"Profile\", selection: $selectedJobProfile)"))
    }

    @Test
    func clarifyRequestReleasesComposerSendState() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("hermes_deck/Models/ChatStore+Send.swift"),
            encoding: .utf8
        )

        let clarifyCaseStart = try #require(source.range(of: "case .clarifyRequest")?.lowerBound)
        let clarifyCaseEnd = try #require(source[clarifyCaseStart...].range(of: "case .thinkingDelta")?.lowerBound)
        let clarifyCaseSource = String(source[clarifyCaseStart..<clarifyCaseEnd])

        #expect(clarifyCaseSource.contains("showClarificationRequest"))
        #expect(clarifyCaseSource.contains("setSendState(.idle, for: threadID, usesGlobalSendState: usesGlobalSendState)"))
    }

    @Test
    func answeringClarifyRequestRespondsToGatewayWithoutStartingNewPrompt() async throws {
        let client = RecordingStreamingHermesAgentClient(events: [])
        let store = ChatStore(agentClient: client)
        let request = ClarificationRequest(question: "Pick one", choices: ["A", "B"], requestID: "clarify-1")
        guard let threadID = store.selectedThreadID else {
            Issue.record("Expected selected thread")
            return
        }
        store.showClarificationRequest(request, for: threadID, usesGlobalSendState: true)

        store.answerClarificationRequest(store.pendingClarificationRequest, answer: " B ", forAgentThreadID: nil)
        try await Task.sleep(for: .milliseconds(50))

        let responses = await client.clarificationResponses
        #expect(responses.count == 1)
        #expect(responses.first?.0 == "clarify-1")
        #expect(responses.first?.1 == "B")
        #expect(store.pendingClarificationRequest == nil)
    }

    @Test
    func approvalRequestsAreExposedAboveComposer() async throws {
        let client = StubStreamingHermesAgentClient(events: [
            .approvalRequest(sessionID: "s1", requestID: "hermes:s1", text: "Allow shell command?", options: [PermissionOption(id: "session", label: "Allow this session"), PermissionOption(id: "deny", label: "Deny")]),
            .messageComplete(sessionID: "s1", text: "Waiting", status: "complete", usage: nil),
        ])
        let store = ChatStore(agentClient: client)

        await store.send("Run command")

        #expect(store.pendingPermissionRequest?.message == "Allow shell command?")
        #expect(store.pendingPermissionRequest?.choices == ["Allow this session", "Deny"])
        #expect(store.pendingPermissionRequest?.isAnswerable == true)
    }

    @Test
    func hermesApprovalAnswerIsSentBackToGateway() async throws {
        let client = RecordingStreamingHermesAgentClient(events: [
            .approvalRequest(sessionID: "s1", requestID: "hermes:s1", text: "Allow shell command?", options: [PermissionOption(id: "session", label: "Allow this session"), PermissionOption(id: "deny", label: "Deny")]),
            .messageComplete(sessionID: "s1", text: "Waiting", status: "complete", usage: nil),
        ])
        let store = ChatStore(agentClient: client)

        await store.send("Run command")
        store.answerPermission(at: 0)
        try await Task.sleep(for: .milliseconds(50))

        let responses = await client.permissionResponses
        #expect(responses.count == 1)
        #expect(responses.first?.0 == "hermes:s1")
        #expect(responses.first?.1 == "session")
        #expect(store.pendingPermissionRequest == nil)
    }

    @Test
    func dismissingHermesApprovalDeniesGatewayRequest() async throws {
        let client = RecordingStreamingHermesAgentClient(events: [
            .approvalRequest(sessionID: "s1", requestID: "hermes:s1", text: "Allow shell command?", options: [PermissionOption(id: "session", label: "Allow this session"), PermissionOption(id: "deny", label: "Deny")]),
            .messageComplete(sessionID: "s1", text: "Waiting", status: "complete", usage: nil),
        ])
        let store = ChatStore(agentClient: client)

        await store.send("Run command")
        store.dismissPermissionRequest()
        try await Task.sleep(for: .milliseconds(50))

        let responses = await client.permissionResponses
        #expect(responses.count == 1)
        #expect(responses.first?.0 == "hermes:s1")
        #expect(responses.first?.1 == "deny")
        #expect(store.pendingPermissionRequest == nil)
    }

    @Test
    func subagentEventsPopulateTaskPanelState() async throws {
        let client = StubStreamingHermesAgentClient(events: [
            .subagentStart(sessionID: "s1", progress: SubagentProgressEvent(
                id: "sa-1",
                parentID: nil,
                taskIndex: 0,
                taskCount: 1,
                depth: 0,
                goal: "Inspect implementation",
                status: .running,
                model: "Hermes",
                toolName: nil,
                text: nil,
                summary: nil,
                durationSeconds: nil,
                toolCount: nil,
                inputTokens: nil,
                outputTokens: nil,
                reasoningTokens: nil,
                apiCalls: nil,
                costUSD: nil,
                filesRead: [],
                filesWritten: [],
                outputTail: []
            )),
            .subagentThinking(sessionID: "s1", progress: SubagentProgressEvent(
                id: "sa-1",
                parentID: nil,
                taskIndex: 0,
                taskCount: 1,
                depth: 0,
                goal: "Inspect implementation",
                status: nil,
                model: nil,
                toolName: nil,
                text: "Need to read the parser.",
                summary: nil,
                durationSeconds: nil,
                toolCount: nil,
                inputTokens: nil,
                outputTokens: nil,
                reasoningTokens: nil,
                apiCalls: nil,
                costUSD: nil,
                filesRead: [],
                filesWritten: [],
                outputTail: []
            )),
            .subagentTool(sessionID: "s1", progress: SubagentProgressEvent(
                id: "sa-1",
                parentID: nil,
                taskIndex: 0,
                taskCount: 1,
                depth: 0,
                goal: "Inspect implementation",
                status: nil,
                model: nil,
                toolName: "read_file",
                text: "Models.swift",
                summary: nil,
                durationSeconds: nil,
                toolCount: nil,
                inputTokens: nil,
                outputTokens: nil,
                reasoningTokens: nil,
                apiCalls: nil,
                costUSD: nil,
                filesRead: [],
                filesWritten: [],
                outputTail: []
            )),
            .subagentComplete(sessionID: "s1", progress: SubagentProgressEvent(
                id: "sa-1",
                parentID: nil,
                taskIndex: 0,
                taskCount: 1,
                depth: 0,
                goal: "Inspect implementation",
                status: .completed,
                model: nil,
                toolName: nil,
                text: nil,
                summary: "Done",
                durationSeconds: 1.2,
                toolCount: 1,
                inputTokens: 100,
                outputTokens: 50,
                reasoningTokens: nil,
                apiCalls: 1,
                costUSD: nil,
                filesRead: ["Models.swift"],
                filesWritten: [],
                outputTail: [SubagentOutputTailItem(tool: "read_file", preview: "ok")]
            )),
            .messageComplete(sessionID: "s1", text: "Parent done", status: "complete", usage: nil),
        ])
        let store = ChatStore(agentClient: client)

        await store.send("Use delegate_task")

        let subagent = try #require(store.taskSubagents.first)
        #expect(subagent.goal == "Inspect implementation")
        #expect(subagent.status == .completed)
        #expect(subagent.thinking == ["Need to read the parser."])
        #expect(subagent.tools == ["read_file: Models.swift"])
        #expect(subagent.summary == "Done")
        #expect(subagent.durationSeconds == 1.2)
        #expect(subagent.filesRead == ["Models.swift"])
        #expect(subagent.outputTail.first?.preview == "ok")
    }

    @Test
    func thinkingAndReasoningAttachBeforeFinalMessageContent() async throws {
        let client = StubStreamingHermesAgentClient(events: [
            .thinkingDelta(sessionID: "s1", text: "Checking "),
            .thinkingDelta(sessionID: "s1", text: "state"),
            .reasoningDelta(sessionID: "s1", text: "Need context"),
            .messageDelta(sessionID: "s1", text: "Final"),
            .messageComplete(sessionID: "s1", text: "Final answer", status: "complete", usage: nil),
        ])
        let store = ChatStore(agentClient: client)

        await store.send("Explain")

        let assistant = store.selectedThread?.messages.last
        #expect(assistant?.thinkingText == "Checking state")
        #expect(assistant?.reasoningText == "Need context")
        #expect(assistant?.content == "Final answer")
    }

    @Test
    func historySearchMatchesMessagesAndTitlesCaseInsensitively() {
        let store = ChatStore(agentClient: StubHermesAgentClient(reply: "ok"))
        store.createThread(title: "SwiftData Notes")
        store.selectedThread?.messages.append(ChatMessage(role: .assistant, content: "Profile switching is ready."))

        let titleMatches = store.filteredThreads(query: "swiftdata")
        let bodyMatches = store.filteredThreads(query: "PROFILE")

        #expect(titleMatches.count == 1)
        #expect(bodyMatches.count == 1)
    }

    @Test
    func sidebarHistoryOnlyIncludesThreadsAfterNewUserPrompt() async {
        let provider = StubHermesSessionProvider(sessions: [
            HermesSessionListItem(id: "hermes-session-1", title: "Loaded Session"),
        ])
        provider.loadedThreads["hermes-session-1"] = ChatThread(
            title: "Loaded Session",
            messages: [
                ChatMessage(role: .user, content: "Old prompt"),
                ChatMessage(role: .assistant, content: "Old answer"),
            ]
        )
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "New answer"),
            sessionProvider: provider
        )

        #expect(store.historyThreads(query: "").isEmpty)

        store.createThread()

        #expect(store.historyThreads(query: "").isEmpty)

        await store.loadSessionIntoChat(id: "hermes-session-1")

        #expect(store.historyThreads(query: "").isEmpty)

        await store.send("New prompt")

        #expect(store.historyThreads(query: "").map(\.title) == ["Loaded Session"])
        #expect(store.historyThreads(query: "new prompt").count == 1)
    }

    @Test
    func loadingProfilesRefreshesAvailableProfiles() async {
        let provider = StubHermesProfileProvider(profiles: [
            HermesProfile(id: "default", displayName: "Default"),
            HermesProfile(id: "developer", displayName: "developer"),
            HermesProfile(id: "researcher", displayName: "researcher"),
        ])
        let store = ChatStore(agentClient: StubHermesAgentClient(reply: "ok"), profileProvider: provider)

        await store.loadProfiles()

        #expect(store.availableProfiles.map(\.id) == ["default", "developer", "researcher"])
        #expect(store.selectedProfile.id == "default")
    }

    @Test
    func modelConfigurationParserReadsConfiguredModels() {
        let config = """
        model:
          provider: deepseek
          default: deepseek-v4-flash
          base_url: https://api.deepseek.com/v1

        providers:
          gemini:
            model: gemini-2.5-flash
            api_key: configured
            base_url: https://generativelanguage.googleapis.com/v1beta/openai
          ollama:
            name: local-model
            base_url: http://localhost:11434/v1
            api_key: ''

        fallback_providers: []

        auxiliary:
          vision:
            provider: google
            model: gemini-2.5-flash
            api_key_env_var: GEMINI_API_KEY
          web_extract:
            provider: deepseek
            model: deepseek-chat
            api_key_env_var: DEEPSEEK_API_KEY
          approval:
            provider: auto
            model: ''
        """
        let environment = """
        DEEPSEEK_API_KEY=secret
        GEMINI_API_KEY=secret
        """

        let models = HermesModelConfigurationParser.parse(config, environment: environment)

        #expect(models.map(\.id) == [
            "default",
            "provider-gemini",
            "provider-ollama",
            "auxiliary-vision",
            "auxiliary-web_extract",
        ])
        #expect(models.first?.provider == "deepseek")
        #expect(models.first?.model == "deepseek-v4-flash")
        #expect(models.first?.apiKeyStatus == "Configured via DEEPSEEK_API_KEY")
        #expect(models.first { $0.id == "provider-gemini" }?.apiKeyStatus == "Configured")
        #expect(models.first { $0.id == "provider-ollama" }?.apiKeyStatus == "No key required")
        #expect(models.first { $0.id == "auxiliary-vision" }?.apiKeyStatus == "Configured via GEMINI_API_KEY")
    }

    @Test
    func loadingConfiguredModelsUpdatesStoreState() async {
        let provider = StubHermesModelConfigurationProvider(models: [
            HermesConfiguredModel(
                id: "default",
                category: "Default",
                title: "Default Model",
                provider: "deepseek",
                model: "deepseek-v4-flash",
                apiKeyStatus: "Configured"
            ),
        ])
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            modelConfigurationProvider: provider
        )

        await store.loadConfiguredModels()

        guard case .loaded(let models) = store.modelListState else {
            Issue.record("Expected loaded model list state")
            return
        }
        #expect(models.map(\.id) == ["default"])
        #expect(models.first?.model == "deepseek-v4-flash")
    }

    @Test
    func localPluginProviderReadsInstalledPluginManifests() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-plugin-provider-\(UUID().uuidString)", isDirectory: true)
        let configURL = root.appendingPathComponent("config.yaml")
        let userPluginsURL = root.appendingPathComponent("plugins", isDirectory: true)
        let bundledPluginsURL = root.appendingPathComponent("hermes-agent/plugins", isDirectory: true)
        let gatewayDirectory = userPluginsURL.appendingPathComponent("gateway_chat", isDirectory: true)
        let diskCleanupDirectory = bundledPluginsURL.appendingPathComponent("disk-cleanup", isDirectory: true)
        let firecrawlDirectory = bundledPluginsURL
            .appendingPathComponent("web", isDirectory: true)
            .appendingPathComponent("firecrawl", isDirectory: true)
        let unusedDirectory = bundledPluginsURL.appendingPathComponent("unused-plugin", isDirectory: true)

        try FileManager.default.createDirectory(at: gatewayDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: diskCleanupDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: firecrawlDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unusedDirectory, withIntermediateDirectories: true)

        let config = """
        plugins:
          disabled:
          - unused-plugin
          enabled:
          - disk-cleanup
          - gateway_chat
        """
        let gatewayManifest = """
        name: gateway_chat
        version: 0.1.0
        description: "Chat with child Hermes gateways through API server."
        author: NousResearch
        kind: backend
        provides_tools:
          - gateway_chat
        """
        let diskCleanupManifest = """
        name: disk-cleanup
        version: 2.0.0
        description: "Auto-track and clean up ephemeral files created during Hermes sessions."
        author: NousResearch
        hooks:
          - post_tool_call
          - on_session_end
        """
        let firecrawlManifest = """
        name: web-firecrawl
        version: 1.0.0
        description: "Firecrawl web search + content extraction."
        author: NousResearch
        kind: backend
        provides_web_providers:
          - firecrawl
        """
        let unusedManifest = """
        name: unused-plugin
        version: 1.0.0
        description: "Disabled test plugin."
        author: NousResearch
        kind: backend
        """

        try config.write(to: configURL, atomically: true, encoding: .utf8)
        try gatewayManifest.write(to: gatewayDirectory.appendingPathComponent("plugin.yaml"), atomically: true, encoding: .utf8)
        try diskCleanupManifest.write(to: diskCleanupDirectory.appendingPathComponent("plugin.yaml"), atomically: true, encoding: .utf8)
        try firecrawlManifest.write(to: firecrawlDirectory.appendingPathComponent("plugin.yaml"), atomically: true, encoding: .utf8)
        try unusedManifest.write(to: unusedDirectory.appendingPathComponent("plugin.yaml"), atomically: true, encoding: .utf8)

        let provider = LocalHermesPluginProvider(
            configURL: configURL,
            userPluginsURL: userPluginsURL,
            bundledPluginsURL: bundledPluginsURL
        )
        let plugins = try await provider.installedPlugins()

        #expect(plugins.map(\.name) == ["disk-cleanup", "gateway_chat", "unused-plugin", "web-firecrawl"])
        let gateway = try #require(plugins.first { $0.name == "gateway_chat" })
        let diskCleanup = try #require(plugins.first { $0.name == "disk-cleanup" })
        let firecrawl = try #require(plugins.first { $0.name == "web-firecrawl" })
        let unused = try #require(plugins.first { $0.name == "unused-plugin" })
        #expect(gateway.source == "Local")
        #expect(gateway.category == "backend")
        #expect(gateway.status == "Enabled")
        #expect(gateway.capabilities == ["gateway_chat"])
        #expect(diskCleanup.source == "Bundled")
        #expect(diskCleanup.capabilities == ["post_tool_call", "on_session_end"])
        #expect(unused.status == "Disabled")
        #expect(firecrawl.status == "Available")
        #expect(firecrawl.capabilities == ["firecrawl"])
    }

    @Test
    func hermesConfigurationFilePartiallyUpdatesScalarAndPreservesComments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("config.yaml")
        try """
        # Hermes user configuration
        model:
          provider: deepseek
          default: deepseek-chat # selected model

        providers:
          deepseek:
            model: deepseek-chat
            api_key_env_var: DEEPSEEK_API_KEY
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let config = HermesConfigurationFile(url: configURL)
        try config.load()

        #expect(try config.string(at: ["model", "default"]) == "deepseek-chat")

        try config.setString("deepseek-v4-flash", at: ["model", "default"])
        try config.save()

        let updated = try String(contentsOf: configURL, encoding: .utf8)
        #expect(updated.contains("# Hermes user configuration"))
        #expect(updated.contains("default: deepseek-v4-flash # selected model"))
        #expect(updated.contains("api_key_env_var: DEEPSEEK_API_KEY"))
        #expect(!updated.contains("default: deepseek-chat # selected model"))
    }

    @Test
    func hermesConfigurationFileUpdatesSequencesAndCanRemoveValues() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("config.yaml")
        try """
        plugins:
          # disabled plugins stay visible to users
          disabled:
          - old-plugin
          enabled:
          - gateway_chat
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let config = HermesConfigurationFile(url: configURL)
        try config.load()

        #expect(try config.stringArray(at: ["plugins", "enabled"]) == ["gateway_chat"])

        try config.setStringArray(["disk-cleanup", "gateway_chat"], at: ["plugins", "enabled"])
        try config.removeValue(at: ["plugins", "disabled"])
        try config.save()

        let updated = try String(contentsOf: configURL, encoding: .utf8)
        #expect(updated.contains("plugins:"))
        #expect(updated.contains("# disabled plugins stay visible to users"))
        #expect(updated.contains("enabled:\n  - disk-cleanup\n  - gateway_chat"))
        #expect(!updated.contains("disabled:"))
        #expect(!updated.contains("old-plugin"))
    }

    @Test
    func hermesToolListParserReadsToolsSortedByName() {
        let output = """
        Failed to parse /Users/test/.hermes/config.yaml: ignored warning
        Built-in toolsets (cli):
          ✓ enabled  web  🔍 Web Search & Scraping
          ✗ disabled  video  🎬 Video Analysis
          ✓ enabled  browser  🌐 Browser Automation
        """

        let tools = HermesToolListParser.parse(Data(output.utf8))

        #expect(tools.map(\.name) == ["browser", "video", "web"])
        #expect(tools.first { $0.name == "browser" }?.source == "Built-in")
        #expect(tools.first { $0.name == "browser" }?.status == "Enabled")
        #expect(tools.first { $0.name == "browser" }?.summary == "🌐 Browser Automation")
        #expect(tools.first { $0.name == "video" }?.status == "Disabled")
    }

    @Test
    func settingInstalledPluginStatusUpdatesConfigLists() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-plugin-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("config.yaml")
        try """
        plugins:
          enabled:
          - browser
          disabled:
          - web-firecrawl
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let provider = LocalHermesPluginProvider(
            configURL: configURL,
            userPluginsURL: root.appendingPathComponent("plugins", isDirectory: true),
            bundledPluginsURL: root.appendingPathComponent("bundled", isDirectory: true)
        )

        try await provider.setPlugin("web-firecrawl", enabled: true)

        let config = HermesConfigurationFile(url: configURL)
        try config.load()
        #expect(try config.stringArray(at: ["plugins", "enabled"]) == ["browser", "web-firecrawl"])
        #expect(try config.stringArray(at: ["plugins", "disabled"]) == [])
    }

    @Test
    func installingDeckDelegationPluginWritesPluginAndEnablesProfile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-deck-plugin-install-\(UUID().uuidString)", isDirectory: true)
        let provider = LocalHermesPluginProvider(
            configURL: root.appendingPathComponent("config.yaml"),
            userPluginsURL: root.appendingPathComponent("plugins", isDirectory: true),
            bundledPluginsURL: root.appendingPathComponent("bundled", isDirectory: true),
            rootURL: root
        )
        let profile = HermesProfile(id: "coding", displayName: "Coding")

        try await provider.installDeckDelegationPlugin(profile: profile)

        let home = root.appendingPathComponent("profiles").appendingPathComponent("coding")
        let pluginDirectory = home
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("deck-delegate-agent", isDirectory: true)
        let manifest = try String(contentsOf: pluginDirectory.appendingPathComponent("plugin.yaml"), encoding: .utf8)
        let source = try String(contentsOf: pluginDirectory.appendingPathComponent("__init__.py"), encoding: .utf8)
        #expect(manifest.contains("provides_tools:\n  - deck_delegate_agent"))
        #expect(manifest.contains("version: 0.1.2"))
        #expect(source.contains("TOOL_NAME = \"deck_delegate_agent\""))
        #expect(source.contains("\"source_profile_id\": source_profile_id"))
        #expect(!source.contains("HERMES_DECK_ROUTE_SOCKET"))

        let config = HermesConfigurationFile(url: home.appendingPathComponent("config.yaml"))
        try config.load()
        #expect(try config.stringArray(at: ["plugins", "enabled"]) == ["deck-delegate-agent"])
        #expect(try config.stringArray(at: ["plugins", "disabled"]) == [])
    }

    @Test
    func deckDelegationPluginStatusDetectsOutdatedPlugin() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-deck-plugin-status-\(UUID().uuidString)", isDirectory: true)
        let provider = LocalHermesPluginProvider(rootURL: root)
        let profile = HermesProfile(id: "coding", displayName: "Coding")
        let pluginDirectory = root
            .appendingPathComponent("profiles/coding/plugins/deck-delegate-agent", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try """
        name: deck-delegate-agent
        version: 0.1.0
        """.write(to: pluginDirectory.appendingPathComponent("plugin.yaml"), atomically: true, encoding: .utf8)

        let status = try await provider.deckDelegationPluginStatus(profile: profile)

        #expect(status == .outdated(installedVersion: "0.1.0", bundledVersion: "0.1.2"))
    }

    @Test
    func loadingInstalledToolsUpdatesStoreState() async {
        let provider = StubHermesPluginProvider(
            plugins: [],
            tools: [
                HermesInstalledTool(
                    id: "local-gateway-chat",
                    name: "gateway_chat",
                    source: "Local",
                    status: "Enabled",
                    summary: "Chat with child Hermes gateways"
                ),
            ]
        )
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            pluginProvider: provider
        )

        await store.loadInstalledTools()

        guard case .loaded(let tools) = store.toolListState else {
            Issue.record("Expected loaded tool list state")
            return
        }
        #expect(tools.map(\.name) == ["gateway_chat"])
        #expect(tools.first?.summary == "Chat with child Hermes gateways")
    }

    @Test
    func installingDeckDelegationToolUpdatesStoreStateAndReloadsTools() async {
        let provider = StubHermesPluginProvider(plugins: [], tools: [])
        let store = ChatStore(agentClient: StubHermesAgentClient(reply: "ok"), pluginProvider: provider)
        store.selectedProfile = HermesProfile(id: "coding", displayName: "Coding")

        await store.installDeckDelegationTool()

        #expect(provider.installedDeckDelegationProfiles == ["coding"])
        #expect(store.deckDelegationToolInstallState == .installed)
        guard case .loaded(let tools) = store.toolListState else {
            Issue.record("Expected loaded tool list state")
            return
        }
        #expect(tools.map(\.name) == ["deck"])
        #expect(tools.first?.status == "Enabled")
    }

    @Test
    func settingInstalledToolStatusUpdatesConfigLists() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-tool-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("config.yaml")
        try """
        tools:
          # explicit tool selections
          enabled:
          - browser
          disabled:
          - web
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let provider = LocalHermesPluginProvider(
            configURL: configURL,
            userPluginsURL: root.appendingPathComponent("plugins", isDirectory: true),
            bundledPluginsURL: root.appendingPathComponent("bundled", isDirectory: true)
        )

        try await provider.setTool("web", enabled: true)

        let updated = try String(contentsOf: configURL, encoding: .utf8)
        #expect(updated.contains("# explicit tool selections"))
        #expect(updated.contains("enabled:\n  - browser\n  - web"))
        #expect(updated.contains("disabled: []"))
        let config = HermesConfigurationFile(url: configURL)
        try config.load()
        #expect(try config.stringArray(at: ["tools", "enabled"]) == ["browser", "web"])
        #expect(try config.stringArray(at: ["tools", "disabled"]) == [])
    }

    @Test
    func togglingToolStatusUpdatesProviderAndReloadsTools() async {
        let provider = StubHermesPluginProvider(
            plugins: [],
            tools: [
                HermesInstalledTool(
                    id: "Built-in-web",
                    name: "web",
                    source: "Built-in",
                    status: "Disabled",
                    summary: "Web Search"
                ),
            ]
        )
        let store = ChatStore(agentClient: StubHermesAgentClient(reply: "ok"), pluginProvider: provider)

        await store.loadInstalledTools()
        await store.setTool(HermesInstalledTool(id: "Built-in-web", name: "web", status: "Disabled"), enabled: true)

        guard case .loaded(let tools) = store.toolListState else {
            Issue.record("Expected loaded tool list state")
            return
        }
        #expect(provider.updatedTools.map(\.0) == ["web"])
        #expect(provider.updatedTools.map(\.1) == [true])
        #expect(tools.first?.status == "Enabled")
    }

    @Test
    func hermesSkillListParserReadsTableRows() {
        let output = """
                                Installed Skills                                
        ┏━━━━━━━━━━━━━━┳━━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━┓
        ┃ Name         ┃ Category ┃ Source  ┃ Trust   ┃ Status  ┃
        ┡━━━━━━━━━━━━━━╇━━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━┩
        │ dogfood      │          │ builtin │ builtin │ enabled │
        │ apple-apps   │ apple    │ local   │ local   │ enabled │
        └──────────────┴──────────┴─────────┴─────────┴─────────┘
        1 builtin, 1 local — 2 enabled, 0 disabled
        """

        let skills = HermesSkillListParser.parse(Data(output.utf8))

        #expect(skills.map(\.name) == ["dogfood", "apple-apps"])
        #expect(skills.first?.source == "builtin")
        #expect(skills.first?.status == "enabled")
        #expect(skills.last?.category == "apple")
    }

    @Test
    func loadingInstalledSkillsUpdatesStoreState() async {
        let provider = StubHermesSkillProvider(skills: [
            HermesInstalledSkill(
                id: "dogfood",
                name: "dogfood",
                category: "",
                source: "builtin",
                trust: "builtin",
                status: "enabled"
            ),
        ])
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            skillProvider: provider
        )

        await store.loadInstalledSkills()

        guard case .loaded(let skills) = store.skillListState else {
            Issue.record("Expected loaded skill list state")
            return
        }
        #expect(skills.map(\.name) == ["dogfood"])
        #expect(skills.first?.source == "builtin")
    }

    @Test
    func settingInstalledSkillStatusUpdatesConfigLists() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-skill-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("config.yaml")
        try """
        skills:
          enabled:
          - dogfood
          disabled:
          - apple-apps
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let provider = LocalHermesSkillProvider(configURL: configURL)

        try await provider.setSkill("apple-apps", enabled: true)

        let config = HermesConfigurationFile(url: configURL)
        try config.load()
        #expect(try config.stringArray(at: ["skills", "enabled"]) == ["dogfood", "apple-apps"])
        #expect(try config.stringArray(at: ["skills", "disabled"]) == [])
    }

    @Test
    func togglingSkillStatusUpdatesProviderAndReloadsSkills() async {
        let provider = StubHermesSkillProvider(skills: [
            HermesInstalledSkill(
                id: "apple-apps",
                name: "apple-apps",
                category: "apple",
                source: "local",
                trust: "local",
                status: "disabled"
            ),
        ])
        let store = ChatStore(agentClient: StubHermesAgentClient(reply: "ok"), skillProvider: provider)

        await store.loadInstalledSkills()
        await store.setSkill(provider.skills[0], enabled: true)

        guard case .loaded(let skills) = store.skillListState else {
            Issue.record("Expected loaded skill list state")
            return
        }
        #expect(provider.updatedSkills.map(\.0) == ["apple-apps"])
        #expect(provider.updatedSkills.map(\.1) == [true])
        #expect(skills.first?.status == "enabled")
    }

    @Test
    func sessionListParserReadsHermesSessionsTableOutput() {
        let output = """
        Title                            Preview                                  Last Active   ID
        ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
        让researher搜索今日国际新闻               让researher搜索今日国际新闻                       39m ago       20260603_100649_818a5e
        Initial Friendly Greeting and    hi                                       14h ago       20260602_204012_bd58d6
        —                                你好                                       13h ago       20260602_205951_da3aa5
        —                                                                         yesterday     20260602_115156_ca1982
        """

        let sessions = HermesSessionListParser.parse(Data(output.utf8))

        #expect(sessions.count == 3)
        let newsSession = sessions.first { $0.id == "20260603_100649_818a5e" }
        let greetingSession = sessions.first { $0.id == "20260602_204012_bd58d6" }
        let previewOnlySession = sessions.first { $0.id == "20260602_205951_da3aa5" }

        #expect(newsSession?.title == "让researher搜索今日国际新闻")
        #expect(newsSession?.preview == "让researher搜索今日国际新闻")
        #expect(newsSession?.lastActive == "39m ago")
        #expect(greetingSession?.title == "Initial Friendly Greeting and")
        #expect(greetingSession?.preview == "hi")
        #expect(previewOnlySession?.title == "你好")
        #expect(previewOnlySession?.preview == "你好")
        #expect(previewOnlySession?.lastActive == "13h ago")
    }

    @Test
    func sessionDatabaseParserReadsSourceAndFiltersEmptyRows() {
        let output = """
        20260603_100649_818a5e\t让researher搜索今日国际新闻\ttui\t8\t让researher搜索今日国际新闻\t1780442809
        20260602_205951_da3aa5\t—\tcli\t2\t你好\t1780395593
        20260602_115156_ca1982\t—\ttui\t0\t\t1780362716
        """

        let sessions = HermesSessionDatabaseParser.parse(Data(output.utf8))

        #expect(sessions.count == 2)
        #expect(sessions[0].id == "20260603_100649_818a5e")
        #expect(sessions[0].source == "tui")
        #expect(sessions[0].messageCount == 8)
        #expect(sessions[1].title == "你好")
        #expect(sessions[1].source == "cli")
        #expect(sessions[1].messageCount == 2)
    }

    @Test
    func loadingSessionsRefreshesSessionListState() async {
        let provider = StubHermesSessionProvider(sessions: [
            HermesSessionListItem(
                id: "20260603_100649_818a5e",
                title: "Research news",
                preview: "Search today's news",
                source: "tui",
                messageCount: 4,
                lastActive: "39m ago"
            ),
        ])
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            sessionProvider: provider
        )

        await store.loadSessions()

        #expect(store.sessionListState.sessions.map(\.id) == ["20260603_100649_818a5e"])
        #expect(provider.requests == [SessionPageRequest(limit: 100, offset: 0)])
        #expect(store.canLoadMoreSessions == false)
    }

    @Test
    func loadingMoreSessionsAppendsNextPage() async {
        let provider = StubHermesSessionProvider(pages: [
            [
                HermesSessionListItem(id: "session-1", title: "First"),
                HermesSessionListItem(id: "session-2", title: "Second"),
            ],
            [
                HermesSessionListItem(id: "session-3", title: "Third"),
            ],
        ])
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            sessionProvider: provider,
            sessionPageSize: 2
        )

        await store.loadSessions()
        await store.loadMoreSessions()

        #expect(provider.requests == [
            SessionPageRequest(limit: 2, offset: 0),
            SessionPageRequest(limit: 2, offset: 2),
        ])
        #expect(store.sessionListState.sessions.map(\.id) == ["session-1", "session-2", "session-3"])
        #expect(store.canLoadMoreSessions == false)
    }

    @Test
    func deletingSessionAsksProviderToDeleteAndRefreshesSessions() async {
        let provider = StubHermesSessionProvider(sessions: [
            HermesSessionListItem(id: "session-1", title: "First", source: "tui", messageCount: 2),
            HermesSessionListItem(id: "session-2", title: "Second", source: "cli", messageCount: 1),
        ])
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            sessionProvider: provider
        )

        await store.loadSessions()
        await store.deleteSession(id: "session-1")

        #expect(provider.deletedIDs == ["session-1"])
        #expect(store.sessionListState.sessions.map(\.id) == ["session-2"])
    }

    @Test
    func deletingSessionAlsoRemovesItFromSidebarHistory() async {
        let provider = StubHermesSessionProvider(sessions: [
            HermesSessionListItem(id: "session-1", title: "First"),
            HermesSessionListItem(id: "session-2", title: "Second"),
        ])
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            sessionProvider: provider
        )

        await store.loadSessions()
        await store.loadHistorySessions()
        #expect(store.historySessions.map(\.id) == ["session-1", "session-2"])

        await store.deleteSession(id: "session-1")

        #expect(store.historySessions.map(\.id) == ["session-2"])
    }

    @Test
    func isRespondingTracksMainAndAgentSendStates() {
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            sessionProvider: StubHermesSessionProvider(sessions: [])
        )

        #expect(store.isResponding == false)

        store.sendState = .sending
        #expect(store.isResponding == true)

        store.sendState = .idle
        store.agentSendStates[UUID()] = .sending
        #expect(store.isResponding == true)

        store.agentSendStates = [:]
        #expect(store.isResponding == false)
    }

    @Test
    func deletingSessionDoesNotResetLoadedCountToPageSize() async {
        let provider = StubHermesSessionProvider(sessions: [
            HermesSessionListItem(id: "session-1", title: "First"),
            HermesSessionListItem(id: "session-2", title: "Second"),
            HermesSessionListItem(id: "session-3", title: "Third"),
            HermesSessionListItem(id: "session-4", title: "Fourth"),
            HermesSessionListItem(id: "session-5", title: "Fifth"),
        ])
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            sessionProvider: provider,
            sessionPageSize: 2
        )

        await store.loadSessions()
        #expect(store.sessionListState.sessions.map(\.id) == ["session-1", "session-2"])

        await store.loadMoreSessions()
        #expect(store.sessionListState.sessions.map(\.id) == ["session-1", "session-2", "session-3", "session-4"])

        await store.deleteSession(id: "session-2")

        #expect(store.sessionListState.sessions.map(\.id) == ["session-1", "session-3", "session-4", "session-5"])
    }

    @Test
    func loadingSessionIntoChatSelectsThreadFromProvider() async {
        let provider = StubHermesSessionProvider(sessions: [
            HermesSessionListItem(id: "hermes-session-1", title: "Loaded Session"),
        ])
        provider.loadedThreads["hermes-session-1"] = ChatThread(
            title: "Loaded Session",
            messages: [
                ChatMessage(role: .user, content: "Hi"),
                ChatMessage(role: .assistant, content: "Hello"),
            ]
        )
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            sessionProvider: provider
        )

        await store.loadSessionIntoChat(id: "hermes-session-1")

        #expect(provider.loadedThreadIDs == ["hermes-session-1"])
        #expect(store.selectedThread?.title == "Loaded Session")
        #expect(store.selectedThread?.messages.map(\.content) == ["Hi", "Hello"])
    }

    @Test
    func sessionThreadParserAttachesDatabaseToolRowsToAssistantMessage() throws {
        let json = """
        [
          {
            "session_id": "s1",
            "title": "Tool Session",
            "started_at": 1780442800,
            "updated_at": 1780442810,
            "role": "user",
            "content": "Run pwd",
            "reasoning": "",
            "tool_name": "",
            "tool_call_id": "",
            "timestamp": 1780442801
          },
          {
            "session_id": "s1",
            "title": "Tool Session",
            "started_at": 1780442800,
            "updated_at": 1780442810,
            "role": "assistant",
            "content": "",
            "reasoning": "",
            "tool_name": "",
            "tool_call_id": "",
            "timestamp": 1780442802
          },
          {
            "session_id": "s1",
            "title": "Tool Session",
            "started_at": 1780442800,
            "updated_at": 1780442810,
            "role": "tool",
            "content": "/Users/cxd/Developer/hermes_mac_ui",
            "reasoning": "",
            "tool_name": "terminal",
            "tool_call_id": "tool-1",
            "timestamp": 1780442803
          },
          {
            "session_id": "s1",
            "title": "Tool Session",
            "started_at": 1780442800,
            "updated_at": 1780442810,
            "role": "assistant",
            "content": "Done",
            "reasoning": "",
            "tool_name": "",
            "tool_call_id": "",
            "timestamp": 1780442804
          }
        ]
        """

        let thread = try HermesSessionThreadParser.parse(Data(json.utf8), fallbackID: "s1")

        #expect(thread.messages.map(\.role) == [.user, .assistant])
        #expect(thread.messages[1].content == "Done")
        #expect(thread.messages[1].toolEvents.count == 1)
        #expect(thread.messages[1].toolEvents.first?.toolID == "tool-1")
        #expect(thread.messages[1].toolEvents.first?.name == "terminal")
        #expect(thread.messages[1].toolEvents.first?.summary == "/Users/cxd/Developer/hermes_mac_ui")
    }

    @Test
    func sessionThreadParserMatchesToolRowsToAssistantToolCallsByID() throws {
        let json = """
        [
          {
            "session_id": "s1",
            "title": "Tool Match Session",
            "started_at": 1780442800,
            "updated_at": 1780442810,
            "role": "assistant",
            "content": "",
            "reasoning": "",
            "tool_calls": "[{\\"id\\":\\"call-a\\",\\"call_id\\":\\"call-a\\",\\"name\\":\\"terminal\\",\\"arguments\\":\\"pwd\\"}]",
            "tool_name": "",
            "tool_call_id": "",
            "timestamp": 1780442801
          },
          {
            "session_id": "s1",
            "title": "Tool Match Session",
            "started_at": 1780442800,
            "updated_at": 1780442810,
            "role": "assistant",
            "content": "",
            "reasoning": "",
            "tool_calls": "[{\\"id\\":\\"call-b\\",\\"call_id\\":\\"call-b\\",\\"name\\":\\"delegate_task\\",\\"arguments\\":\\"news\\"}]",
            "tool_name": "",
            "tool_call_id": "",
            "timestamp": 1780442802
          },
          {
            "session_id": "s1",
            "title": "Tool Match Session",
            "started_at": 1780442800,
            "updated_at": 1780442810,
            "role": "tool",
            "content": "delegate result",
            "reasoning": "",
            "tool_calls": "",
            "tool_name": "delegate_task",
            "tool_call_id": "call-b",
            "timestamp": 1780442803
          },
          {
            "session_id": "s1",
            "title": "Tool Match Session",
            "started_at": 1780442800,
            "updated_at": 1780442810,
            "role": "tool",
            "content": "terminal result",
            "reasoning": "",
            "tool_calls": "",
            "tool_name": "terminal",
            "tool_call_id": "call-a",
            "timestamp": 1780442804
          }
        ]
        """

        let thread = try HermesSessionThreadParser.parse(Data(json.utf8), fallbackID: "s1")

        #expect(thread.messages.count == 1)
        #expect(thread.messages[0].toolEvents.map(\.toolID) == ["call-a", "call-b"])
        #expect(thread.messages[0].toolEvents.map(\.summary) == ["terminal result", "delegate result"])
    }


    @Test
    func sessionInfoUpdatesComposerRuntimeSummary() async throws {
        let client = StubStreamingHermesAgentClient(events: [
            .sessionInfo(
                sessionID: "s1",
                info: HermesSessionInfo(model: "Hermes 4 70B", contextLength: 128000, usedTokens: 2140)
            ),
            .messageComplete(sessionID: "s1", text: "Ready", status: "complete", usage: nil),
        ])
        let store = ChatStore(agentClient: client)

        await store.send("Hi")

        #expect(store.sessionInfo.displayText == "Hermes 4 70B · 2.1K/128K")
    }

    @Test
    func sessionInfoDisplayTextAbbreviatesLargeTokenCounts() {
        let thousands = HermesSessionInfo(model: "Hermes", contextLength: 128000, usedTokens: 2140)
        let millions = HermesSessionInfo(model: "Hermes", contextLength: 2_000_000, usedTokens: 1_250_000)

        #expect(thousands.displayText == "Hermes · 2.1K/128K")
        #expect(millions.displayText == "Hermes · 1.3M/2M")
    }

    @Test
    func sessionInfoDisplayTextShowsPartialTokenUsage() {
        let contextOnly = HermesSessionInfo(model: "Hermes", contextLength: 128000)
        let usedOnly = HermesSessionInfo(model: "Hermes", usedTokens: 2140)

        #expect(contextOnly.displayText == "Hermes · ?/128K")
        #expect(usedOnly.displayText == "Hermes · 2.1K/?")
    }

    @Test
    func concurrentLoadSessionsAndLoadMoreSessionsDoesNotCorruptState() async throws {
        let provider = StubDelayingHermesSessionProvider()
        
        let store = ChatStore(
            agentClient: StubHermesAgentClient(reply: "ok"),
            sessionProvider: provider,
            sessionPageSize: 2
        )
        
        provider.resultSessions = [
            HermesSessionListItem(id: "session-1", title: "First"),
            HermesSessionListItem(id: "session-2", title: "Second")
        ]
        await store.loadSessions()
        
        #expect(store.canLoadMoreSessions == true)
        #expect(store.sessionListState.sessions.map(\.id) == ["session-1", "session-2"])
        
        let session3 = HermesSessionListItem(id: "session-3", title: "Third")
        
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let (finishStream, finishContinuation) = AsyncStream<Void>.makeStream()
        
        provider.onSessions = { request in
            if request.offset == 2 {
                continuation.yield()
                for await _ in finishStream {
                    break
                }
            }
        }
        
        provider.resultSessions = [session3]
        
        let loadMoreTask = Task {
            await store.loadMoreSessions()
        }
        
        for await _ in stream {
            break
        }
        
        provider.onSessions = nil
        provider.resultSessions = [
            HermesSessionListItem(id: "session-refresh-1", title: "Refresh 1"),
            HermesSessionListItem(id: "session-refresh-2", title: "Refresh 2")
        ]
        
        await store.loadSessions()
        #expect(store.sessionListState.sessions.map(\.id) == ["session-refresh-1", "session-refresh-2"])
        
        finishContinuation.yield()
        _ = await loadMoreTask.result
        
        #expect(store.sessionListState.sessions.map(\.id) == ["session-refresh-1", "session-refresh-2"])
    }
}

private final class StubDelayingHermesSessionProvider: HermesSessionProvider, @unchecked Sendable {
    var onSessions: ((SessionPageRequest) async -> Void)?
    var resultSessions: [HermesSessionListItem] = []

    func sessions(page: SessionPageRequest) async throws -> [HermesSessionListItem] {
        if let onSessions {
            await onSessions(page)
        }
        return resultSessions
    }

    func deleteSession(id: String) async throws {}

    func sessionThread(id: String) async throws -> ChatThread {
        ChatThread(title: id)
    }
}

@MainActor private final class RecordingHermesAgentClient: HermesAgentClient {
    let reply: String
    private var recordedRequests: [HermesChatRequest] = []

    init(reply: String) {
        self.reply = reply
    }

    var requests: [HermesChatRequest] {
        recordedRequests
    }

    func send(_ request: HermesChatRequest) async throws -> HermesChatResponse {
        recordedRequests.append(request)
        return HermesChatResponse(content: reply)
    }
}

@MainActor private final class RecordingStreamingHermesAgentClient: HermesAgentClient {
    let events: [HermesAgentEvent]
    private var recordedPermissionResponses: [(String, String)] = []
    private var recordedClarificationResponses: [(String, String)] = []

    init(events: [HermesAgentEvent]) {
        self.events = events
    }

    var permissionResponses: [(String, String)] {
        recordedPermissionResponses
    }

    var clarificationResponses: [(String, String)] {
        recordedClarificationResponses
    }

    func send(_ request: HermesChatRequest) async throws -> HermesChatResponse {
        let final = events.compactMap { event -> String? in
            if case .messageComplete(_, let text, _, _) = event { return text }
            return nil
        }.last ?? ""
        return HermesChatResponse(content: final)
    }

    nonisolated func eventStream(for request: HermesChatRequest) -> AsyncThrowingStream<HermesAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func respondToPermission(requestID: String, optionID: String) async {
        recordedPermissionResponses.append((requestID, optionID))
    }

    func respondToClarification(requestID: String, answer: String) async {
        recordedClarificationResponses.append((requestID, answer))
    }
}

private struct StubHermesProfileProvider: HermesProfileProvider {
    var values: [HermesProfile]

    init(profiles: [HermesProfile]) {
        self.values = profiles
    }

    func profiles() async throws -> [HermesProfile] {
        values
    }
}

private struct StubHermesModelConfigurationProvider: HermesModelConfigurationProvider {
    var models: [HermesConfiguredModel]

    func configuredModels() async throws -> [HermesConfiguredModel] {
        models
    }
}

private final class StubHermesJobProvider: HermesJobProvider, @unchecked Sendable {
    var jobs: [HermesScheduledJob]
    var requestedProfiles: [String] = []

    init(jobs: [HermesScheduledJob]) {
        self.jobs = jobs
    }

    func jobs(for profile: HermesProfile) async throws -> [HermesScheduledJob] {
        requestedProfiles.append(profile.id)
        return jobs
    }
}

private final class StubHermesPluginProvider: HermesPluginProvider, @unchecked Sendable {
    var plugins: [HermesInstalledPlugin]
    var tools: [HermesInstalledTool] = []
    var deckDelegationStatus: DeckDelegationToolStatus = .missing
    var updatedPlugins: [(String, Bool)] = []
    var updatedTools: [(String, Bool)] = []
    var installedDeckDelegationProfiles: [String] = []

    init(plugins: [HermesInstalledPlugin], tools: [HermesInstalledTool] = []) {
        self.plugins = plugins
        self.tools = tools
    }

    func installedPlugins() async throws -> [HermesInstalledPlugin] {
        plugins
    }

    func installedTools() async throws -> [HermesInstalledTool] {
        tools
    }

    func setPlugin(_ name: String, enabled: Bool) async throws {
        updatedPlugins.append((name, enabled))
        plugins = plugins.map { plugin in
            guard plugin.name == name else { return plugin }
            var updated = plugin
            updated.status = enabled ? "Enabled" : "Disabled"
            return updated
        }
    }

    func setTool(_ name: String, enabled: Bool) async throws {
        updatedTools.append((name, enabled))
        tools = tools.map { tool in
            guard tool.name == name else { return tool }
            var updated = tool
            updated.status = enabled ? "Enabled" : "Disabled"
            return updated
        }
    }

    func installDeckDelegationPlugin(profile: HermesProfile) async throws {
        installedDeckDelegationProfiles.append(profile.id)
        deckDelegationStatus = .current(version: "0.1.2")
        tools = [
            HermesInstalledTool(
                id: "Plugin-deck",
                name: "deck",
                source: "Plugin",
                status: "Enabled",
                summary: "Deck"
            ),
        ]
    }

    func deckDelegationPluginStatus(profile: HermesProfile) async throws -> DeckDelegationToolStatus {
        deckDelegationStatus
    }
}

private final class StubHermesSkillProvider: HermesSkillProvider, @unchecked Sendable {
    var skills: [HermesInstalledSkill]
    var updatedSkills: [(String, Bool)] = []

    init(skills: [HermesInstalledSkill]) {
        self.skills = skills
    }

    func installedSkills() async throws -> [HermesInstalledSkill] {
        skills
    }

    func setSkill(_ name: String, enabled: Bool) async throws {
        updatedSkills.append((name, enabled))
        skills = skills.map { skill in
            guard skill.name == name else { return skill }
            var updated = skill
            updated.status = enabled ? "enabled" : "disabled"
            return updated
        }
    }
}

private final class StubHermesSessionProvider: HermesSessionProvider, @unchecked Sendable {
    var values: [HermesSessionListItem]
    var pages: [[HermesSessionListItem]]?
    var deletedIDs: [String] = []
    var requests: [SessionPageRequest] = []
    var loadedThreadIDs: [String] = []
    var loadedThreads: [String: ChatThread] = [:]

    init(sessions: [HermesSessionListItem]) {
        self.values = sessions
        self.pages = nil
    }

    init(pages: [[HermesSessionListItem]]) {
        self.values = pages.flatMap { $0 }
        self.pages = pages
    }

    func sessions(page: SessionPageRequest) async throws -> [HermesSessionListItem] {
        requests.append(page)
        if let pages {
            let index = requests.count - 1
            guard pages.indices.contains(index) else { return [] }
            return pages[index]
        }

        let startIndex = min(page.offset, values.count)
        let endIndex = min(startIndex + page.limit, values.count)
        return Array(values[startIndex..<endIndex])
    }

    func deleteSession(id: String) async throws {
        deletedIDs.append(id)
        values.removeAll { $0.id == id }
        pages = pages?.map { page in page.filter { $0.id != id } }
    }

    func sessionThread(id: String) async throws -> ChatThread {
        loadedThreadIDs.append(id)
        return loadedThreads[id] ?? ChatThread(title: id)
    }
}

/// Holds each turn open until the test releases it, so turn-serialization
/// ordering can be asserted deterministically.
@MainActor
final class GatedHermesAgentClient: HermesAgentClient {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var started = 0

    func releaseNext() async {
        while waiters.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        waiters.removeFirst().resume()
    }

    func send(_ request: HermesChatRequest) async throws -> HermesChatResponse {
        HermesChatResponse(content: "ok")
    }

    nonisolated func eventStream(for request: HermesChatRequest) -> AsyncThrowingStream<HermesAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                await self.noteStartedAndWait()
                continuation.yield(.messageComplete(sessionID: "s", text: "ok", status: "complete", usage: nil))
                continuation.finish()
            }
        }
    }

    private func noteStartedAndWait() async {
        started += 1
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Returns a different canned reply per turn, so multi-turn flows (like the
/// malformed-block self-correction) can be scripted.
@MainActor
final class SequencedHermesAgentClient: HermesAgentClient {
    private var replies: [String]

    init(replies: [String]) {
        self.replies = replies
    }

    private func nextReply() -> String {
        replies.isEmpty ? "ok" : replies.removeFirst()
    }

    func send(_ request: HermesChatRequest) async throws -> HermesChatResponse {
        HermesChatResponse(content: nextReply())
    }

    nonisolated func eventStream(for request: HermesChatRequest) -> AsyncThrowingStream<HermesAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                let reply = nextReply()
                continuation.yield(.messageComplete(sessionID: "s", text: reply, status: "complete", usage: nil))
                continuation.finish()
            }
        }
    }
}
