import XCTest
@testable import QuietVibeStatus

final class PermissionRuleTests: XCTestCase {
    /// "Always allow" on one npm script must not hand over every npm invocation.
    func testBashRuleIsScopedToTheCommandHead() {
        let rule = PermissionRule.forAlwaysAllow(
            tool: "Bash",
            input: HookFixtures.json(["command": "npm test --watch --coverage"])
        )
        XCTAssertEqual(rule, "Bash(npm test:*)")
    }

    func testSingleWordBashCommandStillScopes() {
        let rule = PermissionRule.forAlwaysAllow(
            tool: "Bash",
            input: HookFixtures.json(["command": "ls"])
        )
        XCTAssertEqual(rule, "Bash(ls:*)")
    }

    /// An empty command would produce `Bash(:*)`, which is not a rule any agent understands.
    func testEmptyBashCommandFallsBackToTheBareTool() {
        let rule = PermissionRule.forAlwaysAllow(
            tool: "Bash",
            input: HookFixtures.json(["command": ""])
        )
        XCTAssertEqual(rule, "Bash")
    }

    func testNonBashToolsUseTheirOwnName() {
        for tool in ["Read", "Edit", "Write", "WebFetch"] {
            XCTAssertEqual(
                PermissionRule.forAlwaysAllow(tool: tool, input: .null),
                tool
            )
        }
    }
}
