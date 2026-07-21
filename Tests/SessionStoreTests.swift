import XCTest
@testable import QuietVibeStatus

@MainActor
final class SessionStoreTests: XCTestCase {
    private var store: SessionStore { SessionStore.shared }
    private let prefs = Preferences.shared

    override func setUp() async throws {
        try await super.setUp()
        store.removeAll()
        prefs.directoryFilters = []
        prefs.promptFilters = []
        prefs.promptFilterMatchType = "prefix"
        prefs.filterCodexInternalWorkers = true
    }

    override func tearDown() async throws {
        store.removeAll()
        try await super.tearDown()
    }

    // MARK: - Upsert

    func testUpsertCreatesThenUpdatesTheSameSession() {
        store.upsert(id: "a", agent: .claude, cwd: "/tmp/one") { $0.state = .working }
        store.upsert(id: "a", agent: .claude, cwd: "/tmp/one") { $0.state = .complete }

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.session(id: "a")?.state, .complete)
    }

    func testArchivedSessionsAreNotRecreatedByLaterEvents() {
        store.upsert(id: "a", agent: .claude, cwd: "/tmp/one") { $0.state = .working }
        store.archive(id: "a")

        store.upsert(id: "a", agent: .claude, cwd: "/tmp/one") { $0.state = .working }
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testSessionEndClearsTheArchiveEntry() {
        store.upsert(id: "a", agent: .claude, cwd: "/tmp/one") { $0.state = .working }
        store.archive(id: "a")
        store.sessionDidEnd(id: "a")

        store.upsert(id: "a", agent: .claude, cwd: "/tmp/one") { $0.state = .working }
        XCTAssertEqual(store.sessions.count, 1)
    }

    // MARK: - Filters

    func testDirectoryFilterBlocksCreation() {
        prefs.directoryFilters = ["/scratch"]
        store.upsert(id: "a", agent: .claude, cwd: "/tmp/scratch/work") { $0.state = .working }
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testPresetDirectoryFilterBlocksAgentInternalWorkers() {
        store.upsert(id: "a", agent: .codex, cwd: "/Users/x/.codex/memories") { $0.state = .working }
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testPromptFilterBlocksCreation() {
        prefs.promptFilters = ["## Internal"]
        store.upsert(id: "a", agent: .claude, cwd: "/tmp/one") {
            $0.lastPrompt = "## Internal task runner"
        }
        XCTAssertTrue(store.sessions.isEmpty)
    }

    /// Regression: helper sessions send `SessionStart` before their prompt exists, so the filter
    /// cannot judge them at creation time. The card must disappear once the prompt arrives.
    func testPromptFilterAlsoRemovesAnAlreadyCreatedSession() {
        store.upsert(id: "helper", agent: .claude, cwd: "/tmp/one") { $0.state = .idle }
        XCTAssertEqual(store.sessions.count, 1)

        let result = store.upsert(id: "helper", agent: .claude, cwd: "/tmp/one") {
            $0.lastPrompt = "What topic or task is this about? Give a short descriptive title"
        }

        XCTAssertNil(result, "a filtered session must report that it no longer exists")
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testPrefixMatchDoesNotFireOnMidPromptText() {
        prefs.promptFilters = ["Generate"]
        prefs.promptFilterMatchType = "prefix"

        store.upsert(id: "a", agent: .claude, cwd: "/tmp/one") {
            $0.lastPrompt = "Please Generate a summary"
        }
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testContainsMatchFiresAnywhereInThePrompt() {
        prefs.promptFilters = ["Generate"]
        prefs.promptFilterMatchType = "contains"

        store.upsert(id: "a", agent: .claude, cwd: "/tmp/one") {
            $0.lastPrompt = "Please Generate a summary"
        }
        XCTAssertTrue(store.sessions.isEmpty)
    }

    // MARK: - Ordering

    func testBlockedSessionsSortAboveWorkingOnes() {
        store.upsert(id: "working", agent: .claude, cwd: "/tmp/one") { $0.state = .working }
        store.upsert(id: "blocked", agent: .claude, cwd: "/tmp/two") { $0.state = .needsApproval }
        store.upsert(id: "idle", agent: .claude, cwd: "/tmp/three") { $0.state = .idle }

        XCTAssertEqual(store.visibleSessions.map(\.id), ["blocked", "working", "idle"])
        XCTAssertEqual(store.blockedSessions.map(\.id), ["blocked"])
    }

    func testSubagentSessionsAreHiddenFromTheTopLevelList() {
        store.upsert(id: "parent", agent: .claude, cwd: "/tmp/one") { $0.state = .working }
        store.upsert(id: "child", agent: .claude, cwd: "/tmp/one") { $0.parentID = "parent" }

        XCTAssertEqual(store.visibleSessions.map(\.id), ["parent"])
    }

    // MARK: - Subagents

    func testSubagentsAreTrackedAndDeduplicated() {
        store.upsert(id: "a", agent: .claude, cwd: "/tmp/one") { $0.state = .working }
        store.startSubagent(sessionID: "a", agentID: "sub-1", type: "Explore")
        store.startSubagent(sessionID: "a", agentID: "sub-1", type: "Explore")

        XCTAssertEqual(store.session(id: "a")?.subagents.count, 1)
        XCTAssertEqual(store.session(id: "a")?.runningSubagents.count, 1)

        store.finishSubagent(sessionID: "a", agentID: "sub-1")
        XCTAssertEqual(store.session(id: "a")?.runningSubagents.count, 0)
    }

    // MARK: - Liveness

    /// A pid that has been seen twice is trusted, so a dead one retires the card. This is what
    /// clears sessions whose terminal was closed without ever sending `SessionEnd`.
    func testDeadAgentProcessRetiresTheSession() {
        let deadPID = Self.reapedPID()

        store.upsert(id: "a", agent: .claude, cwd: "/tmp/one") { $0.terminal.pid = deadPID }
        store.upsert(id: "a", agent: .claude, cwd: "/tmp/one") { $0.terminal.pid = deadPID }
        XCTAssertEqual(store.session(id: "a")?.pidIsStable, true)

        store.pruneDeadSessions()
        XCTAssertTrue(store.sessions.isEmpty)
    }

    /// Some CLIs run hooks through a throwaway shell whose pid dies immediately and differs every
    /// event. Culling on that would delete cards for sessions that are very much alive.
    func testUnstablePIDIsNeverTreatedAsProofOfDeath() {
        store.upsert(id: "a", agent: .codex, cwd: "/tmp/one") { $0.terminal.pid = Self.reapedPID() }
        store.upsert(id: "a", agent: .codex, cwd: "/tmp/one") { $0.terminal.pid = Self.reapedPID() + 1 }

        XCTAssertEqual(store.session(id: "a")?.pidIsStable, false)
        store.pruneDeadSessions()
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testLiveProcessSurvivesTheSweep() {
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)

        store.upsert(id: "a", agent: .claude, cwd: "/tmp/one") { $0.terminal.pid = ownPID }
        store.upsert(id: "a", agent: .claude, cwd: "/tmp/one") { $0.terminal.pid = ownPID }

        store.pruneDeadSessions()
        XCTAssertEqual(store.sessions.count, 1)
    }

    /// A pid that exited and was reaped, so it is genuinely absent rather than a zombie.
    private static func reapedPID() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? process.run()
        process.waitUntilExit()
        return Int(process.processIdentifier)
    }
}
