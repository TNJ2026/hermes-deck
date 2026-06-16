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
        let list = targets.map { "@\($0)" }.joined(separator: ", ")
        let targetDescriptions = targets.map { "- @\($0): \(description(for: $0))" }.joined(separator: "\n")
        return """
        [Hermes Deck capability: delegate_to_agent]
        You have a built-in delegation capability. When a clearly separable \
        subtask is better handled by another available agent, delegate it with \
        AgentRouting instead of doing everything yourself.

        Available delegation targets:
        \(targetDescriptions)

        To delegate, emit only a fenced AgentRouting block for that subtask:

        ```AgentRouting
        @\(targets[0])
        Write the exact task for that agent here.
        Include all context it needs; the prompt may span multiple lines.
        ```

        Target aliases: \(list).

        Routing rules:
        - The first non-whitespace content inside the block must be exactly one \
        available target alias from the list above.
        - Everything after that target is forwarded verbatim as the target's \
        prompt.
        - Use one block per target. Several blocks fan out in parallel.
        - Do not put a second target alias inside the same block.
        - Treat the block as an action request, not as a Markdown example to \
        display.
        - The AgentRouting block is the complete output for that subtask; do \
        not wrap it inside another code block or quote block.
        - Do not place a plain ``` fence before or after the AgentRouting \
        fence.
        - Mentions in prose or in non-AgentRouting code blocks do not route.
        - Target replies come back to you in a follow-up turn. Delegation is \
        single-hop, so routed agents cannot delegate again.

        Valid:
        ```AgentRouting
        @\(targets[0])
        Inspect the parser failure and report the likely cause.
        ```

        Invalid:
        - `Please ask @\(targets[0]) ...` in prose
        - A block that starts with anything before the target alias
        - One block containing more than one available target alias
        - A nested code block that contains an AgentRouting block inside it

        If no target is clearly useful, answer normally without a routing block.
        """
    }

    private static func description(for target: String) -> String {
        let normalized = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "codex":
            return "repository work, implementation, debugging, tests, and terminal-based verification"
        case "claude", "claude-code", "claudecode":
            return "codebase analysis, refactors, debugging, and implementation review"
        case "gemini", "antigravity", "agy":
            return "broad analysis, alternate implementation ideas, and cross-checking"
        case let value where value.contains("coding") || value.contains("code"):
            return "code changes, debugging, tests, refactors, and implementation details"
        case let value where value.contains("research"):
            return "investigation, comparison, summarization, and documentation-oriented tasks"
        case let value where value.contains("review"):
            return "reviewing plans, code, diffs, risks, and missing tests"
        default:
            return "a Hermes profile agent; use when its name or specialty fits the subtask"
        }
    }
}
