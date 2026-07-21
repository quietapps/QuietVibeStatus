import XCTest
@testable import QuietVibeStatus

@MainActor
final class SessionHistoryTests: XCTestCase {
    private var history: SessionHistory { SessionHistory.shared }
    private let prefs = Preferences.shared

    override func setUp() async throws {
        try await super.setUp()
        prefs.keepSessionHistory = true
        history.clear()
    }

    override func tearDown() async throws {
        history.clear()
        try await super.tearDown()
    }

    private func session(id: String, prompt: String? = "do a thing") -> Session {
        var s = Session(id: id, agent: .claude, cwd: "/tmp/project")
        s.lastPrompt = prompt
        s.model = "Opus 4.8"
        s.usage = TokenUsage(input: 1000, output: 500)
        return s
    }

    func testRecordingAddsAnEntry() {
        history.record(session(id: "a"))
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.id, "a")
        XCTAssertEqual(history.entries.first?.model, "Opus 4.8")
    }

    func testEmptySessionsAreNotRecorded() {
        var empty = Session(id: "empty", agent: .claude, cwd: "/tmp/project")
        empty.lastPrompt = nil
        history.record(empty)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testTheSameSessionIsNotRecordedTwice() {
        history.record(session(id: "a"))
        history.record(session(id: "a"))
        XCTAssertEqual(history.entries.count, 1)
    }

    func testNewestEntryIsFirst() {
        history.record(session(id: "first"))
        history.record(session(id: "second"))
        XCTAssertEqual(history.entries.map(\.id), ["second", "first"])
    }

    func testDisablingHistoryStopsRecording() {
        prefs.keepSessionHistory = false
        history.record(session(id: "a"))
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testTotalsSumEstimatedCostAndTokens() {
        history.record(session(id: "a"))
        history.record(session(id: "b"))

        // Two sessions, 1500 tokens each.
        XCTAssertEqual(history.totalTokens(withinDays: 7), 3000)
        // Opus 4.8: 1000 input * $5/M + 500 output * $25/M = $0.005 + $0.0125, ×2 sessions.
        XCTAssertEqual(history.totalCost(withinDays: 7), 0.035, accuracy: 0.0001)
    }

    func testFailedSessionRecordsItsError() {
        var s = session(id: "boom")
        s.state = .failed
        s.errorMessage = "api_error"
        history.record(s)

        XCTAssertEqual(history.entries.first?.failed, true)
        XCTAssertEqual(history.entries.first?.errorMessage, "api_error")
    }

    func testStoreRetiringASessionLogsItToHistory() {
        let store = SessionStore.shared
        store.removeAll()
        store.upsert(id: "live", agent: .claude, cwd: "/tmp/project") {
            $0.lastPrompt = "build"
            $0.usage = TokenUsage(input: 100, output: 50)
        }

        store.remove(id: "live")

        XCTAssertEqual(history.entries.first?.id, "live")
        store.removeAll()
    }
}
