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
struct AgentTerminalView: View {
    /// argv for the agent, e.g. `["claude"]` — run through `/usr/bin/env` so
    /// it resolves against the launch PATH.
    let command: [String]
    let workingDirectory: URL
    /// The terminal's base background (the view fill and the default cell
    /// color). Defaults to the app's surface color so the panel blends in.
    var backgroundColor: NSColor = .textBackgroundColor
    /// Monospaced font for the grid; defaults to the system monospaced face at
    /// the standard text size so it matches the rest of the app.
    var font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    /// Bumping this recreates the terminal host, relaunching the process —
    /// used by the restart affordance after the agent exits.
    @State private var runID = UUID()
    /// Non-nil once the child process has exited; drives the restart banner.
    @State private var processExit: ProcessExit?
    /// The agent's reported working directory (OSC 7), shown when it diverges
    /// from the launch directory. Most agents never emit it, so it stays hidden.
    @State private var reportedDirectory: String?

    var body: some View {
        TerminalHost(
            command: command,
            workingDirectory: workingDirectory,
            backgroundColor: backgroundColor,
            font: font,
            onExit: { code in
                withAnimation(.snappy) { processExit = ProcessExit(code: code) }
            },
            onWorkingDirectoryChange: { dir in
                reportedDirectory = (dir == workingDirectory.path) ? nil : dir
            }
        )
        .id(runID)
        .overlay(alignment: .top) { directoryFooter }
        .overlay(alignment: .bottom) { exitBanner }
    }

    @ViewBuilder
    private var directoryFooter: some View {
        if let reportedDirectory {
            Text(reportedDirectory)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
                .overlay(alignment: .bottom) { Divider() }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var exitBanner: some View {
        if let processExit {
            HStack(spacing: 12) {
                Image(systemName: "stop.circle")
                    .foregroundStyle(.secondary)
                Text(processExit.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Restart", action: restart)
                    .keyboardShortcut(.return, modifiers: [])
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Divider() }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func restart() {
        withAnimation(.snappy) {
            processExit = nil
            reportedDirectory = nil
        }
        // A fresh id tears down the dead host and builds a new one, relaunching
        // the agent in the same working directory.
        runID = UUID()
    }

    struct ProcessExit: Equatable {
        let code: Int32?
        var message: String {
            guard let code else { return "Process ended unexpectedly." }
            return code == 0 ? "Process exited." : "Process exited (code \(code))."
        }
    }
}

/// Bridges SwiftTerm's `LocalProcessTerminalView` into SwiftUI: launches the
/// agent, reports exit/cwd back through callbacks, and terminates the child on
/// teardown.
private struct TerminalHost: NSViewRepresentable {
    let command: [String]
    let workingDirectory: URL
    var backgroundColor: NSColor
    var font: NSFont
    var onExit: (Int32?) -> Void
    var onWorkingDirectoryChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onExit: onExit, onCwd: onWorkingDirectoryChange)
    }

    func makeNSView(context: Context) -> ThemedTerminalView {
        let terminal = ThemedTerminalView(frame: .zero)
        terminal.processDelegate = context.coordinator
        terminal.themedBackgroundColor = backgroundColor
        terminal.font = font
        startProcess(in: terminal)
        return terminal
    }

    func updateNSView(_ nsView: ThemedTerminalView, context: Context) {
        // Keep the callbacks fresh (they capture per-render closures).
        context.coordinator.onExit = onExit
        context.coordinator.onCwd = onWorkingDirectoryChange
        nsView.themedBackgroundColor = backgroundColor
        if nsView.font != font { nsView.font = font }
    }

    /// SwiftTerm's `LocalProcess.deinit` only cancels its exit monitor; it
    /// neither signals the child nor closes the PTY. Without this the agent
    /// keeps running on every panel switch/collapse or `.id` rebuild,
    /// orphaning a background codex/claude/agy. `terminate()` sends SIGTERM
    /// and closes the PTY.
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
        var onExit: (Int32?) -> Void
        var onCwd: (String) -> Void

        init(onExit: @escaping (Int32?) -> Void, onCwd: @escaping (String) -> Void) {
            self.onExit = onExit
            self.onCwd = onCwd
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            guard let directory else { return }
            DispatchQueue.main.async { self.onCwd(directory) }
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { self.onExit(exitCode) }
        }
    }
}

/// `LocalProcessTerminalView` resolves a dynamic `NSColor` to a fixed RGB the
/// moment it is assigned, so a semantic color like `.textBackgroundColor` would
/// otherwise freeze at whichever appearance was current at launch. Re-resolve
/// the background, foreground and caret against the view's live appearance
/// whenever the system toggles light/dark so the terminal tracks the app's
/// theme. The view also claims first-responder when it lands in a window so
/// keystrokes reach the agent without an extra click.
final class ThemedTerminalView: LocalProcessTerminalView {
    var themedBackgroundColor: NSColor = .textBackgroundColor {
        didSet { applyThemedColors() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemedColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    private func applyThemedColors() {
        // Assigning inside the current drawing appearance makes the dynamic
        // colors resolve to the right light/dark variant.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeBackgroundColor = themedBackgroundColor
            nativeForegroundColor = .textColor
            caretColor = .controlAccentColor
        }
        needsDisplay = true
    }
}
