import XCTest
@testable import QuietVibeStatus

@MainActor
final class SessionPersistenceTests: XCTestCase {
    private var store: SessionStore { SessionStore.shared }
    private let prefs = Preferences.shared

    override func setUp() async throws {
        try await super.setUp()
        store.removeAll()
        SessionPersistence.clear()
        prefs.restoreSessionsOnLaunch = true
        prefs.directoryFilters = []
    }

    override func tearDown() async throws {
        store.removeAll()
        SessionPersistence.clear()
        try await super.tearDown()
    }

    private var livePID: Int { Int(ProcessInfo.processInfo.processIdentifier) }

    private func session(
        id: String,
        pid: Int?,
        state: SessionState = .working,
        cwd: String = "/tmp/project"
    ) -> Session {
        var session = Session(id: id, agent: .claude, cwd: cwd)
        session.state = state
        session.terminal.pid = pid
        session.model = "Opus 4.8"
        session.lastPrompt = "fix the parser"
        return session
    }

    func testRoundTripsALiveSession() {
        SessionPersistence.save([session(id: "a", pid: livePID)])

        let restored = SessionPersistence.load()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.id, "a")
        XCTAssertEqual(restored.first?.model, "Opus 4.8")
        XCTAssertEqual(restored.first?.lastPrompt, "fix the parser")
        XCTAssertEqual(restored.first?.state, .working)
        XCTAssertEqual(restored.first?.pidIsStable, true)
    }

    /// The point of restoring is agents that outlived the app. A card for a terminal closed days
    /// ago is one the user would have to dismiss by hand for no reason.
    func testSessionsWhoseProcessDiedAreNotRestored() {
        SessionPersistence.save([session(id: "dead", pid: Self.reapedPID())])
        XCTAssertTrue(SessionPersistence.load().isEmpty)
    }

    /// The approval died with the old process, so its buttons would resolve nothing.
    func testBlockedSessionsAreNotSaved() {
        SessionPersistence.save([
            session(id: "blocked", pid: livePID, state: .needsApproval),
            session(id: "working", pid: livePID),
        ])

        XCTAssertEqual(SessionPersistence.load().map(\.id), ["working"])
    }

    func testSessionsWithoutAPIDAreNotSaved() {
        SessionPersistence.save([session(id: "no-pid", pid: nil)])
        XCTAssertTrue(SessionPersistence.load().isEmpty)
    }

    /// Prompts and recaps are the user's own words.
    func testSavedFileIsNotReadableByOtherAccounts() throws {
        SessionPersistence.save([session(id: "a", pid: livePID)])

        let attributes = try FileManager.default.attributesOfItem(atPath: SessionPersistence.url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testCorruptFileIsIgnoredRatherThanCrashing() throws {
        try FileManager.default.createDirectory(
            at: SessionPersistence.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json at all".utf8).write(to: SessionPersistence.url)

        XCTAssertTrue(SessionPersistence.load().isEmpty)
    }

    // MARK: - Store integration

    func testRestorePutsCardsBackOnScreen() {
        SessionPersistence.save([session(id: "a", pid: livePID)])

        store.restore()
        XCTAssertEqual(store.sessions.map(\.id), ["a"])
    }

    /// A hook arriving right after launch must update the restored card, not duplicate it.
    func testRestoredSessionIsUpdatedNotDuplicatedByTheNextEvent() {
        SessionPersistence.save([session(id: "a", pid: livePID)])
        store.restore()

        store.upsert(id: "a", agent: .claude, cwd: "/tmp/project") { $0.state = .complete }

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.session(id: "a")?.state, .complete)
    }

    func testRestoreSkipsSessionsTheUserArchived() {
        SessionPersistence.save([session(id: "a", pid: livePID)])
        store.upsert(id: "a", agent: .claude, cwd: "/tmp/project") { $0.state = .working }
        store.archive(id: "a")
        store.removeAll()

        // `removeAll` clears the archive, so re-archive to model a dismissal that outlived a quit.
        store.upsert(id: "a", agent: .claude, cwd: "/tmp/project") { $0.state = .working }
        store.archive(id: "a")

        store.restore()
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testRestoreHonorsDirectoryFilters() {
        SessionPersistence.save([session(id: "a", pid: livePID, cwd: "/tmp/secret/work")])
        prefs.directoryFilters = ["/secret"]

        store.restore()
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testDisablingRestoreDeletesTheSavedFile() {
        SessionPersistence.save([session(id: "a", pid: livePID)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: SessionPersistence.url.path))

        prefs.restoreSessionsOnLaunch = false
        store.restore()

        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SessionPersistence.url.path))
        prefs.restoreSessionsOnLaunch = true
    }

    func testRestoreDoesNothingWhenSessionsAreAlreadyLoaded() {
        SessionPersistence.save([session(id: "a", pid: livePID)])
        store.upsert(id: "b", agent: .claude, cwd: "/tmp/project") { $0.state = .working }

        store.restore()
        XCTAssertEqual(store.sessions.map(\.id), ["b"])
    }

    private static func reapedPID() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? process.run()
        process.waitUntilExit()
        return Int(process.processIdentifier)
    }
}
