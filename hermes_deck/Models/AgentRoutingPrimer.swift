import Foundation

/// The routing primer seeded as a system-role message when the Deck creates a
/// gateway session, so every agent knows — without installing a skill — that it
/// can delegate via ```AgentRouting blocks, and which targets exist right now.
///
/// Kept in the same module as `AgentMentionRouteParser` on purpose: the format
/// described here and the parser that recognizes it must change in the same
/// commit.
enum AgentRoutingPrimer {
    /// `targets` are mention aliases without the `@` (e.g. "coding", "codex"),
    /// already filtered to exclude the session's own profile.
    static func text(targets: [String]) -> String? {
        guard !targets.isEmpty else { return nil }
        let fence = AgentMentionRouteParser.routingFenceInfo
        let list = targets.map { "@\($0)" }.joined(separator: ", ")
        return """
        [Hermes Deck routing]
        You are running inside Hermes Deck. You can delegate part of a task to \
        another agent by replying with a fenced code block:

        ```\(fence)
        @<target> <prompt>
        ```

        Available targets: \(list).
        The block's content must start with the @target; the rest of the block \
        is the prompt forwarded to that agent. One block addresses one target; \
        several blocks fan out in parallel. The target's reply is fed back to \
        you as a follow-up turn. Delegated agents cannot re-delegate (single \
        hop). Mentions in prose or in other code blocks never route. Delegate \
        only when the task clearly matches another agent's specialty or the \
        user asks for it; otherwise answer yourself.
        """
    }
}
