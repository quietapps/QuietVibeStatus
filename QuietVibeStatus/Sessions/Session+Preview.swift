import Foundation

extension Session {
    /// A representative session for the Settings preview.
    ///
    /// Deliberately carries every optional field the card can render — branch, model, activity,
    /// recap, subagents — so each Session card toggle has something visible to switch off. The
    /// preview renders the real `SessionCard`, so anything true of this sample is true of the notch.
    static var preview: Session {
        var session = Session(
            id: "preview",
            agent: .claude,
            cwd: "/Users/you/Projects/quiet-vibe-status"
        )
        session.state = .working
        session.model = "Opus 4.8"
        session.lastPrompt = "extract chatEndpoint into a transport-agnostic layer"
        session.lastActivity = "Editing chatEndpoint.ts"
        session.lastActivityAt = Date().addingTimeInterval(-12)
        session.startedAt = Date().addingTimeInterval(-215)
        session.branch = "chat-ui"
        session.sessionTitle = "Refactor the chat endpoint"
        session.subagents = [
            Subagent(
                id: "a",
                type: "Explore (Search API endpoints)",
                startedAt: Date().addingTimeInterval(-8),
                lastActivity: "Grep: handleRequest"
            ),
            Subagent(
                id: "b",
                type: "Explore (Read config files)",
                startedAt: Date().addingTimeInterval(-30),
                finishedAt: Date().addingTimeInterval(-4)
            ),
        ]
        return session
    }
}
