import SwiftUI
import AppKit
import SwiftTerm

/// Embeds an interactive agent CLI (claude / codex / agy) in a panel using a
/// real terminal emulator. `LocalProcessTerminalView` owns the PTY, parses the
/// full VT/xterm stream (alt-screen, cursor moves, colors) and routes keyboard,
/// scroll and resize straight to the child — everything a TUI needs that an
/// append-to-`Text` view cannot do.
///
/// The panel recreates this view (via `.id(workingDirectory)`) when the cwd
/// changes, which relaunches the process in the new directory.
struct AgentTerminalView: NSViewRepresentable {
    /// argv for the agent, e.g. `["claude"]` — run through `/usr/bin/env` so
    /// it resolves against the launch PATH.
    let command: [String]
    let workingDirectory: URL
    /// The terminal's base background (the view fill and the default cell
    /// color). Defaults to the app's surface color so the panel blends in;
    /// cells the agent paints with explicit colors keep those.
    var backgroundColor: NSColor = .textBackgroundColor

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ThemedTerminalView {
        let terminal = ThemedTerminalView(frame: .zero)
        terminal.processDelegate = context.coordinator
        terminal.themedBackgroundColor = backgroundColor
        startProcess(in: terminal)
        // Hand the terminal focus once it is in a window so typing goes to the
        // child without an extra click.
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
        return terminal
    }

    func updateNSView(_ nsView: ThemedTerminalView, context: Context) {
        nsView.themedBackgroundColor = backgroundColor
    }

    /// SwiftTerm's `LocalProcess.deinit` only cancels its exit monitor — it
    /// neither closes the PTY nor signals the child. Without this the agent
    /// keeps running every time the view is torn down (panel switch/collapse,
    /// or the `.id(workingDirectory)` rebuild on a cwd change), orphaning a
    /// background codex/claude/agy. `terminate()` sends SIGTERM and closes the
    /// PTY.
    static func dismantleNSView(_ nsView: ThemedTerminalView, coordinator: Coordinator) {
        nsView.terminate()
    }

    private func startProcess(in terminal: ThemedTerminalView) {
        // SwiftTerm replaces the child environment with whatever is passed, so
        // start from the agent launch environment (carries the right PATH) and
        // layer on the terminal hints it would otherwise have supplied.
        var environment = AgentLaunchEnvironment.make()
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["LANG"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        let environmentList = environment.map { "\($0.key)=\($0.value)" }

        terminal.startProcess(
            executable: "/usr/bin/env",
            args: command,
            environment: environmentList,
            currentDirectory: workingDirectory.path
        )
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}

/// `LocalProcessTerminalView` resolves a dynamic `NSColor` to a fixed RGB the
/// moment it is assigned, so a semantic color like `.textBackgroundColor` would
/// otherwise freeze at whichever appearance was current at launch. Re-resolve
/// the background (and the matching default text color) against the view's live
/// appearance whenever the system toggles light/dark so the terminal tracks the
/// app's theme.
final class ThemedTerminalView: LocalProcessTerminalView {
    var themedBackgroundColor: NSColor = .textBackgroundColor {
        didSet { applyThemedColors() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemedColors()
    }

    private func applyThemedColors() {
        // Assigning inside the current drawing appearance makes the dynamic
        // colors resolve to the right light/dark variant.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeBackgroundColor = themedBackgroundColor
            nativeForegroundColor = .textColor
        }
        needsDisplay = true
    }
}
