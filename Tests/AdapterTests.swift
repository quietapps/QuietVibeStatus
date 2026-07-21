import XCTest
@testable import QuietVibeStatus

/// Drives each adapter through the same path the bridge uses: a decoded envelope in, a hook
/// response string out, with the session store as the observable side effect.
@MainActor
final class AdapterTests: XCTestCase {
    private var store: SessionStore { SessionStore.shared }

    override func setUp() async throws {
        try await super.setUp()
        store.removeAll()
        Preferences.shared.directoryFilters = []
        Preferences.shared.promptFilters = []
        Preferences.shared.soundEnabled = false
    }

    override func tearDown() async throws {
        store.removeAll()
        try await super.tearDown()
    }

    // MARK: - Claude

    func testSessionStartCreatesACardWithModelAndTitle() async {
        _ = await ClaudeAdapter().handle(HookFixtures.claude(
            event: "SessionStart",
            extra: ["model": "claude-opus-4-8", "session_title": "Auth refactor"]
        ))

        let session = store.session(id: "session-1")
        XCTAssertEqual(session?.state, .idle)
        XCTAssertEqual(session?.model, "Opus 4.8")
        XCTAssertEqual(session?.sessionTitle, "Auth refactor")
        XCTAssertEqual(session?.terminal.pid, 4242)
    }

    /// Hooks get installed mid-session and the app can launch after the agent did, so any event
    /// has to be able to materialize a card.
    func testSessionMaterializesFromAToolEventAlone() async {
        _ = await ClaudeAdapter().handle(HookFixtures.claude(
            event: "PreToolUse",
            extra: ["tool_name": "Bash", "tool_input": ["command": "swift build"]]
        ))

        let session = store.session(id: "session-1")
        XCTAssertEqual(session?.state, .working)
        XCTAssertEqual(session?.lastActivity, "Running swift build")
    }

    func testStopRecordsTheRecapAndCompletes() async {
        _ = await ClaudeAdapter().handle(HookFixtures.claude(
            event: "Stop",
            extra: ["last_assistant_message": "Fixed the failing test."]
        ))

        let session = store.session(id: "session-1")
        XCTAssertEqual(session?.state, .complete)
        XCTAssertEqual(session?.recap, "Fixed the failing test.")
        XCTAssertNotNil(session?.revealedAt)
    }

    func testStopFailureRecordsTheErrorType() async {
        _ = await ClaudeAdapter().handle(HookFixtures.claude(
            event: "StopFailure",
            extra: ["error_type": "api_error"]
        ))

        XCTAssertEqual(store.session(id: "session-1")?.state, .failed)
        XCTAssertEqual(store.session(id: "session-1")?.errorMessage, "api_error")
    }

    func testSessionEndRemovesTheCard() async {
        _ = await ClaudeAdapter().handle(HookFixtures.claude(event: "SessionStart"))
        XCTAssertEqual(store.sessions.count, 1)

        _ = await ClaudeAdapter().handle(HookFixtures.claude(event: "SessionEnd"))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testCompactionMovesThroughCompactingAndBack() async {
        _ = await ClaudeAdapter().handle(HookFixtures.claude(event: "SessionStart"))

        _ = await ClaudeAdapter().handle(HookFixtures.claude(event: "PreCompact"))
        XCTAssertEqual(store.session(id: "session-1")?.state, .compacting)

        _ = await ClaudeAdapter().handle(HookFixtures.claude(event: "PostCompact"))
        XCTAssertEqual(store.session(id: "session-1")?.state, .working)
    }

    func testSubagentLifecycleNestsUnderTheParent() async {
        _ = await ClaudeAdapter().handle(HookFixtures.claude(event: "SessionStart"))

        _ = await ClaudeAdapter().handle(HookFixtures.claude(
            event: "SubagentStart",
            extra: ["agent_id": "sub-1", "agent_type": "Explore"]
        ))
        XCTAssertEqual(store.session(id: "session-1")?.runningSubagents.count, 1)

        _ = await ClaudeAdapter().handle(HookFixtures.claude(
            event: "SubagentStop",
            extra: ["agent_id": "sub-1"]
        ))
        XCTAssertEqual(store.session(id: "session-1")?.runningSubagents.count, 0)
    }

    func testUnknownEventIsInertAndAnswersEmpty() async {
        let response = await ClaudeAdapter().handle(HookFixtures.claude(event: "SomeFutureEvent"))
        XCTAssertEqual(response, "{}")
    }

    func testNotificationTypesMapOntoStates() async {
        _ = await ClaudeAdapter().handle(HookFixtures.claude(
            event: "Notification",
            extra: ["notification_type": "idle_prompt", "message": "Waiting for input"]
        ))

        XCTAssertEqual(store.session(id: "session-1")?.state, .idle)
        XCTAssertEqual(store.session(id: "session-1")?.lastActivity, "Waiting for input")
    }

    // MARK: - Codex

    func testCodexEventsMapOntoTheSharedLifecycle() async {
        let envelope = HookFixtures.envelope(
            source: "codex",
            payload: [
                "hook_event_name": "UserPromptSubmit",
                "session_id": "codex-1",
                "cwd": "/tmp/project",
                "prompt": "add a migration",
            ]
        )

        _ = await CodexAdapter().handle(envelope)

        let session = store.session(id: "codex-1")
        XCTAssertEqual(session?.agent, .codex)
        XCTAssertEqual(session?.state, .working)
        XCTAssertEqual(session?.lastPrompt, "add a migration")
    }

    /// Without a session id from the agent, sessions must not all collapse into one card.
    func testCodexFallsBackToThePIDWhenNoSessionIDIsSent() async {
        let envelope = HookFixtures.envelope(
            source: "codex",
            pid: "9001",
            payload: ["hook_event_name": "SessionStart", "cwd": "/tmp/project"]
        )

        _ = await CodexAdapter().handle(envelope)
        XCTAssertNotNil(store.session(id: "codex-9001"))
    }

    // MARK: - Gemini

    func testGeminiUsesItsOwnEventVocabulary() async {
        let envelope = HookFixtures.envelope(
            source: "gemini",
            payload: [
                "hook_event_name": "AfterAgent",
                "session_id": "gem-1",
                "cwd": "/tmp/project",
                "response": "All done.",
            ]
        )

        _ = await GeminiAdapter().handle(envelope)

        XCTAssertEqual(store.session(id: "gem-1")?.state, .complete)
        XCTAssertEqual(store.session(id: "gem-1")?.recap, "All done.")
    }

    // MARK: - Cursor

    func testCursorReadsConversationIDAndItsOwnPromptField() async {
        let envelope = HookFixtures.envelope(
            source: "cursor",
            payload: [
                "hook_event_name": "beforeSubmitPrompt",
                "conversation_id": "conv-1",
                "workspace_root": "/tmp/project",
                "prompt": "rename the module",
            ]
        )

        _ = await CursorAdapter().handle(envelope)

        let session = store.session(id: "conv-1")
        XCTAssertEqual(session?.agent, .cursor)
        XCTAssertEqual(session?.lastPrompt, "rename the module")
        XCTAssertEqual(session?.cwd, "/tmp/project")
    }

    /// Cursor fires these before *every* shell call, whether or not it intends to ask anything.
    /// Treating them as approvals invented prompts Cursor never made and stalled its agent.
    func testCursorShellHooksAreActivityNotApprovals() async {
        let envelope = HookFixtures.envelope(
            source: "cursor",
            payload: [
                "hook_event_name": "beforeShellExecution",
                "conversation_id": "conv-1",
                "workspace_root": "/tmp/project",
                "command": "rm -rf build",
            ]
        )

        let response = await CursorAdapter().handle(envelope)

        XCTAssertEqual(response, "{}", "the hook must not be held open")
        XCTAssertEqual(store.session(id: "conv-1")?.state, .working)
        XCTAssertFalse(store.session(id: "conv-1")?.state.isBlocked ?? true)
    }
}
