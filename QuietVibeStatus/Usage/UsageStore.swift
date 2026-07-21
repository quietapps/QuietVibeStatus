import Combine
import Foundation

/// One provider's quota window.
struct UsageWindow: Equatable {
    var usedPercentage: Double
    var resetsAt: Date?

    var remainingPercentage: Double { max(0, 100 - usedPercentage) }

    var resetText: String? {
        guard let resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSinceNow
        guard seconds > 0 else { return nil }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }
}

struct ProviderUsage: Equatable {
    /// Which agent this quota belongs to. Carried as the enum rather than a name so the badge can
    /// brand it — two providers' percentages look identical without it.
    var agent: AgentKind
    var short: UsageWindow?
    var long: UsageWindow?
    var updatedAt: Date

    var provider: String { agent.displayName }

    /// Data older than this is shown dimmed rather than hidden, so the panel never goes blank
    /// just because no session has reported in for a while.
    var isStale: Bool {
        Date().timeIntervalSince(updatedAt) > 1800
    }
}

/// Tracks subscription quota for the providers we can read.
///
/// Claude usage arrives through the status line bridge (the only place Claude Code publishes rate
/// limits); Codex usage is read from its own state files.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var claude: ProviderUsage?
    @Published private(set) var codex: ProviderUsage?

    private var timer: Timer?
    private let prefs = Preferences.shared

    private init() {}

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// The provider the header should show, honoring the user's Auto/Claude/Codex preference.
    var displayed: ProviderUsage? {
        switch prefs.usageProvider {
        case "claude": return claude
        case "codex": return codex
        default:
            // Auto: follow whichever provider reported most recently.
            switch (claude, codex) {
            case let (lhs?, rhs?): return lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
            case let (lhs?, nil): return lhs
            case let (nil, rhs?): return rhs
            default: return nil
            }
        }
    }

    /// Every provider the header should show, in the user's preferred order.
    ///
    /// In Auto mode both Claude and Codex are shown when both have reported — a five-hour
    /// percentage is meaningless without knowing whose it is, and hiding one behind "most recent"
    /// loses the case where the quiet provider is the one about to run out.
    var displayedAll: [ProviderUsage] {
        switch prefs.usageProvider {
        case "claude": return [claude].compactMap { $0 }
        case "codex": return [codex].compactMap { $0 }
        default:
            // Most-recently-active provider first, so the one you're using leads.
            return [claude, codex]
                .compactMap { $0 }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    func refresh() {
        readClaude()
        readCodex()
    }

    // MARK: - Claude

    private func readClaude() {
        let url = StatusLineInstaller.cacheURL
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let limits = root["rate_limits"] as? [String: Any]
        let updated = (root["updated_at"] as? Double).map { Date(timeIntervalSince1970: $0) }

        claude = ProviderUsage(
            agent: .claude,
            short: window(from: limits?["five_hour"] as? [String: Any]),
            long: window(from: limits?["seven_day"] as? [String: Any]),
            updatedAt: updated ?? Date()
        )
    }

    private func window(from dict: [String: Any]?) -> UsageWindow? {
        guard let dict, let used = dict["used_percentage"] as? Double else { return nil }
        let resets = (dict["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return UsageWindow(usedPercentage: used, resetsAt: resets)
    }

    // MARK: - Codex

    /// Codex writes rate-limit snapshots into its own state directory. The exact filename has moved
    /// between versions, so scan for the newest file that carries the fields we need.
    private func readCodex() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
        let candidates = [
            base.appendingPathComponent("rate_limits.json"),
            base.appendingPathComponent("usage.json"),
            base.appendingPathComponent("cache/rate_limits.json"),
        ]

        for url in candidates {
            guard
                let data = try? Data(contentsOf: url),
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let primary = root["primary"] as? [String: Any] ?? root["five_hour"] as? [String: Any]
            let secondary = root["secondary"] as? [String: Any] ?? root["weekly"] as? [String: Any]

            guard primary != nil || secondary != nil else { continue }

            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date

            codex = ProviderUsage(
                agent: .codex,
                short: codexWindow(from: primary),
                long: codexWindow(from: secondary),
                updatedAt: modified ?? Date()
            )
            return
        }
    }

    private func codexWindow(from dict: [String: Any]?) -> UsageWindow? {
        guard let dict else { return nil }
        let used = (dict["used_percent"] as? Double)
            ?? (dict["used_percentage"] as? Double)
            ?? (dict["percent_used"] as? Double)
        guard let used else { return nil }

        // Codex reports "minutes until reset" rather than an absolute timestamp in some versions.
        var resets: Date?
        if let seconds = dict["resets_in_seconds"] as? Double {
            resets = Date().addingTimeInterval(seconds)
        } else if let epoch = dict["resets_at"] as? Double {
            resets = Date(timeIntervalSince1970: epoch)
        }

        return UsageWindow(usedPercentage: used, resetsAt: resets)
    }
}
