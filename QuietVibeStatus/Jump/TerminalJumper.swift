import AppKit
import Foundation

/// Focuses the exact terminal tab, split, or IDE window a session is running in.
///
/// Strategy per host, best effort throughout: if the precise route fails we still activate the
/// app, which is far better than doing nothing.
enum TerminalJumper {
    static func jump(to session: Session) {
        let app = TerminalApp.resolve(from: session.terminal)

        // Never launch a terminal that isn't running. The captured environment can be stale — the
        // session may predate a quit, or the card may have outlived the app entirely — and booting
        // iTerm2 because a card once mentioned it is worse than doing nothing.
        guard app != .unknown, app.isRunning else {
            Log.jump.info("no terminal host for \(session.id); activating owner app")
            activateOwningApplication(of: session)
            return
        }

        Log.jump.info("jumping to \(app.displayName) for session \(session.id)")

        // A tmux pane has to be selected before focusing the window, or the window comes forward
        // showing whatever pane was last active.
        if let pane = session.terminal.tmuxPane {
            selectTmuxPane(pane, socket: session.terminal.tmux)
        }

        switch app {
        case .iTerm2:
            jumpToITerm(session)
        case .appleTerminal:
            jumpToTerminalApp(session)
        case .ghostty:
            jumpToGhostty(session)
        case .vscode, .cursor, .windsurf:
            jumpToVSCodeFamily(session, app: app)
        case .warp:
            // Warp exposes no scripting interface for tabs; activating lands on the last-used tab.
            activate(app)
        default:
            activate(app)
        }
    }

    // MARK: - Hosts

    private static func jumpToITerm(_ session: Session) {
        // ITERM_SESSION_ID looks like "w0t1p0:UUID"; the UUID is what iTerm's `id` matches.
        guard let raw = session.terminal.itermSessionID else {
            activate(.iTerm2)
            return
        }
        let uuid = raw.contains(":") ? String(raw.split(separator: ":").last ?? "") : raw

        let script = """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if id of s is "\(uuid)" then
                            select w
                            select t
                            select s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
        run(script, fallback: .iTerm2)
    }

    private static func jumpToTerminalApp(_ session: Session) {
        // TERM_SESSION_ID is Terminal.app's own tty-based identifier.
        guard let sessionID = session.terminal.termSessionID else {
            activate(.appleTerminal)
            return
        }

        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if (tty of t) is not missing value then
                            set theID to (do shell script "echo " & quoted form of "\(sessionID)")
                            if "\(sessionID)" contains (tty of t) or (tty of t) is in "\(sessionID)" then
                                set index of w to 1
                                set selected of t to true
                                return
                            end if
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """
        run(script, fallback: .appleTerminal)
    }

    private static func jumpToGhostty(_ session: Session) {
        // Ghostty has no scripting dictionary; Accessibility focus of the owning window is the
        // best available route.
        activate(.ghostty)
        focusWindowByProcess(session.terminal.pid, app: .ghostty)
    }

    private static func jumpToVSCodeFamily(_ session: Session, app: TerminalApp) {
        // Opening the folder brings the right window forward, and the integrated terminal keeps
        // whatever tab it had focused.
        guard let bundleID = app.bundleID else { return }
        let url = URL(fileURLWithPath: session.cwd)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            activate(app)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
    }

    // MARK: - Helpers

    private static func selectTmuxPane(_ pane: String, socket: String?) {
        var arguments: [String] = []
        // TMUX is "socket_path,pid,session_index" — the socket matters for multi-server setups.
        if let socket, let path = socket.split(separator: ",").first {
            arguments += ["-S", String(path)]
        }
        arguments += ["select-pane", "-t", pane]
        shell("/usr/bin/env", ["tmux"] + arguments)
    }

    /// Bring an already-running app forward. Does nothing if it isn't running — see `jump`.
    private static func activate(_ app: TerminalApp) {
        guard let bundleID = app.bundleID else { return }
        let running = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID
        }
        running?.activate()
    }

    /// Fallback when there's no usable terminal identity: walk up from the process that ran the
    /// hook until we find an app with a UI, and bring that forward.
    ///
    /// This is what makes a click useful for agents that aren't in a terminal at all — Claude Code
    /// inside the desktop app, or an IDE-hosted session — instead of the card doing nothing.
    private static func activateOwningApplication(of session: Session) {
        guard let bundleID = session.hostBundleID else {
            Log.jump.info("session \(session.id) has no resolved host app")
            return
        }

        let running = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID
        }
        guard let running else {
            Log.jump.info("host app \(bundleID) is no longer running")
            return
        }
        running.activate()
    }

    /// Raise the window that owns a given process id, using Accessibility.
    private static func focusWindowByProcess(_ pid: Int?, app: TerminalApp) {
        guard let pid, AXIsProcessTrusted() else { return }

        // The hook runs in a shell descended from the terminal, so walk up to the terminal's pid.
        guard let ownerPID = terminalOwnerPID(startingFrom: pid_t(pid)) else { return }

        let element = AXUIElementCreateApplication(ownerPID)
        var windowsValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsValue)
            == .success,
            let windows = windowsValue as? [AXUIElement],
            let first = windows.first
        else { return }

        AXUIElementPerformAction(first, kAXRaiseAction as CFString)
    }

    /// Walk the process tree upward until we hit a process owned by a known terminal app.
    private static func terminalOwnerPID(startingFrom pid: pid_t) -> pid_t? {
        let terminalPIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { TerminalApp.allBundleIDs.contains($0.bundleIdentifier ?? "") }
                .map(\.processIdentifier)
        )

        var current = pid
        for _ in 0 ..< 12 {
            if terminalPIDs.contains(current) { return current }
            guard let parent = ProcessTree.parentPID(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    private static func run(_ script: String, fallback: TerminalApp) {
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            activate(fallback)
            return
        }
        appleScript.executeAndReturnError(&error)
        if let error {
            Log.jump.error("AppleScript failed: \(error)")
            activate(fallback)
        }
    }

    @discardableResult
    private static func shell(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
