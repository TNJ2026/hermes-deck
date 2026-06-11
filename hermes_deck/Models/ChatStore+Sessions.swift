import Foundation

/// Stored session history: sidebar list, pagination, deletion, and
/// loading a stored session back into the chat.
extension ChatStore {
    func loadHistorySessions(limit: Int = 10) async {
        let profile = selectedProfile
        do {
            let page = try await sessionProvider.sessions(
                page: SessionPageRequest(limit: limit, offset: 0),
                profile: profile
            )
            guard profile.id == selectedProfile.id else { return }
            historySessions = Array(page.prefix(limit))
        } catch {
            if error is CancellationError { return }
            historySessions = []
        }
    }

    func loadSessions() async {
        sessionLoadGeneration += 1
        let generation = sessionLoadGeneration

        sessionListState = .loading
        canLoadMoreSessions = false
        isLoadingMoreSessions = false
        let profile = selectedProfile
        do {
            let page = try await sessionProvider.sessions(page: SessionPageRequest(limit: sessionPageSize, offset: 0, query: sessionSearchQuery.isEmpty ? nil : sessionSearchQuery), profile: profile)
            guard generation == sessionLoadGeneration else { return }
            sessionListState = .loaded(page)
            canLoadMoreSessions = page.count == sessionPageSize
        } catch {
            guard generation == sessionLoadGeneration else { return }
            if error is CancellationError { return }
            sessionListState = .failed(error.localizedDescription)
        }
    }

    func loadMoreSessions() async {
        guard !isLoadingMoreSessions, canLoadMoreSessions else { return }
        let currentSessions = sessionListState.sessions
        guard !currentSessions.isEmpty else { return }

        let generation = sessionLoadGeneration
        isLoadingMoreSessions = true
        let profile = selectedProfile
        do {
            let page = try await sessionProvider.sessions(
                page: SessionPageRequest(limit: sessionPageSize, offset: currentSessions.count, query: sessionSearchQuery.isEmpty ? nil : sessionSearchQuery),
                profile: profile
            )
            guard generation == sessionLoadGeneration else {
                isLoadingMoreSessions = false
                return
            }
            sessionListState = .loaded(currentSessions + page)
            canLoadMoreSessions = page.count == sessionPageSize
        } catch {
            guard generation == sessionLoadGeneration else {
                isLoadingMoreSessions = false
                return
            }
            if error is CancellationError {
                isLoadingMoreSessions = false
                return
            }
            sessionListState = .failed(error.localizedDescription)
        }
        isLoadingMoreSessions = false
    }

    func deleteSession(id: String) async {
        sessionLoadGeneration += 1
        let generation = sessionLoadGeneration

        let profile = selectedProfile
        do {
            try await sessionProvider.deleteSession(id: id, profile: profile)

            // Sidebar History is a separate list from the session list, so drop
            // the deleted session there too instead of waiting for a reload.
            historySessions.removeAll { $0.id == id }

            guard generation == sessionLoadGeneration else { return }

            let currentCount = sessionListState.sessions.count
            if currentCount > 0 {
                let limit = max(sessionPageSize, currentCount)
                let page = try await sessionProvider.sessions(page: SessionPageRequest(limit: limit, offset: 0, query: sessionSearchQuery.isEmpty ? nil : sessionSearchQuery), profile: profile)
                guard generation == sessionLoadGeneration else { return }
                sessionListState = .loaded(page)
                canLoadMoreSessions = page.count == limit
            } else {
                let page = try await sessionProvider.sessions(page: SessionPageRequest(limit: sessionPageSize, offset: 0, query: sessionSearchQuery.isEmpty ? nil : sessionSearchQuery), profile: profile)
                guard generation == sessionLoadGeneration else { return }
                sessionListState = .loaded(page)
                canLoadMoreSessions = page.count == sessionPageSize
            }
        } catch {
            guard generation == sessionLoadGeneration else { return }
            if error is CancellationError { return }
            sessionListState = .failed(error.localizedDescription)
        }
    }

    func loadSessionIntoChat(id: String) async {
        let profile = selectedProfile
        do {
            var thread = try await sessionProvider.sessionThread(id: id, profile: profile)
            thread.profile = profile
            threads.insert(thread, at: 0)
            selectedThreadID = thread.id
            selectedProfile = profile
        } catch {
            sessionListState = .failed(error.localizedDescription)
        }
    }
}
