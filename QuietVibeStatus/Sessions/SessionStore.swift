import Combine
import Foundation

/// The single source of truth for live agent sessions.
///
/// Adapters push normalized events in; the notch UI observes `sessions`. Everything here runs on
/// the main actor because the UI reads it directly and hook events arrive from network queues.
@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var sessions: [Session] = [] {
        didSet { scheduleSave() }
    }
    /// Session id that should be scrolled to and highlighted, set when something demands attention.
    @Published var highlightedID: String?

    private var cleanupTimer: Timer?
    private var saveTask: Task<Void, Never>?
    /// When each session's transcript was last parsed for token usage.
    private var lastUsageReads: [String: Date] = [:]
    private let prefs = Preferences.shared

    private init() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneStaleSessions() }
        }
    }

    // MARK: - Persistence

    /// Put back the cards for agents that kept running while the app was quit.
    ///
    /// Called once at launch, before the bridge starts listening, so a hook arriving in the same
    /// moment updates the restored card rather than creating a second one for the same session.
    func restore() {
        guard prefs.restoreSessionsOnLaunch else {
            SessionPersistence.clear()
            return
        }
        guard sessions.isEmpty else { return }

        let restored = SessionPersistence.load()
            .filter { !archived.contains($0.id) && !isFiltered(cwd: $0.cwd) }
        guard !restored.isEmpty else { return }

        sessions = restored
        for session in restored {
            resolveGitInfo(for: session.id, cwd: session.cwd)
        }
        Log.bridge.info("restored \(restored.count) live session(s)")
    }

    /// Write the session list out shortly after it changes.
    ///
    /// Debounced because hook events arrive in bursts — a tool call can touch the store several
    /// times in a second, and none of those intermediate states is worth a disk write.
    private func scheduleSave() {
        guard prefs.restoreSessionsOnLaunch else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            SessionPersistence.save(self.sessions)
        }
    }

    /// Flush immediately, for app termination where a debounced write would never land.
    func saveNow() {
        saveTask?.cancel()
        guard prefs.restoreSessionsOnLaunch else { return }
        SessionPersistence.save(sessions)
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

    /// One project's sessions, in panel order.
    struct ProjectGroup: Identifiable {
        var id: String { cwd }
        let cwd: String
        let name: String
        let sessions: [Session]
    }

    /// `visibleSessions` bucketed by working directory.
    ///
    /// Several agents in one repository is the normal case, not the exception, and a flat list of
    /// identically-titled cards reads as duplicates. Groups keep the existing sort: a project is
    /// ordered by its most urgent session, and sessions keep their order inside it.
    var groupedSessions: [ProjectGroup] {
        var order: [String] = []
        var buckets: [String: [Session]] = [:]

        for session in visibleSessions {
            if buckets[session.cwd] == nil { order.append(session.cwd) }
            buckets[session.cwd, default: []].append(session)
        }

        return order.map { cwd in
            let sessions = buckets[cwd] ?? []
            return ProjectGroup(
                cwd: cwd,
                name: sessions.first?.projectName ?? (cwd as NSString).lastPathComponent,
                sessions: sessions
            )
        }
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
            let previousPID = sessions[idx].terminal.pid
            mutate(&sessions[idx])
            if let pid = sessions[idx].terminal.pid, pid == previousPID {
                sessions[idx].pidIsStable = true
            }
            // Helper sessions (title generators, memory writers) announce themselves with
            // `SessionStart` before their prompt exists, so the prompt filters cannot see them at
            // creation time. Re-check on every event: the prompt arrives a moment later.
            guard !isFiltered(prompt: sessions[idx].lastPrompt) else {
                sessions.remove(at: idx)
                return nil
            }
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

    func setModel(_ model: String, raw: String? = nil, for id: String) {
        guard let idx = index(of: id) else { return }
        sessions[idx].model = model
        if let raw { sessions[idx].rawModel = raw }
    }

    func setUsage(_ usage: TokenUsage, for id: String) {
        guard let idx = index(of: id) else { return }
        sessions[idx].usage = usage
    }

    /// Record where a session's transcript lives, and report whether a usage re-read is due.
    ///
    /// Reading usage means parsing the whole transcript, which grows to megabytes, while hooks
    /// arrive many times a second. Rate-limiting here keeps that cost off the event path.
    func noteTranscriptPath(_ path: String, for id: String) -> Bool {
        guard let idx = index(of: id) else { return false }
        sessions[idx].transcriptPath = path

        let now = Date()
        if let last = lastUsageReads[id], now.timeIntervalSince(last) < 20 { return false }
        lastUsageReads[id] = now
        return true
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
        // Log the outcome on the way out — this is the one place every disappearance funnels
        // through (agent close, manual archive, dead process, stale sweep), so recording here
        // means no ending is missed and none is double-counted.
        for session in sessions where session.id == id || session.parentID == id {
            SessionHistory.shared.record(session)
        }
        sessions.removeAll { $0.id == id || $0.parentID == id }
        lastUsageReads.removeValue(forKey: id)
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
    /// Drop sessions whose agent process is gone.
    ///
    /// A closed terminal tab or a killed CLI never runs its exit hooks, so `SessionEnd` never
    /// arrives and the card sits at "working" indefinitely. Blocked sessions are included: nobody
    /// can answer an approval whose agent already exited.
    func pruneDeadSessions() {
        retire { session in
            guard session.pidIsStable, let pid = session.terminal.pid else { return false }
            guard !ProcessTree.isAlive(pid: pid_t(pid)) else { return false }
            PendingRequestRegistry.shared.cancel(sessionID: session.id)
            return true
        }
    }

    /// Remove every session matching `shouldRetire`, logging each one to history first.
    ///
    /// Every removal path goes through here so an ending is never dropped from the log just
    /// because it happened via a sweep rather than a `SessionEnd` event.
    private func retire(where shouldRetire: (Session) -> Bool) {
        var remaining: [Session] = []
        remaining.reserveCapacity(sessions.count)

        for session in sessions {
            if shouldRetire(session) {
                SessionHistory.shared.record(session)
                lastUsageReads.removeValue(forKey: session.id)
            } else {
                remaining.append(session)
            }
        }

        guard remaining.count != sessions.count else { return }
        sessions = remaining
    }

    private func pruneStaleSessions() {
        pruneDeadSessions()

        let now = Date()
        let idleLimit = prefs.idleCleanupSeconds
        retire { session in
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
