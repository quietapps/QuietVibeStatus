import Foundation

/// Saves live sessions across app restarts.
///
/// Agents keep running while the app is quit, updated, or crashes, and their `SessionStart` has
/// long passed — so without this every card is lost and the panel sits empty next to half a dozen
/// working agents until each one happens to fire its next hook.
///
/// Only sessions whose agent process is still alive are restored, which is what stops the file
/// turning into a graveyard of cards for terminals closed days ago.
enum SessionPersistence {
    /// What we write per session. A hand-rolled snapshot rather than making `Session` itself
    /// `Codable`: this file is a compatibility surface across app versions, and it should carry
    /// only the fields a restored card actually needs.
    struct Snapshot: Codable {
        var id: String
        var agent: String
        var cwd: String
        var state: String
        var model: String?
        var sessionTitle: String?
        var lastPrompt: String?
        var recap: String?
        var lastActivity: String?
        var branch: String?
        var worktree: String?
        var rawModel: String?
        var usage: TokenUsage?
        var transcriptPath: String?
        var terminal: TerminalIdentity
        var hostBundleID: String?
        var parentID: String?
        var startedAt: Date
        var updatedAt: Date
    }

    private struct File: Codable {
        var version: Int
        var savedAt: Date
        var sessions: [Snapshot]
    }

    private static let version = 1

    static var url: URL {
        // Tests write and delete this file freely, so they must never be pointed at the state of
        // the copy the user is actually running.
        let folder = AppDelegate.isRunningTests ? "state-tests" : "state"
        return BridgeServer.supportDirectory
            .appendingPathComponent(folder)
            .appendingPathComponent("sessions.json")
    }

    // MARK: - Saving

    /// Blocking events are excluded on purpose: the approval they were waiting on died with the
    /// old process, so restoring the card would show a button that resolves nothing.
    static func save(_ sessions: [Session]) {
        let snapshots = sessions
            .filter { !$0.state.isBlocked && $0.terminal.pid != nil }
            .map(snapshot)

        let file = File(version: version, savedAt: Date(), sessions: snapshots)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(file)

            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            // Prompts and recaps are the user's own words — no other account may read them.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            Log.bridge.error("session save failed: \(error.localizedDescription)")
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Loading

    /// Sessions worth putting back on screen: same file format, agent still running.
    static func load() -> [Session] {
        guard let data = try? Data(contentsOf: url) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let file = try? decoder.decode(File.self, from: data), file.version == version else {
            return []
        }

        return file.sessions.compactMap(session)
    }

    // MARK: - Conversion

    private static func snapshot(_ session: Session) -> Snapshot {
        Snapshot(
            id: session.id,
            agent: session.agent.rawValue,
            cwd: session.cwd,
            state: session.state.rawValue,
            model: session.model,
            sessionTitle: session.sessionTitle,
            lastPrompt: session.lastPrompt,
            recap: session.recap,
            lastActivity: session.lastActivity,
            branch: session.branch,
            worktree: session.worktree,
            rawModel: session.rawModel,
            usage: session.usage,
            transcriptPath: session.transcriptPath,
            terminal: session.terminal,
            hostBundleID: session.hostBundleID,
            parentID: session.parentID,
            startedAt: session.startedAt,
            updatedAt: session.updatedAt
        )
    }

    private static func session(from snapshot: Snapshot) -> Session? {
        guard let agent = AgentKind(rawValue: snapshot.agent) else { return nil }

        // The pid is the whole point of restoring: a session whose process is gone is a card the
        // user would have to dismiss by hand for no reason.
        guard let pid = snapshot.terminal.pid, ProcessTree.isAlive(pid: pid_t(pid)) else {
            return nil
        }

        var session = Session(id: snapshot.id, agent: agent, cwd: snapshot.cwd)
        session.state = SessionState(rawValue: snapshot.state) ?? .working
        session.model = snapshot.model
        session.sessionTitle = snapshot.sessionTitle
        session.lastPrompt = snapshot.lastPrompt
        session.recap = snapshot.recap
        session.lastActivity = snapshot.lastActivity
        session.branch = snapshot.branch
        session.worktree = snapshot.worktree
        session.rawModel = snapshot.rawModel
        session.usage = snapshot.usage
        session.transcriptPath = snapshot.transcriptPath
        session.terminal = snapshot.terminal
        session.hostBundleID = snapshot.hostBundleID
        session.parentID = snapshot.parentID
        session.startedAt = snapshot.startedAt
        session.updatedAt = snapshot.updatedAt
        // The pid was verified alive just now, so liveness sweeps can trust it immediately.
        session.pidIsStable = true
        return session
    }
}
