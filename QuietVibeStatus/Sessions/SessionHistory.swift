import Combine
import Foundation

/// One finished session, kept after its card is gone.
struct HistoryEntry: Identifiable, Codable, Equatable {
    var id: String
    var agent: String
    var project: String
    var cwd: String
    var headline: String
    var model: String?
    var branch: String?
    var recap: String?
    var errorMessage: String?
    var failed: Bool
    var startedAt: Date
    var endedAt: Date
    var usage: TokenUsage?
    var estimatedCost: Double?

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    var agentKind: AgentKind { AgentKind(rawValue: agent) ?? .claude }

    var durationText: String {
        let seconds = Int(duration)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return String(format: "%.1fh", duration / 3600)
    }
}

/// A log of sessions that have finished.
///
/// Live cards are deliberately short-lived — they age out so the panel stays a picture of *now*.
/// That left no way to answer "what did I run this morning, and what did it cost", which is what
/// this file is for. It records outcomes only; nothing is written while a session is still running.
@MainActor
final class SessionHistory: ObservableObject {
    static let shared = SessionHistory()

    @Published private(set) var entries: [HistoryEntry] = []

    /// Cap the log so a busy month can't grow it without bound. Oldest entries fall off first.
    private let limit = 500

    private var saveTask: Task<Void, Never>?
    private let prefs = Preferences.shared

    static var url: URL {
        let folder = AppDelegate.isRunningTests ? "state-tests" : "state"
        return BridgeServer.supportDirectory
            .appendingPathComponent(folder)
            .appendingPathComponent("history.json")
    }

    private init() {}

    func load() {
        guard prefs.keepSessionHistory else { return }
        guard let data = try? Data(contentsOf: Self.url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    /// Record a session that just ended. Ignores sessions that never did anything.
    func record(_ session: Session) {
        guard prefs.keepSessionHistory else { return }
        guard session.lastPrompt != nil || session.usage != nil || session.recap != nil else {
            return
        }
        guard !entries.contains(where: { $0.id == session.id }) else { return }

        let entry = HistoryEntry(
            id: session.id,
            agent: session.agent.rawValue,
            project: session.projectName,
            cwd: session.cwd,
            headline: session.headline,
            model: session.model,
            branch: session.branch,
            recap: session.recap,
            errorMessage: session.errorMessage,
            failed: session.state == .failed,
            startedAt: session.startedAt,
            endedAt: Date(),
            usage: session.usage,
            estimatedCost: session.estimatedCost
        )

        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        scheduleSave()
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: Self.url)
    }

    // MARK: - Totals

    /// Entries from the last `days` days, newest first.
    func entries(withinDays days: Int) -> [HistoryEntry] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        return entries.filter { $0.endedAt >= cutoff }
    }

    func totalCost(withinDays days: Int) -> Double {
        entries(withinDays: days).compactMap(\.estimatedCost).reduce(0, +)
    }

    func totalTokens(withinDays days: Int) -> Int {
        entries(withinDays: days).compactMap(\.usage?.totalTokens).reduce(0, +)
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        guard prefs.keepSessionHistory else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(entries)
            try FileManager.default.createDirectory(
                at: Self.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: Self.url, options: .atomic)
            // Prompts and recaps are the user's own words.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: Self.url.path
            )
        } catch {
            Log.bridge.error("history save failed: \(error.localizedDescription)")
        }
    }
}
