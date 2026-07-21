import Foundation

/// What the user is being asked to decide.
enum ApprovalKind: Equatable {
    /// A tool wants permission to run.
    case permission(tool: String, input: JSONValue)
    /// The agent finished planning and wants to start work.
    case planReview(plan: String)
    /// The agent asked a structured question.
    case question(QuestionSet)
}

/// One `AskUserQuestion`-style question with its options.
struct QuestionItem: Identifiable, Equatable {
    let id = UUID()
    var header: String
    var question: String
    var options: [Option]
    var multiSelect: Bool

    struct Option: Identifiable, Equatable {
        let id = UUID()
        var label: String
        var description: String
    }
}

struct QuestionSet: Equatable {
    var items: [QuestionItem]
    /// The raw tool input, so we can hand it back with `answers` filled in.
    var rawInput: JSONValue
}

/// How the user answered.
enum ApprovalOutcome: Equatable {
    case allow
    case allowAlways
    case deny(reason: String?)
    /// Approve a plan and switch the session out of plan mode.
    case approvePlan(autoMode: Bool)
    case rejectPlan(feedback: String)
    case answered([String: String])
    /// User chose to handle it in the terminal, or we timed out — return no opinion.
    case defer_
}

/// A pending decision, shown as a card and awaited by a parked bridge connection.
struct ApprovalRequest: Identifiable, Equatable {
    let id: String
    var sessionID: String
    var agent: AgentKind
    var kind: ApprovalKind
    var createdAt = Date()

    /// Short human label for the card headline.
    var title: String {
        switch kind {
        case let .permission(tool, _): return tool
        case .planReview: return "Plan review"
        case .question: return "Question"
        }
    }

    static func == (lhs: ApprovalRequest, rhs: ApprovalRequest) -> Bool {
        lhs.id == rhs.id
    }
}
