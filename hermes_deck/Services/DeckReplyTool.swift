import Foundation

/// Ships the `deck-reply` command that the interactive CLI panels
/// (claude / codex / gemini) call to return a delegated result to the agent
/// that requested it. All three CLIs can run a shell command, so a small script
/// on their PATH is the one mechanism that works uniformly — no per-CLI MCP
/// wiring. The script talks to `DeckRoutingIPCServer` over the same local socket
/// the gateway delegation tool uses, identifying its panel via
/// `HERMES_DECK_PANEL_SESSION`.
enum DeckReplyTool {
    static let scriptName = "deck-reply"

    /// Deck-managed bin directory, prepended to the agent launch PATH.
    static var binDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("HermesDeck/bin", isDirectory: true)
    }

    static var scriptURL: URL { binDirectory.appendingPathComponent(scriptName) }

    /// Writes the script and marks it executable. Idempotent and overwriting, so
    /// the shipped version always wins.
    static func install() {
        try? FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            // Best effort: if the script can't be written, deck-reply is simply
            // unavailable and the agent falls back to plain output.
        }
    }

    // bash (not python) so it runs without a Python install, which macOS no
    // longer ships; the message is base64-encoded to avoid JSON-escaping
    // arbitrary multiline content in shell.
    private static let script = #"""
    #!/bin/bash
    # Hermes Deck: return a delegated agent's result to the requesting agent.
    # Usage:  deck-reply <<'EOF'
    #         <your result>
    #         EOF
    set -uo pipefail
    if [ -z "${HERMES_DECK_ROUTE_TOKEN:-}" ] || [ -z "${HERMES_DECK_ROUTE_HOST:-}" ] || [ -z "${HERMES_DECK_ROUTE_PORT:-}" ]; then
      echo "deck-reply: Hermes Deck routing IPC is not available." >&2
      exit 1
    fi
    msg=$(cat | base64 | tr -d '\n')
    payload="{\"token\":\"${HERMES_DECK_ROUTE_TOKEN}\",\"type\":\"reply\",\"session\":\"${HERMES_DECK_PANEL_SESSION:-}\",\"message_b64\":\"${msg}\"}"
    if ! exec 3<>"/dev/tcp/${HERMES_DECK_ROUTE_HOST}/${HERMES_DECK_ROUTE_PORT}"; then
      echo "deck-reply: could not connect to Hermes Deck." >&2
      exit 1
    fi
    printf '%s\n' "$payload" >&3
    IFS= read -r response <&3 || true
    exec 3>&- 3<&-
    echo "${response:-}"
    """#
}

/// Prefixes a delegated prompt with the convention for returning a result, so
/// the panel CLI knows to call `deck-reply` when it finishes.
enum DeckReplyPrimer {
    static func wrap(_ prompt: String) -> String {
        """
        [Hermes Deck] A teammate delegated this task to you. When you have the \
        final result, return it to them by running this command, with the result \
        on stdin:

          deck-reply <<'DECK_EOF'
          <your result here>
          DECK_EOF

        You may stop after that. Task:

        \(prompt)
        """
    }
}
