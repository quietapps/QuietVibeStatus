import Combine
import Foundation

/// The single source of truth for live agent sessions.
///
/// Adapters push normalized events in; the notch UI observes `sessions`. Everything here runs on
/// the main actor because the UI reads it directly and hook events arrive from network queues.
@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var sessions: [Session] = []
    /// Session id that should be scrolled to and highlighted, set when something demands attention.
    @Published var highlightedID: String?

    private var cleanupTimer: Timer?
    private let prefs = Preferences.shared

    private init() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneStaleSessions() }
        }
    }

    // MARK: - Ordering

    /// Cards sorted so anything blocking on you is first, then most recently active.
    var visibleSessions: [Session] {
        sessions
            .filter { $0.parentID == nil }
            .sorted { lhs, rhs in
                if lhs.state.sortRank != rhs.state.sortRank {
                    return lhs.state.sortRank < rhs.state.sortRank
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    var blockedSessions: [Session] {
        visibleSessions.filter { $0.state.isBlocked }
    }

    var hasActiveWork: Bool {
        sessions.contains { $0.state == .working || $0.state == .compacting }
    }

    // MARK: - Lookup

    func session(id: String) -> Session? {
        sessions.first { $0.id == id }
    }

    func index(of id: String) -> Int? {
        sessions.firstIndex { $0.id == id }
    }

    // MARK: - Mutation

    /// Create the session if we haven't seen this id, then apply `mutate`. Adapters call this for
    /// every event so a session can materialize from any event, not only `SessionStart` — hooks
    /// can be installed mid-session, and the app can launch after the agent did.
    @discardableResult
    func upsert(id: String, agent: AgentKind, cwd: String, mutate: (inout Session) -> Void) -> Session? {
        if let idx = index(of: id) {
            mutate(&sessions[idx])
            sessions[idx].updatedAt = Date()
            resolveHostIfNeeded(&sessions[idx])
            return sessions[idx]
        }

        // Archived by hand — stay gone even though the agent is still reporting.
        guard !archived.contains(id) else { return nil }
        guard !isFiltered(cwd: cwd) else { return nil }

        var session = Session(id: id, agent: agent, cwd: cwd)
        mutate(&session)
        guard !isFiltered(prompt: session.lastPrompt) else { return nil }
        resolveHostIfNeeded(&session)
        sessions.append(session)
        resolveGitInfo(for: id, cwd: cwd)
        return session
    }

    /// Resolve the owning application now, not at click time.
    ///
    /// The captured pid is the bridge shell, which exits as soon as the hook returns. Walking the
    /// tree here works because the hook is still blocked waiting on our reply; deferring it until
    /// the user clicks meant the process was always already gone.
    private func resolveHostIfNeeded(_ session: inout Session) {
        guard session.hostBundleID == nil, let pid = session.terminal.pid else { return }
        session.hostBundleID = ProcessTree.owningAppBundleID(of: pid_t(pid))
    }

    /// Fill in branch and worktree in the background — `git` is a subprocess, and hook events
    /// arrive on a hot path that must not wait on it.
    private func resolveGitInfo(for id: String, cwd: String) {
        Task.detached(priority: .utility) {
            guard let info = GitInfo.resolve(for: cwd) else { return }
            await MainActor.run {
                SessionStore.shared.applyGitInfo(info, to: id)
            }
        }
    }

    func applyGitInfo(_ info: GitInfo.Info, to id: String) {
        guard let idx = index(of: id) else { return }
        sessions[idx].branch = info.branch
        sessions[idx].worktree = info.worktree
    }

    func setModel(_ model: String, for id: String) {
        guard let idx = index(of: id) else { return }
        sessions[idx].model = model
    }

    func setState(_ state: SessionState, for id: String) {
        guard let idx = index(of: id) else { return }
        sessions[idx].state = state
        sessions[idx].updatedAt = Date()
        if state == .complete || state == .failed {
            sessions[idx].revealedAt = Date()
        }
    }

    func remove(id: String) {
        sessions.removeAll { $0.id == id || $0.parentID == id }
    }

    /// The agent reported this session finished, so forget any archive entry for it.
    func sessionDidEnd(id: String) {
        archived.remove(id)
        remove(id: id)
    }

    func removeAll() {
        sessions.removeAll()
        archived.removeAll()
    }

    // MARK: - Archiving

    /// Sessions the user has dismissed from the panel by hand.
    ///
    /// Kept as ids rather than just deleting the row, because a live agent keeps sending events —
    /// without this the next tool call would rebuild the card you just dismissed.
    @Published private(set) var archived: Set<String> = []

    /// Hide a session until it ends. Any approval it was blocking on is released first, so
    /// archiving can never strand an agent waiting on a card that is no longer on screen.
    func archive(id: String) {
        PendingRequestRegistry.shared.cancel(sessionID: id)
        archived.insert(id)
        remove(id: id)
    }

    func unarchiveAll() {
        archived.removeAll()
    }

    // MARK: - Subagents

    func startSubagent(sessionID: String, agentID: String, type: String) {
        guard let idx = index(of: sessionID) else { return }
        guard !sessions[idx].subagents.contains(where: { $0.id == agentID }) else { return }
        sessions[idx].subagents.append(Subagent(id: agentID, type: type, startedAt: Date()))
        sessions[idx].updatedAt = Date()
    }

    func finishSubagent(sessionID: String, agentID: String) {
        guard let idx = index(of: sessionID),
              let subIdx = sessions[idx].subagents.firstIndex(where: { $0.id == agentID })
        else { return }
        sessions[idx].subagents[subIdx].finishedAt = Date()
        sessions[idx].updatedAt = Date()
    }

    func noteSubagentActivity(sessionID: String, agentID: String, activity: String) {
        guard let idx = index(of: sessionID),
              let subIdx = sessions[idx].subagents.firstIndex(where: { $0.id == agentID })
        else { return }
        sessions[idx].subagents[subIdx].lastActivity = activity
    }

    // MARK: - Filters

    /// Directory filters hide background/helper sessions (memory writers, health probes) before
    /// they ever reach the panel.
    func isFiltered(cwd: String) -> Bool {
        if prefs.filterCodexInternalWorkers {
            for preset in Self.presetDirectoryFilters where cwd.contains(preset) {
                return true
            }
        }
        return prefs.directoryFilters.contains { !$0.isEmpty && cwd.contains($0) }
    }

    func isFiltered(prompt: String?) -> Bool {
        guard let prompt, !prompt.isEmpty else { return false }
        let patterns = prefs.promptFilters + Self.presetPromptFilters
        return patterns.contains { pattern in
            guard !pattern.isEmpty else { return false }
            return prefs.promptFilterMatchType == "contains"
                ? prompt.contains(pattern)
                : prompt.hasPrefix(pattern)
        }
    }

    static let presetDirectoryFilters = [
        "/.codex/memories",
        "/chronicle/screen_recording",
        "/.claude-mem",
    ]

    static let presetPromptFilters = [
        "## Memory Writing Agent",
        "# Overview Generate personalized suggestions",
        "Using the supplied context below, generate",
        "What topic or task is this about? Give a short descriptive title",
    ]

    // MARK: - Cleanup

    /// Sessions from agents without a reliable close signal linger forever otherwise. Sessions
    /// that finished cleanly age out much faster, since their card has already been read.
    private func pruneStaleSessions() {
        let now = Date()
        let idleLimit = prefs.idleCleanupSeconds
        sessions.removeAll { session in
            guard !session.state.isBlocked else { return false }
            let age = now.timeIntervalSince(session.updatedAt)
            switch session.state {
            case .complete, .failed, .idle:
                return age > idleLimit
            default:
                // A "working" session that has not sent an event in an hour is almost certainly gone.
                return age > max(idleLimit, 3600)
            }
        }
    }
}
