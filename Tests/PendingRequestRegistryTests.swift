import XCTest
@testable import QuietVibeStatus

@MainActor
final class PendingRequestRegistryTests: XCTestCase {
    private var registry: PendingRequestRegistry { PendingRequestRegistry.shared }
    private let prefs = Preferences.shared

    override func setUp() async throws {
        try await super.setUp()
        registry.cancelAll()
        prefs.approvalTimeoutMinutes = 0
    }

    override func tearDown() async throws {
        registry.cancelAll()
        prefs.approvalTimeoutMinutes = 15
        try await super.tearDown()
    }

    private func request(id: String = "req-1", session: String = "s-1") -> ApprovalRequest {
        ApprovalRequest(
            id: id,
            sessionID: session,
            agent: .claude,
            kind: .permission(tool: "Bash", input: HookFixtures.json(["command": "ls"]))
        )
    }

    private func question(id: String, session: String = "s-1") -> ApprovalRequest {
        ApprovalRequest(
            id: id,
            sessionID: session,
            agent: .claude,
            kind: .question(QuestionSet(items: [], rawInput: HookFixtures.json([:])))
        )
    }

    // MARK: - Settled elsewhere

    /// The agent reporting that a tool ran means the same prompt was answered in its own terminal,
    /// so the card asking about that call is stale and must go.
    func testACompletedToolClearsItsPendingCard() async {
        let parked = Task { await registry.park(request()) }
        await waitForPending(count: 1)

        registry.settleExternally(
            sessionID: "s-1",
            tool: "Bash",
            input: HookFixtures.json(["command": "ls"])
        )

        let outcome = await parked.value
        if case .defer_ = outcome {} else { XCTFail("expected .defer_, got \(outcome)") }
        XCTAssertTrue(registry.requests.isEmpty)
    }

    /// A different command finishing says nothing about the one still being asked about.
    func testADifferentToolCallLeavesTheCardAlone() async {
        let parked = Task { await registry.park(request()) }
        await waitForPending(count: 1)

        registry.settleExternally(
            sessionID: "s-1",
            tool: "Bash",
            input: HookFixtures.json(["command": "rm -rf /"])
        )
        registry.settleExternally(
            sessionID: "s-2",
            tool: "Bash",
            input: HookFixtures.json(["command": "ls"])
        )

        XCTAssertEqual(registry.requests.map(\.id), ["req-1"])
        registry.resolve("req-1", with: .allow)
        _ = await parked.value
    }

    /// Two identical calls in flight: one completion clears one card, not both.
    func testIdenticalCallsClearOneAtATime() async {
        let first = Task { await registry.park(request(id: "req-1")) }
        let second = Task { await registry.park(request(id: "req-2")) }
        await waitForPending(count: 2)

        registry.settleExternally(
            sessionID: "s-1",
            tool: "Bash",
            input: HookFixtures.json(["command": "ls"])
        )
        _ = await first.value

        XCTAssertEqual(registry.requests.map(\.id), ["req-2"])
        registry.resolve("req-2", with: .allow)
        _ = await second.value
    }

    // MARK: - Batch

    func testAllowAllResolvesEveryPermissionInTheSession() async {
        let first = Task { await registry.park(request(id: "req-1")) }
        let second = Task { await registry.park(request(id: "req-2")) }
        await waitForPending(count: 2)

        registry.resolveAll(sessionID: "s-1", with: .allow)

        for outcome in await [first.value, second.value] {
            if case .allow = outcome {} else { XCTFail("expected .allow, got \(outcome)") }
        }
        XCTAssertTrue(registry.requests.isEmpty)
    }

    /// A batch must not reach into another agent's queue.
    func testBatchIsScopedToOneSession() async {
        let mine = Task { await registry.park(request(id: "req-1", session: "s-1")) }
        let other = Task { await registry.park(request(id: "req-2", session: "s-2")) }
        await waitForPending(count: 2)

        registry.resolveAll(sessionID: "s-1", with: .allow)
        _ = await mine.value

        XCTAssertEqual(registry.requests.map(\.id), ["req-2"])
        registry.resolve("req-2", with: .allow)
        _ = await other.value
    }

    /// Questions and plans each need their own answer, so a batch leaves them alone.
    func testBatchSkipsQuestions() async {
        let permission = Task { await registry.park(request(id: "req-1")) }
        let asked = Task { await registry.park(question(id: "req-2")) }
        await waitForPending(count: 2)

        XCTAssertEqual(registry.batchablePermissions(for: "s-1").map(\.id), ["req-1"])

        registry.resolveAll(sessionID: "s-1", with: .allow)
        _ = await permission.value

        XCTAssertEqual(registry.requests.map(\.id), ["req-2"])
        registry.resolve("req-2", with: .defer_)
        _ = await asked.value
    }

    func testParkedRequestResumesWithTheUsersOutcome() async {
        let parked = Task { await registry.park(request()) }
        await waitForPending(count: 1)

        registry.resolve("req-1", with: .allow)
        let outcome = await parked.value

        if case .allow = outcome {} else { XCTFail("expected .allow, got \(outcome)") }
        XCTAssertTrue(registry.requests.isEmpty)
    }

    func testCancellingASessionReleasesItsWaiter() async {
        let parked = Task { await registry.park(request()) }
        await waitForPending(count: 1)

        registry.cancel(sessionID: "s-1")
        let outcome = await parked.value

        if case .defer_ = outcome {} else { XCTFail("expected .defer_, got \(outcome)") }
    }

    /// An unanswered card holds the agent's hook open. After the configured wait the hook must be
    /// released as `.defer_` so the agent falls back to its own prompt rather than blocking all day.
    func testUnansweredRequestTimesOutAsDeferred() async {
        // 0.05 minutes = 3s, short enough for a test and still exercising the real timer path.
        prefs.approvalTimeoutMinutes = 0.05

        let started = Date()
        let outcome = await registry.park(request())

        if case .defer_ = outcome {} else { XCTFail("expected .defer_, got \(outcome)") }
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 2.5)
        XCTAssertTrue(registry.requests.isEmpty, "the card must clear when the hook is released")
    }

    /// Answering before the deadline must not leave a timer that fires into a resolved request.
    func testResolvingCancelsThePendingTimeout() async {
        prefs.approvalTimeoutMinutes = 0.05

        let parked = Task { await registry.park(request()) }
        await waitForPending(count: 1)
        registry.resolve("req-1", with: .allow)
        _ = await parked.value

        // Park a second request with timeouts disabled; if the first timer were still alive it
        // would resolve nothing, but a stale entry would show up here.
        prefs.approvalTimeoutMinutes = 0
        let second = Task { await registry.park(request(id: "req-2")) }
        await waitForPending(count: 1)

        try? await Task.sleep(for: .seconds(4))
        XCTAssertEqual(registry.requests.map(\.id), ["req-2"])

        registry.resolve("req-2", with: .allow)
        _ = await second.value
    }

    /// Cancelling the task that awaits a card must take the card with it.
    ///
    /// Nothing in the bridge cancels today — 1.0.8 tried to, from socket EOF, and had to be reverted
    /// because `nc` half-closes on every request and EOF therefore means nothing. This stays as the
    /// contract any future canceller has to meet: release the hook, decide nothing, drop the card.
    func testCancellingAParkedRequestClearsTheCard() async {
        prefs.approvalTimeoutMinutes = 0

        let parked = Task { await registry.park(request()) }
        await waitForPending(count: 1)

        parked.cancel()
        let outcome = await parked.value

        if case .defer_ = outcome {} else { XCTFail("expected .defer_, got \(outcome)") }
        await waitForPending(count: 0)
    }

    /// Abandoning a request that was already answered must not resume its continuation twice.
    func testAbandonAfterResolveIsIgnored() async {
        prefs.approvalTimeoutMinutes = 0

        let parked = Task { await registry.park(request()) }
        await waitForPending(count: 1)

        registry.resolve("req-1", with: .allow)
        registry.abandon("req-1")

        let outcome = await parked.value
        if case .allow = outcome {} else { XCTFail("expected .allow, got \(outcome)") }
    }

    func testTimeoutOfZeroWaitsIndefinitely() async {
        prefs.approvalTimeoutMinutes = 0

        let parked = Task { await registry.park(request()) }
        await waitForPending(count: 1)

        try? await Task.sleep(for: .seconds(1))
        XCTAssertEqual(registry.requests.count, 1)

        registry.resolve("req-1", with: .allow)
        _ = await parked.value
    }

    private func waitForPending(count: Int, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while registry.requests.count != count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(registry.requests.count, count)
    }
}
