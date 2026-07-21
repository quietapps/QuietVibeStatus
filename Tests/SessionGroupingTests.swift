import XCTest
@testable import QuietVibeStatus

@MainActor
final class SessionGroupingTests: XCTestCase {
    private var store: SessionStore { SessionStore.shared }

    override func setUp() async throws {
        try await super.setUp()
        store.removeAll()
        Preferences.shared.directoryFilters = []
    }

    override func tearDown() async throws {
        store.removeAll()
        try await super.tearDown()
    }

    func testSessionsBucketByDirectory() {
        store.upsert(id: "a1", agent: .claude, cwd: "/tmp/alpha") { $0.state = .working }
        store.upsert(id: "b1", agent: .claude, cwd: "/tmp/beta") { $0.state = .working }
        store.upsert(id: "a2", agent: .claude, cwd: "/tmp/alpha") { $0.state = .working }

        let groups = store.groupedSessions
        XCTAssertEqual(groups.count, 2)

        let alpha = groups.first { $0.cwd == "/tmp/alpha" }
        XCTAssertEqual(alpha?.sessions.map(\.id).sorted(), ["a1", "a2"])
        XCTAssertEqual(alpha?.name, "alpha")
    }

    /// Group order follows the panel sort — the project holding the most urgent session leads.
    func testGroupOrderFollowsUrgency() {
        store.upsert(id: "working", agent: .claude, cwd: "/tmp/busy") { $0.state = .working }
        store.upsert(id: "blocked", agent: .claude, cwd: "/tmp/waiting") { $0.state = .needsApproval }

        XCTAssertEqual(store.groupedSessions.first?.cwd, "/tmp/waiting")
    }

    func testEveryVisibleSessionLandsInExactlyOneGroup() {
        for i in 0 ..< 5 {
            store.upsert(id: "s\(i)", agent: .claude, cwd: "/tmp/dir\(i % 2)") { $0.state = .working }
        }

        let grouped = store.groupedSessions.flatMap(\.sessions).map(\.id).sorted()
        XCTAssertEqual(grouped, store.visibleSessions.map(\.id).sorted())
    }
}
