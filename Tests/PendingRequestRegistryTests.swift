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
