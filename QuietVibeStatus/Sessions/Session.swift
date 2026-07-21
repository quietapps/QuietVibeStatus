import SwiftUI

/// Which CLI or app a session belongs to. Every adapter normalizes onto this enum so the UI
/// never has to branch on vendor-specific event names.
enum AgentKind: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex
    case gemini
    case cursor
    case codexDesktop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .cursor: return "Cursor"
        case .codexDesktop: return "Codex Desktop"
        }
    }

    /// Brand tint used for the agent chip on a session card.
    var tint: Color {
        switch self {
        case .claude: return Color(hex: 0xD97757)
        case .codex: return Color(hex: 0x8E8E93)
        case .gemini: return Color(hex: 0x4285F4)
        case .cursor: return Color(hex: 0x6E56CF)
        case .codexDesktop: return Color(hex: 0x8E8E93)
        }
    }
}

/// What a session is doing right now. Ordering matters: `sortRank` drives which card floats to
/// the top of the panel, because a session waiting on you outranks one that is merely busy.
enum SessionState: String, Codable {
    /// The agent is running a turn.
    case working
    /// Blocked on a permission approval.
    case needsApproval
    /// Blocked on a question (AskUserQuestion / elicitation).
    case needsAnswer
    /// Blocked on a plan review.
    case needsPlanReview
    /// Turn finished cleanly.
    case complete
    /// Turn ended on an API or tool error.
    case failed
    /// Waiting for the user to type something.
    case idle
    /// Compacting context.
    case compacting

    var sortRank: Int {
        switch self {
        case .needsApproval, .needsAnswer, .needsPlanReview: return 0
        case .failed: return 1
        case .working, .compacting: return 2
        case .complete: return 3
        case .idle: return 4
        }
    }

    var isBlocked: Bool {
        switch self {
        case .needsApproval, .needsAnswer, .needsPlanReview: return true
        default: return false
        }
    }

    var dotColor: Color {
        switch self {
        case .working, .compacting: return Theme.blue
        case .needsApproval, .needsAnswer, .needsPlanReview: return Theme.attention
        case .complete: return Theme.success
        case .failed: return Theme.danger
        case .idle: return Theme.onDark3
        }
    }

    var label: String {
        switch self {
        case .working: return "Working"
        case .needsApproval: return "Needs approval"
        case .needsAnswer: return "Needs answer"
        case .needsPlanReview: return "Plan review"
        case .complete: return "Done"
        case .failed: return "Error"
        case .idle: return "Idle"
        case .compacting: return "Compacting"
        }
    }
}

/// Everything we know about where a session is running, captured by the bridge script from the
/// agent's environment. This is what makes precise click-to-jump possible.
struct TerminalIdentity: Codable, Equatable {
    var termProgram: String?
    var termSessionID: String?
    var itermSessionID: String?
    var windowID: String?
    var tmux: String?
    var tmuxPane: String?
    var ghostty: Bool = false
    var pid: Int?

    var isEmpty: Bool {
        termProgram == nil && termSessionID == nil && itermSessionID == nil
            && windowID == nil && tmux == nil
    }
}

/// A nested subagent (Task fan-out, Agent Team member, Codex worker).
struct Subagent: Identifiable, Equatable {
    let id: String
    var type: String
    var startedAt: Date
    var finishedAt: Date?
    var lastActivity: String?

    init(
        id: String,
        type: String,
        startedAt: Date,
        finishedAt: Date? = nil,
        lastActivity: String? = nil
    ) {
        self.id = id
        self.type = type
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.lastActivity = lastActivity
    }

    var isRunning: Bool { finishedAt == nil }

    var elapsed: TimeInterval {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

/// One agent session — the unit a session card renders.
struct Session: Identifiable, Equatable {
    let id: String
    var agent: AgentKind
    var cwd: String
    var state: SessionState = .working

    var model: String?
    var sessionTitle: String?
    var lastPrompt: String?
    /// `last_assistant_message` from Stop — the "away summary" shown on an idle card.
    var recap: String?
    var lastActivity: String?
    var lastActivityAt: Date?
    var errorMessage: String?

    var worktree: String?
    var branch: String?

    var terminal = TerminalIdentity()
    /// Bundle id of the app this session lives in, resolved while the hook was still running.
    var hostBundleID: String?
    var subagents: [Subagent] = []
    /// Set when this session is itself a subagent of another session.
    var parentID: String?

    var startedAt = Date()
    var updatedAt = Date()
    /// When a completion or warning reveal started, so the panel knows when to auto-collapse.
    var revealedAt: Date?

    var projectName: String {
        (cwd as NSString).lastPathComponent
    }

    /// The one-line headline on the card: session title if the agent named the session,
    /// otherwise the prompt the user typed.
    var headline: String {
        if let title = sessionTitle, !title.isEmpty { return title }
        if let prompt = lastPrompt, !prompt.isEmpty { return prompt }
        return projectName
    }

    var runningSubagents: [Subagent] {
        subagents.filter(\.isRunning)
    }

    /// The terminal hosting this session, but only if it is identifiable *and* still running.
    /// Everything user-facing keys off this rather than the raw captured environment.
    var runningHost: TerminalApp? {
        guard terminal.termProgram != nil || terminal.ghostty else { return nil }
        let app = TerminalApp.resolve(from: terminal)
        guard app != .unknown, app.isRunning else { return nil }
        return app
    }
}
