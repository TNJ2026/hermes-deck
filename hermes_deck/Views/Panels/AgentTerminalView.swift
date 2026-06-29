import SwiftUI
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.processDelegate = context.coordinator
        startProcess(in: terminal)
        // Hand the terminal focus once it is in a window so typing goes to the
        // child without an extra click.
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    private func startProcess(in terminal: LocalProcessTerminalView) {
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
