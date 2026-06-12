import Foundation
import UniformTypeIdentifiers

enum MessageRole: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
    case system
}

struct Attachment: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var url: URL
    var contentType: String

    init(id: UUID = UUID(), name: String, url: URL, contentType: String = UTType.data.identifier) {
        self.id = id
        self.name = name
        self.url = url
        self.contentType = contentType
    }
}

struct ThinkingSegment: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var text: String
    /// When the first reasoning delta for this segment arrived. Drives the live
    /// "thinking…" timer; `nil` for history segments with no timing.
    var startedAt: Date?
    /// Frozen think duration once reasoning ended (the next output/tool segment
    /// began). `nil` while still thinking or when timing is unavailable.
    var durationSeconds: Double?

    init(id: UUID = UUID(), text: String = "", startedAt: Date? = nil, durationSeconds: Double? = nil) {
        self.id = id
        self.text = text
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
    }
}

enum AssistantSegment: Identifiable, Hashable, Codable, Sendable {
    case thinking(ThinkingSegment)
    case tool(ToolCallEvent)
    case clarify(ClarificationRequest)

    var id: UUID {
        switch self {
        case .thinking(let segment): segment.id
        case .tool(let event): event.id
        case .clarify(let clarification): clarification.id
        }
    }
}

struct ChatMessage: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var role: MessageRole
    var content: String
    var createdAt: Date
    var completedAt: Date?
    var attachments: [Attachment]
    var segments: [AssistantSegment]
    var reasoningText: String
    var routedSourceProfileName: String?
    /// Set when this assistant message is an `@mention` reply echoed back into a
    /// source thread: the routed agent's display name. Drives the attribution
    /// pill explicitly, so ordinary `Label:\n\nbody` content is never misread as
    /// an agent reply.
    var agentReplyName: String?
    /// Set only for internally generated close-the-loop follow-ups such as
    /// `X replied:\n\n...`, fed back to a source agent after it routed work to
    /// another agent. This keeps ordinary user-authored prose from being styled
    /// as a routing receipt just because it matches that text shape.
    var isAgentReplyFollowUp: Bool?
    /// True for messages reconstructed from a stored session. The store has no
    /// real generation duration for these, so the timer is suppressed instead
    /// of showing a meaningless 0s.
    var isHistorical: Bool

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        createdAt: Date = .now,
        completedAt: Date? = nil,
        attachments: [Attachment] = [],
        segments: [AssistantSegment] = [],
        reasoningText: String = "",
        routedSourceProfileName: String? = nil,
        agentReplyName: String? = nil,
        isAgentReplyFollowUp: Bool? = nil,
        isHistorical: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.attachments = attachments
        self.segments = segments
        self.reasoningText = reasoningText
        self.routedSourceProfileName = routedSourceProfileName
        self.agentReplyName = agentReplyName
        self.isAgentReplyFollowUp = isAgentReplyFollowUp
        self.isHistorical = isHistorical
    }

    var toolEvents: [ToolCallEvent] {
        segments.compactMap {
            if case .tool(let event) = $0 { event } else { nil }
        }
    }

    var clarifications: [ClarificationRequest] {
        segments.compactMap {
            if case .clarify(let clarification) = $0 { clarification } else { nil }
        }
    }

    var thinkingSegments: [ThinkingSegment] {
        segments.compactMap {
            if case .thinking(let segment) = $0 { segment } else { nil }
        }
    }

    var thinkingText: String {
        thinkingSegments.map(\.text).joined(separator: "\n\n")
    }
}

struct ClarificationRequest: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var question: String
    var choices: [String]

    init(id: UUID = UUID(), question: String, choices: [String] = []) {
        self.id = id
        self.question = question
        self.choices = choices
    }
}

enum ToolCallState: String, Codable, Sendable {
    case running
    case complete
    case generating
}

struct ToolCallEvent: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var toolID: String?
    var name: String
    var state: ToolCallState
    var context: String?
    var summary: String?
    var durationSeconds: Double?

    init(
        id: UUID = UUID(),
        toolID: String? = nil,
        name: String,
        state: ToolCallState,
        context: String? = nil,
        summary: String? = nil,
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.toolID = toolID
        self.name = name
        self.state = state
        self.context = context
        self.summary = summary
        self.durationSeconds = durationSeconds
    }

    mutating func merge(with event: ToolCallEvent) {
        toolID = event.toolID ?? toolID
        if !event.name.isEmpty && event.name != "tool" { name = event.name }
        state = event.state
        context = event.context ?? context
        summary = event.summary ?? summary
        durationSeconds = event.durationSeconds ?? durationSeconds
    }
}

struct ChatThread: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var title: String
    var profile: HermesProfile
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
    /// The Hermes gateway session id this thread was loaded from (e.g.
    /// `20260608_161655_fc58d6`), if it came from history. Lets the next prompt
    /// resume that session instead of spawning a new one. `nil` for fresh chats.
    var hermesSessionID: String?

    init(
        id: UUID = UUID(),
        title: String,
        profile: HermesProfile = .defaultProfile,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        messages: [ChatMessage] = [],
        hermesSessionID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.profile = profile
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.hermesSessionID = hermesSessionID
    }
}

struct PermissionOption: Identifiable, Hashable, Sendable {
    /// Identifier sent back to the agent. ACP uses `optionId`; Hermes gateway
    /// uses approval choices like `once`, `session`, `always`, or `deny`.
    var id: String
    var label: String
}

struct PermissionRequest: Identifiable, Hashable, Sendable {
    let id: UUID
    var message: String
    var options: [PermissionOption]
    /// Token used to route the answer back to the agent.
    var requestID: String?
    var createdAt: Date

    init(id: UUID = UUID(), message: String, options: [PermissionOption] = [], requestID: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.message = message
        self.options = options
        self.requestID = requestID
        self.createdAt = createdAt
    }

    /// Display labels, kept for the existing banner UI.
    var choices: [String] { options.map(\.label) }

    /// `true` when the UI can route an answer back to the agent.
    var isAnswerable: Bool { requestID != nil }

    var cancelOptionID: String {
        requestID?.hasPrefix("hermes:") == true ? "deny" : ""
    }
}

struct AgentRouteRequest: Equatable, Sendable {
    var profile: HermesProfile
    var threadID: UUID
    var sourceThreadID: UUID?
}

struct AgentMentionRoute: Equatable, Sendable {
    var profile: HermesProfile
    var message: String
}

/// A non-Hermes agent (Codex ACP, Claude CLI, Gemini/Antigravity) that the main
/// chat can forward a prompt to via an `@alias` mention.
struct ExternalAgentMentionTarget: Equatable, Sendable {
    var aliases: [String]
    var profile: HermesProfile
    var backend: AgentBackend
}

struct AgentRouteTarget: Equatable, Sendable {
    var profile: HermesProfile
    var backend: AgentBackend
}

enum ExternalAgentReplySource: Equatable, Sendable {
    case claude
    case codex
    case gemini

    static func parse(displayName: String) -> ExternalAgentReplySource? {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "claude" || normalized == "claude code" {
            return .claude
        }
        if normalized == "codex" {
            return .codex
        }
        if normalized == "gemini" || normalized == "gemini (antigravity)" {
            return .gemini
        }
        return nil
    }
}

struct ExternalAgentReplyAttribution: Equatable, Sendable {
    /// `nil` for a Hermes profile reply (no fixed brand color); set for the known
    /// external agents (claude / codex / gemini).
    var source: ExternalAgentReplySource?
    var displayName: String
    var body: String

    /// Parses an external agent reply whose content embeds a known brand label
    /// (`Claude Code:\n\nbody`). Only the known external agents are recognized,
    /// so ordinary assistant prose that merely contains `Word:\n\n…` is never
    /// misread. Hermes-profile echoes carry their name out-of-band via
    /// `ChatMessage.agentReplyName` instead of going through this path.
    static func parse(_ content: String) -> ExternalAgentReplyAttribution? {
        let separator = ":\n\n"
        guard let separatorRange = content.range(of: separator) else { return nil }
        let displayName = String(content[..<separatorRange.lowerBound])
        guard let source = ExternalAgentReplySource.parse(displayName: displayName) else { return nil }
        let body = String(content[separatorRange.upperBound...])
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ExternalAgentReplyAttribution(source: source, displayName: displayName, body: body)
    }
}

enum PromptRouteSource: Equatable, Sendable {
    case hermes(profile: HermesProfile)
    case external(backend: AgentBackend, displayName: String)

    var displayName: String {
        switch self {
        case .hermes(let profile):
            profile.displayName
        case .external(_, let displayName):
            displayName
        }
    }
}

enum PromptRouteDenialReason: Equatable, Sendable {
    case externalSourceCannotRoute
}

enum PromptRouteResult: Equatable, Sendable {
    case routed
    case notMention
    case denied(PromptRouteDenialReason)
}

enum AgentMentionRouteParser {
    static func parse(_ text: String, profiles: [HermesProfile]) -> AgentMentionRoute? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let sortedProfiles = profiles.sorted {
            max($0.id.count, $0.displayName.count) > max($1.id.count, $1.displayName.count)
        }

        for profile in sortedProfiles {
            let aliases = [profile.id, profile.displayName]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            for alias in aliases {
                let mention = "@\(alias)"
                guard let range = trimmed.range(of: mention, options: [.caseInsensitive, .diacriticInsensitive]) else {
                    continue
                }
                guard isMentionBoundary(in: trimmed, lowerBound: range.lowerBound, upperBound: range.upperBound) else {
                    continue
                }

                let routedMessage = (trimmed[..<range.lowerBound] + trimmed[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !routedMessage.isEmpty else { return nil }
                return AgentMentionRoute(profile: profile, message: String(routedMessage))
            }
        }

        return nil
    }

    private static func isMentionBoundary(in text: String, lowerBound: String.Index, upperBound: String.Index) -> Bool {
        let validBefore = lowerBound == text.startIndex || !isMentionNameCharacter(text[text.index(before: lowerBound)])
        let validAfter = upperBound == text.endIndex || !isMentionNameCharacter(text[upperBound])
        return validBefore && validAfter
    }

    private static func isMentionNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
    }
}

enum ComposerMention {
    /// The mention being typed at the end of `text`: the last `@token` whose
    /// `@` sits at a word boundary (start-of-string or preceded by whitespace)
    /// and whose token contains no whitespace. Returns the range covering
    /// `@`…end (for replacement) and the lowercased query after `@`. Nil once a
    /// space is typed, which dismisses the autocomplete popup.
    static func activeQuery(in text: String) -> (range: Range<String.Index>, query: String)? {
        guard let atIndex = text.lastIndex(of: "@") else { return nil }

        if atIndex != text.startIndex {
            let before = text[text.index(before: atIndex)]
            guard before.isWhitespace else { return nil }
        }

        let queryStart = text.index(after: atIndex)
        let query = text[queryStart...]
        guard !query.contains(where: { $0.isWhitespace }) else { return nil }

        return (atIndex..<text.endIndex, query.lowercased())
    }
}

/// A Hermes gateway slash command surfaced in the composer's `/` popup.
struct SlashCommand: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String      // without the leading slash, e.g. "new"
    let subtitle: String
}

enum ComposerSlash {
    /// The slash command being typed: only when `text` begins with `/` and the
    /// token after it has no whitespace. Returns the range covering the whole
    /// text (for replacement) and the lowercased query. Nil once args are typed.
    static func activeQuery(in text: String) -> (range: Range<String.Index>, query: String)? {
        guard text.first == "/" else { return nil }
        let afterSlash = text.index(after: text.startIndex)
        let rest = text[afterSlash...]
        guard !rest.contains(where: { $0.isWhitespace }) else { return nil }
        return (text.startIndex..<text.endIndex, rest.lowercased())
    }
}

extension AgentMentionRouteParser {
    /// Strips a leading/embedded `@alias` mention and returns the remaining
    /// prompt, matching any of `aliases` (longest first). Shares the boundary
    /// rules used for profile mentions.
    static func routedMessage(in text: String, aliases: [String]) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let sorted = aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }

        for alias in sorted {
            let mention = "@\(alias)"
            guard let range = trimmed.range(of: mention, options: [.caseInsensitive, .diacriticInsensitive]) else {
                continue
            }
            guard isMentionBoundary(in: trimmed, lowerBound: range.lowerBound, upperBound: range.upperBound) else {
                continue
            }
            let routed = (trimmed[..<range.lowerBound] + trimmed[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !routed.isEmpty else { return nil }
            return String(routed)
        }
        return nil
    }

    /// Every `@alias` mention in `text` (across `aliasGroups`), each paired with
    /// the prompt segment that follows it — up to the next mention or the end.
    /// Lets one composed message fan out to multiple @-mentioned agents, each
    /// getting only the text after its own mention.
    static func routeSpans(
        in text: String,
        aliasGroups: [[String]]
    ) -> [(groupIndex: Int, message: String)] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let candidates = mentionCandidates(for: aliasGroups)
        var mentions: [(group: Int, range: Range<String.Index>)] = []
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            if trimmed[index] == "@",
               let match = matchMention(in: trimmed, at: index, candidates: candidates) {
                mentions.append((match.group, index..<match.end))
                index = match.end
            } else {
                index = trimmed.index(after: index)
            }
        }

        return mentions.enumerated().map { offset, mention in
            let stop = offset + 1 < mentions.count ? mentions[offset + 1].range.lowerBound : trimmed.endIndex
            let message = trimmed[mention.range.upperBound..<stop]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (mention.group, message)
        }
    }

    /// The fence info string that marks a routing block in an agent reply.
    static let routingFenceInfo = "AgentRouting"

    /// Agent-reply routing: a mention routes only when it sits in its own
    /// ```AgentRouting fenced block whose content *starts* with `@alias`; the
    /// rest of the block is the routed message. One block addresses one target
    /// — a block holding any further known mention is rejected, and mentions
    /// in prose, plain code blocks, or mid-block never route. Each qualifying
    /// block yields one route, so a reply with several blocks still fans out.
    static func codeBlockRouteSpans(
        in text: String,
        aliasGroups: [[String]]
    ) -> [(groupIndex: Int, message: String)] {
        let candidates = mentionCandidates(for: aliasGroups)
        return fencedCodeBlockContents(in: text).compactMap { block in
            guard block.info.caseInsensitiveCompare(routingFenceInfo) == .orderedSame else { return nil }
            let content = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard content.first == "@",
                  let match = matchMention(in: content, at: content.startIndex, candidates: candidates) else {
                return nil
            }
            let message = content[match.end...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty, !containsMention(message, candidates: candidates) else { return nil }
            return (match.group, message)
        }
    }

    /// (groupIndex, alias) longest-first so "@claude code" beats "@claude";
    /// equal lengths break ties by group order (external groups precede hermes
    /// ones) — `sort` is not stable, so the tiebreak must be explicit.
    private static func mentionCandidates(for aliasGroups: [[String]]) -> [(group: Int, alias: String)] {
        var candidates: [(group: Int, alias: String)] = []
        for (groupIndex, aliases) in aliasGroups.enumerated() {
            for alias in aliases {
                let cleaned = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { candidates.append((groupIndex, cleaned)) }
            }
        }
        candidates.sort {
            $0.alias.count != $1.alias.count ? $0.alias.count > $1.alias.count : $0.group < $1.group
        }
        return candidates
    }

    private static func containsMention(_ text: String, candidates: [(group: Int, alias: String)]) -> Bool {
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "@", matchMention(in: text, at: index, candidates: candidates) != nil {
                return true
            }
            index = text.index(after: index)
        }
        return false
    }

    /// Every closed ``` fenced block with its info string (```AgentRouting →
    /// "AgentRouting"), in order. An unclosed trailing fence does not count.
    private static func fencedCodeBlockContents(in text: String) -> [(info: String, content: String)] {
        var blocks: [(info: String, content: String)] = []
        var currentLines: [Substring]?
        var currentInfo = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") {
                if let lines = currentLines {
                    blocks.append((currentInfo, lines.joined(separator: "\n")))
                    currentLines = nil
                } else {
                    currentLines = []
                    currentInfo = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            } else {
                currentLines?.append(line)
            }
        }
        return blocks
    }

    /// Matches `@<alias>` at `atIndex` (the `@`), honoring the mention boundary
    /// rules. Returns the matched group and the index just past the alias.
    private static func matchMention(
        in text: String,
        at atIndex: String.Index,
        candidates: [(group: Int, alias: String)]
    ) -> (group: Int, end: String.Index)? {
        let precededOK = atIndex == text.startIndex
            || !isMentionNameCharacter(text[text.index(before: atIndex)])
        guard precededOK else { return nil }
        let afterAt = text.index(after: atIndex)
        for candidate in candidates {
            guard let end = text.index(afterAt, offsetBy: candidate.alias.count, limitedBy: text.endIndex) else {
                continue
            }
            guard text[afterAt..<end].compare(candidate.alias, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else {
                continue
            }
            let followedOK = end == text.endIndex || !isMentionNameCharacter(text[end])
            guard followedOK else { continue }
            return (candidate.group, end)
        }
        return nil
    }
}

extension ChatMessage {
    static let sampleAssistant = ChatMessage(
        role: .assistant,
        content: """
        # Hermes

        Ask a question, attach local files, and switch profiles from the toolbar.

        | Feature | Status |
        | --- | --- |
        | Markdown | Native SwiftUI |
        | History search | Ready |
        | Profiles | Ready |
        """
    )
}
