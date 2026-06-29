import SwiftUI
import AppKit
import Combine
import SwiftTerm

/// Embeds an interactive agent CLI (claude / codex / agy) in a panel using a
/// real terminal emulator whose process lifetime is tied to the **app**, not to
/// this view. Showing, hiding, or switching the right-hand panels detaches and
/// reattaches the same terminal — the agent keeps running. The process is only
/// terminated when its working directory changes (an explicit relaunch), when
/// the user restarts it after it exits, or when the app quits.
struct AgentTerminalView: View {
    /// Stable per-panel identity (the panel's thread id); the session key.
    let sessionID: UUID
    /// argv for the agent, e.g. `["claude"]` — run through `/usr/bin/env` so it
    /// resolves against the launch PATH.
    let command: [String]
    let workingDirectory: URL
    /// The terminal's base background (the view fill and the default cell
    /// color). Defaults to the app's surface color so the panel blends in.
    var backgroundColor: NSColor = .textBackgroundColor
    /// Monospaced font for the grid; defaults to the system monospaced face at
    /// the standard text size so it matches the rest of the app.
    var font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    @State private var session: TerminalSession?

    var body: some View {
        Group {
            if let session {
                AgentTerminalContent(session: session, backgroundColor: backgroundColor, font: font)
            } else {
                Color(nsColor: backgroundColor)
            }
        }
        // Resolve the session in a task, not in `body`: the store's
        // get-or-launch may relaunch on a directory change, which must not run
        // inside the view-update pass. Re-runs when the directory changes.
        .task(id: workingDirectory) {
            session = AgentTerminalSessionStore.shared.session(
                id: sessionID,
                command: command,
                workingDirectory: workingDirectory,
                backgroundColor: backgroundColor,
                font: font
            )
        }
    }
}

private struct AgentTerminalContent: View {
    @ObservedObject var session: TerminalSession
    let backgroundColor: NSColor
    let font: NSFont

    var body: some View {
        TerminalSurface(view: session.view, backgroundColor: backgroundColor, font: font)
            // A relaunch swaps in a fresh terminal view; the changing generation
            // makes SwiftUI re-vend it.
            .id(session.generation)
            .overlay(alignment: .top) { directoryFooter }
            .overlay(alignment: .bottom) { exitBanner }
    }

    @ViewBuilder
    private var directoryFooter: some View {
        if let dir = session.reportedDirectory {
            Text(dir)
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
        if let exit = session.exit {
            HStack(spacing: 12) {
                Image(systemName: "stop.circle")
                    .foregroundStyle(.secondary)
                Text(exit.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Restart") {
                    withAnimation(.snappy) { session.relaunch() }
                }
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
}

/// Vends a persistent, externally-owned terminal view into SwiftUI without
/// taking ownership: it never launches or terminates the process. The owning
/// `TerminalSession` (held by `AgentTerminalSessionStore`) outlives mount and
/// unmount, so hiding and reshowing the panel keeps the agent running. There is
/// deliberately no `dismantleNSView` — teardown must not terminate.
private struct TerminalSurface: NSViewRepresentable {
    let view: ThemedTerminalView
    let backgroundColor: NSColor
    let font: NSFont

    func makeNSView(context: Context) -> ThemedTerminalView {
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: ThemedTerminalView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to terminal: ThemedTerminalView) {
        terminal.themedBackgroundColor = backgroundColor
        if terminal.font != font { terminal.font = font }
    }
}

/// Owns one agent terminal for the lifetime of the app: the running process,
/// its view, and the exit / working-directory state the panel observes. Held by
/// `AgentTerminalSessionStore` so it survives the panel being hidden or
/// switched away.
final class TerminalSession: ObservableObject {
    let id: UUID
    let command: [String]
    private(set) var workingDirectory: URL
    private let backgroundColor: NSColor
    private let font: NSFont

    /// The live terminal view. Replaced (and the old one terminated) on a
    /// relaunch; `generation` then tells the surface to re-vend it.
    @Published private(set) var view: ThemedTerminalView
    /// Non-nil once the child process has exited; drives the restart banner.
    @Published var exit: ProcessExit?
    /// The agent's reported working directory (OSC 7), shown when it diverges
    /// from the launch directory. Most agents never emit it, so it stays hidden.
    @Published var reportedDirectory: String?
    @Published private(set) var generation = 0

    private let delegate = SessionDelegate()
    /// Prompts routed in before the freshly-launched CLI is ready to accept
    /// input; flushed once its boot output settles so nothing is typed into a
    /// half-drawn TUI and lost.
    private var pendingPrompts: [String] = []
    private var isReadyForInput = false
    private var readinessSettle: DispatchWorkItem?
    private var readinessDeadline: DispatchWorkItem?

    init(id: UUID, command: [String], workingDirectory: URL, backgroundColor: NSColor, font: NSFont) {
        self.id = id
        self.command = command
        self.workingDirectory = workingDirectory
        self.backgroundColor = backgroundColor
        self.font = font
        self.view = ThemedTerminalView(frame: .zero)
        delegate.owner = self
        launch()
    }

    private func launch() {
        isReadyForInput = false
        pendingPrompts.removeAll()
        readinessSettle?.cancel(); readinessSettle = nil
        readinessDeadline?.cancel(); readinessDeadline = nil

        view.processDelegate = delegate
        view.onOutput = { [weak self] in
            DispatchQueue.main.async { self?.noteOutput() }
        }
        view.themedBackgroundColor = backgroundColor
        view.font = font

        // SwiftTerm replaces the child environment with whatever is passed, so
        // start from the agent launch environment (carries the right PATH) and
        // layer on the terminal hints it would otherwise have supplied.
        var environment = AgentLaunchEnvironment.make()
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["LANG"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        view.startProcess(
            executable: "/usr/bin/env",
            args: command,
            environment: environment.map { "\($0.key)=\($0.value)" },
            currentDirectory: workingDirectory.path
        )

        // Fallback: flush queued prompts even if a chatty TUI never goes quiet.
        let deadline = DispatchWorkItem { [weak self] in self?.markReadyForInput() }
        readinessDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: deadline)
    }

    /// Each burst of child output resets a short settle timer; when the boot
    /// output quiesces the input box is up, so queued prompts can be sent.
    private func noteOutput() {
        guard !isReadyForInput else { return }
        readinessSettle?.cancel()
        let settle = DispatchWorkItem { [weak self] in self?.markReadyForInput() }
        readinessSettle = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: settle)
    }

    private func markReadyForInput() {
        guard !isReadyForInput else { return }
        isReadyForInput = true
        readinessSettle?.cancel(); readinessSettle = nil
        readinessDeadline?.cancel(); readinessDeadline = nil
        let queued = pendingPrompts
        pendingPrompts.removeAll()
        queued.forEach(write)
    }

    /// Terminates the current process and starts a fresh one — used by the
    /// Restart affordance and on a working-directory change.
    func relaunch(workingDirectory newDirectory: URL? = nil) {
        view.terminate()
        if let newDirectory { workingDirectory = newDirectory }
        exit = nil
        reportedDirectory = nil
        view = ThemedTerminalView(frame: .zero)
        launch()
        generation += 1
    }

    func terminate() {
        view.terminate()
    }

    /// Injects a routed prompt into the interactive agent. Sent immediately once
    /// the CLI is accepting input, otherwise queued and flushed when its boot
    /// output settles — so a prompt routed into a just-launched (or hidden,
    /// not-yet-opened) panel isn't typed into a half-drawn TUI and dropped.
    func submitPrompt(_ prompt: String) -> Bool {
        guard exit == nil else { return false }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if isReadyForInput {
            write(text)
        } else {
            pendingPrompts.append(text)
        }
        return true
    }

    /// Writes one prompt to the PTY as a paste + submit, mirroring a user
    /// pasting text so multiline prompts stay together under bracketed paste.
    private func write(_ text: String) {
        if view.terminal.bracketedPasteMode {
            view.send(data: EscapeSequences.bracketedPasteStart[0...])
        }
        view.send(txt: text)
        if view.terminal.bracketedPasteMode {
            view.send(data: EscapeSequences.bracketedPasteEnd[0...])
        }
        view.send(txt: "\r")
    }

    fileprivate func handleExit(_ code: Int32?) {
        exit = ProcessExit(code: code)
    }

    fileprivate func handleCurrentDirectory(_ directory: String) {
        reportedDirectory = (directory == workingDirectory.path) ? nil : directory
    }

    struct ProcessExit: Equatable {
        let code: Int32?
        var message: String {
            guard let code else { return "Process ended unexpectedly." }
            return code == 0 ? "Process exited." : "Process exited (code \(code))."
        }
    }
}

/// SwiftTerm's delegate is delivered off the main actor, so this lightweight
/// `NSObject` receives the callbacks and hops back to the session on main.
private final class SessionDelegate: NSObject, LocalProcessTerminalViewDelegate {
    weak var owner: TerminalSession?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        DispatchQueue.main.async { [weak owner] in
            // Ignore a callback from a view the session already replaced on
            // relaunch — otherwise stale events clobber the new process's state.
            guard let owner, owner.view === source else { return }
            owner.handleCurrentDirectory(directory)
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak owner] in
            // A relaunch terminates the old view before swapping in the new one;
            // its late `processTerminated` must not mark the live session exited.
            guard let owner, owner.view === source else { return }
            owner.handleExit(exitCode)
        }
    }
}

/// Process-lifetime owner for the agent terminals: keyed by panel thread id and
/// held for the whole app run. Sessions are launched lazily on first request,
/// reused across panel show/hide/switch, relaunched when the working directory
/// changes, and all terminated when the app quits.
@MainActor
final class AgentTerminalSessionStore {
    static let shared = AgentTerminalSessionStore()

    private var sessions: [UUID: TerminalSession] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AgentTerminalSessionStore.shared.terminateAll()
            }
        }
    }

    func session(
        id: UUID,
        command: [String],
        workingDirectory: URL,
        backgroundColor: NSColor,
        font: NSFont
    ) -> TerminalSession {
        if let existing = sessions[id] {
            // An explicit directory change relaunches the agent there.
            if existing.workingDirectory.path != workingDirectory.path {
                existing.relaunch(workingDirectory: workingDirectory)
            }
            return existing
        }
        let session = TerminalSession(
            id: id,
            command: command,
            workingDirectory: workingDirectory,
            backgroundColor: backgroundColor,
            font: font
        )
        sessions[id] = session
        return session
    }

    func terminateAll() {
        sessions.values.forEach { $0.terminate() }
        sessions.removeAll()
    }

    func submitPrompt(
        _ prompt: String,
        id: UUID,
        command: [String],
        workingDirectory: URL,
        backgroundColor: NSColor = .textBackgroundColor,
        font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    ) -> Bool {
        session(
            id: id,
            command: command,
            workingDirectory: workingDirectory,
            backgroundColor: backgroundColor,
            font: font
        ).submitPrompt(prompt)
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
    /// Fired on every chunk of child output (off the main actor); the session
    /// uses it to tell when a freshly-launched CLI is ready for injected input.
    var onOutput: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
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
