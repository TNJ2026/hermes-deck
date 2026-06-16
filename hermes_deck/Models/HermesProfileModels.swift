import Foundation

struct HermesProfile: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var displayName: String
    var endpoint: URL

    nonisolated init(id: String, displayName: String? = nil, endpoint: URL? = nil) {
        self.id = id
        self.displayName = displayName ?? HermesProfile.displayName(for: id)
        self.endpoint = endpoint ?? HermesProfile.endpoint(for: id)
    }

    nonisolated static let defaultProfile = HermesProfile(
        id: "default",
        displayName: "Hermes agent"
    )

    nonisolated static let coding = HermesProfile(
        id: "coding",
        displayName: "Coding"
    )

    nonisolated static let research = HermesProfile(
        id: "research",
        displayName: "Research"
    )

    nonisolated static let presets = [defaultProfile, coding, research]

    nonisolated static func endpoint(for profileID: String) -> URL {
        let normalized = profileID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized != "default" else {
            return URL(string: "http://127.0.0.1:8765/chat")!
        }
        return URL(string: "http://127.0.0.1:8765/chat?profile=\(normalized)")!
    }

    nonisolated private static func displayName(for profileID: String) -> String {
        let normalized = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Hermes agent" }
        if normalized == "default" { return "Hermes agent" }
        return normalized
    }
}

enum ChatSendState: Equatable, Sendable {
    case idle
    case sending
    case failed(String)
}

enum HermesSessionListState: Equatable, Sendable {
    case idle
    case loading
    case loaded([HermesSessionListItem])
    case failed(String)

    var sessions: [HermesSessionListItem] {
        if case .loaded(let sessions) = self {
            return sessions
        }
        return []
    }
}

enum HermesModelListState: Equatable, Sendable {
    case idle
    case loading
    case loaded([HermesConfiguredModel])
    case failed(String)
}

enum HermesToolListState: Equatable, Sendable {
    case idle
    case loading
    case loaded([HermesInstalledTool])
    case failed(String)
}

enum DeckDelegationToolInstallState: Equatable, Sendable {
    case idle
    case installing
    case installed
    case failed(String)
}

enum DeckDelegationToolStatus: Equatable, Sendable {
    case missing
    case current(version: String)
    case outdated(installedVersion: String?, bundledVersion: String)
}

enum HermesSkillListState: Equatable, Sendable {
    case idle
    case loading
    case loaded([HermesInstalledSkill])
    case failed(String)
}

enum HermesJobListState: Equatable, Sendable {
    case idle
    case loading
    case loaded([HermesScheduledJob])
    case failed(String)
}

struct HermesScheduledJob: Identifiable, Hashable, Decodable, Sendable {
    var id: String
    var name: String
    var schedule: String
    var state: String
    var enabled: Bool
    var nextRunAt: String?
    var lastRunAt: String?
    var lastStatus: String?
    var lastError: String?
    var deliver: String?
    var skills: [String]
    var script: String?
    var profile: String?
    var prompt: String?

    var statusText: String {
        if !enabled { return "paused" }
        return state.isEmpty ? "active" : state
    }
}
