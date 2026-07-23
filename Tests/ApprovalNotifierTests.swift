import UserNotifications
import XCTest
@testable import QuietVibeStatus

/// Smoke tests for the notification layer.
///
/// The interesting behavior — a banner appearing, an action resolving a request — needs a real user
/// session and a granted authorization, so it can't be asserted here. What these do check is that
/// touching `UNUserNotificationCenter` from this bundle is safe: on an ad-hoc signed app that call
/// is the one that would blow up, and it would take the launch sequence with it.
@MainActor
final class ApprovalNotifierTests: XCTestCase {
    func testStartingRegistersCategoriesWithoutCrashing() async {
        ApprovalNotifier.shared.start()

        let categories = await UNUserNotificationCenter.current().notificationCategories()
        XCTAssertEqual(categories.count, 3)
    }

    func testWithdrawingAnUnknownIdentifierIsHarmless() {
        ApprovalNotifier.shared.withdraw("no-such-request")
    }

    /// Posting must be a no-op — not a crash — when the user has turned banners off.
    func testPostingWithNotificationsOffDoesNothing() {
        let prefs = Preferences.shared
        let original = prefs.approvalNotifications
        defer { prefs.approvalNotifications = original }

        prefs.approvalNotifications = .never
        ApprovalNotifier.shared.post(
            for: ApprovalRequest(
                id: "req-off",
                sessionID: "s-1",
                agent: .claude,
                kind: .permission(tool: "Bash", input: HookFixtures.json(["command": "ls"]))
            ),
            projectName: "project"
        )
    }
}
