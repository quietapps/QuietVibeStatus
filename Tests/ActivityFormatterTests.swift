import XCTest
@testable import QuietVibeStatus

final class ActivityFormatterTests: XCTestCase {
    func testDescribesCommonTools() {
        let bash = ActivityFormatter.describe(
            tool: "Bash",
            input: HookFixtures.json(["command": "npm test --watch"])
        )
        XCTAssertEqual(bash, "Running npm test --watch")

        let read = ActivityFormatter.describe(
            tool: "Read",
            input: HookFixtures.json(["file_path": "/a/b/SessionStore.swift"])
        )
        XCTAssertEqual(read, "Reading SessionStore.swift")

        let fetch = ActivityFormatter.describe(
            tool: "WebFetch",
            input: HookFixtures.json(["url": "https://docs.example.com/page?q=1"])
        )
        XCTAssertEqual(fetch, "Fetching docs.example.com")
    }

    /// Multi-line commands would otherwise blow the card's single line apart.
    func testBashUsesOnlyTheFirstLine() {
        let activity = ActivityFormatter.describe(
            tool: "Bash",
            input: HookFixtures.json(["command": "cd /tmp\nrm -rf build\nmake"])
        )
        XCTAssertEqual(activity, "Running cd /tmp")
    }

    func testLongCommandIsTruncatedWithEllipsis() {
        let command = String(repeating: "x", count: 200)
        let activity = ActivityFormatter.describe(
            tool: "Bash",
            input: HookFixtures.json(["command": command])
        )
        XCTAssertEqual(activity.count, "Running ".count + 48)
        XCTAssertTrue(activity.hasSuffix("…"))
    }

    func testMCPToolsCollapseToTheirLeafName() {
        let activity = ActivityFormatter.describe(
            tool: "mcp__linear__create_issue",
            input: .null
        )
        XCTAssertEqual(activity, "MCP: issue")
    }

    func testUnknownToolFallsBackToItsName() {
        XCTAssertEqual(ActivityFormatter.describe(tool: "Sparkle", input: .null), "Sparkle")
    }

    func testMissingFieldsDoNotProduceEmptyLabels() {
        XCTAssertEqual(ActivityFormatter.describe(tool: "Read", input: .null), "Reading file")
        XCTAssertEqual(ActivityFormatter.describe(tool: "WebFetch", input: .null), "Fetching page")
    }

    func testModelLabelsAreHumanReadable() {
        XCTAssertEqual(ActivityFormatter.modelLabel("claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(ActivityFormatter.modelLabel("claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(ActivityFormatter.modelLabel("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ActivityFormatter.modelLabel("claude-fable-5"), "Fable 5")
    }

    func testModelLabelHandlesUnknownAndEmptyInput() {
        XCTAssertNil(ActivityFormatter.modelLabel(nil))
        XCTAssertNil(ActivityFormatter.modelLabel(""))
        XCTAssertEqual(ActivityFormatter.modelLabel("llama-3"), "llama-3")

        let long = "some-extremely-long-model-identifier"
        XCTAssertEqual(ActivityFormatter.modelLabel(long)?.count, 18)
    }
}
