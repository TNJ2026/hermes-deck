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
        [Hermes Deck agent routing]
        You are running inside Hermes Deck. When another available agent is a \
        better fit for a clearly separable subtask, delegate by emitting only a \
        fenced \(fence) block for that subtask:

        ```\(fence)
        @target
        Write the exact task for that agent here.
        Include all context it needs; the prompt may span multiple lines.
        ```

        Available targets: \(list).

        Routing rules:
        - The first non-whitespace content inside the block must be exactly one \
        available @target.
        - Everything after that target is forwarded verbatim as the target's \
        prompt.
        - Use one block per target. Several blocks fan out in parallel.
        - Do not put a second @target inside the same block.
        - Mentions in prose or in non-\(fence) code blocks do not route.
        - Target replies come back to you in a follow-up turn. Delegation is \
        single-hop, so routed agents cannot delegate again.

        Valid:
        ```\(fence)
        @\(targets[0])
        Inspect the parser failure and report the likely cause.
        ```

        Invalid:
        - `Please ask @\(targets[0]) ...` in prose
        - A block that starts with anything before the @target
        - One block containing more than one available @target

        If no target is clearly useful, answer normally without a routing block.
        """
    }
}
