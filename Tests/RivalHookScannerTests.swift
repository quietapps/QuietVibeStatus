import XCTest
@testable import QuietVibeStatus

final class RivalHookScannerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qvs-scanner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func integration(named file: String, contents: String, style: HookEntryStyle = .nested) throws -> Integration {
        let url = directory.appendingPathComponent(file)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return Integration(
            id: "test",
            agent: .claude,
            displayName: "Test",
            configPath: url.path,
            hooksKeyPath: ["hooks"],
            events: [("SessionStart", 5)],
            detectPaths: [url.path],
            entryStyle: style
        )
    }

    /// The exact shape a stale Vibe Island install leaves behind next to ours.
    func testFindsARivalAlongsideOurOwnHooks() throws {
        let config = """
        {
          "hooks": {
            "SessionStart": [
              { "hooks": [{ "type": "command", "command": "$HOME/.vibe-island/bin/vibe-island-bridge --source claude" }] },
              { "hooks": [{ "type": "command", "command": "'/Users/me/.quietvibestatus/bin/quiet-vibe-bridge' --source claude" }] }
            ],
            "Stop": [
              { "hooks": [{ "type": "command", "command": "$HOME/.vibe-island/bin/vibe-island-bridge --source claude" }] }
            ]
          }
        }
        """

        let found = RivalHookScanner.scan(try integration(named: "settings.json", contents: config))

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.displayName, "Vibe Island")
        XCTAssertEqual(found.first?.events, ["SessionStart", "Stop"])
    }

    /// Cursor lists commands flat under the event name rather than nesting them.
    func testFindsRivalsInTheFlatEntryShape() throws {
        let config = """
        {
          "hooks": {
            "beforeSubmitPrompt": [
              { "command": "/Users/me/.vibe-island/bin/vibe-island-bridge --source cursor" }
            ]
          }
        }
        """

        let found = RivalHookScanner.scan(
            try integration(named: "hooks.json", contents: config, style: .flat)
        )
        XCTAssertEqual(found.first?.events, ["beforeSubmitPrompt"])
    }

    func testOurOwnHooksAreNeverReportedAsRivals() throws {
        let config = """
        {
          "hooks": {
            "SessionStart": [
              { "hooks": [{ "command": "'/Users/me/.quietvibestatus/bin/quiet-vibe-bridge' --source claude" }] }
            ]
          }
        }
        """

        XCTAssertTrue(RivalHookScanner.scan(try integration(named: "settings.json", contents: config)).isEmpty)
    }

    /// A user's own hook must never be offered up for deletion just because it mentions an agent.
    func testUnrelatedUserHooksAreLeftAlone() throws {
        let config = """
        {
          "hooks": {
            "SessionStart": [
              { "hooks": [{ "command": "node /Users/me/.claude/hooks/my-notifier.js" }] },
              { "hooks": [{ "command": "say 'claude started'" }] }
            ]
          }
        }
        """

        XCTAssertTrue(RivalHookScanner.scan(try integration(named: "settings.json", contents: config)).isEmpty)
    }

    /// Several agent configs accept comments, which `JSONSerialization` cannot parse directly.
    func testReadsConfigsContainingComments() throws {
        let config = """
        {
          // installed by another notch app
          "hooks": {
            "Stop": [
              { "hooks": [{ "command": "/opt/notchnook/bridge --source claude" }] }
            ]
          }
        }
        """

        let found = RivalHookScanner.scan(try integration(named: "settings.json", contents: config))
        XCTAssertEqual(found.first?.displayName, "NotchNook")
    }

    func testMissingOrEmptyConfigIsNotAnError() throws {
        let missing = Integration(
            id: "test",
            agent: .claude,
            displayName: "Test",
            configPath: directory.appendingPathComponent("nope.json").path,
            hooksKeyPath: ["hooks"],
            events: [],
            detectPaths: []
        )
        XCTAssertTrue(RivalHookScanner.scan(missing).isEmpty)
        XCTAssertTrue(RivalHookScanner.scan(try integration(named: "empty.json", contents: "")).isEmpty)
    }

    func testCommandsAreReadFromBothEntryShapes() {
        XCTAssertEqual(RivalHookScanner.commands(in: ["command": "a"]), ["a"])
        XCTAssertEqual(
            RivalHookScanner.commands(in: ["hooks": [["command": "b"], ["command": "c"]]]),
            ["b", "c"]
        )
        XCTAssertTrue(RivalHookScanner.commands(in: ["matcher": "*"]).isEmpty)
    }
}
