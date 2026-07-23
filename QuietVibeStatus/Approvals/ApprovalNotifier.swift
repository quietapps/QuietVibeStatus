import AppKit
import UserNotifications

/// Puts blocking requests in Notification Center, with the decision buttons on the banner itself.
///
/// The notch is the right place to answer when you can see it. In fullscreen the panel hides by
/// default, and on a multi-display desk it may be sitting on a screen you aren't looking at — in
/// both cases an agent can block for minutes on a card nobody is going to see. A banner reaches you
/// anywhere, and answering from it resolves the same registry entry the card would have.
///
/// Notifications are advisory: every one of them can be ignored and answered in the panel or the
/// terminal instead, and none of them decides anything on its own.
@MainActor
final class ApprovalNotifier: NSObject, ObservableObject {
    static let shared = ApprovalNotifier()

    /// Whether the system has granted us permission to post at all.
    @Published private(set) var isAuthorized = false

    private let center = UNUserNotificationCenter.current()
    private let prefs = Preferences.shared
    private var authorizationAsked = false

    private enum Category {
        static let permission = "app.quiet.qvs.permission"
        static let plan = "app.quiet.qvs.plan"
        static let question = "app.quiet.qvs.question"
    }

    private enum Action {
        static let allow = "allow"
        static let allowAlways = "allow-always"
        static let deny = "deny"
        static let approvePlan = "approve-plan"
        static let rejectPlan = "reject-plan"
        static let open = "open-panel"
    }

    private override init() {
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        center.delegate = self
        center.setNotificationCategories(categories())
        refreshAuthorization()
    }

    private func categories() -> Set<UNNotificationCategory> {
        // Actions are background actions on purpose: answering must not pull a menu bar app to the
        // front and take focus off whatever you were typing in.
        let permission = UNNotificationCategory(
            identifier: Category.permission,
            actions: [
                UNNotificationAction(identifier: Action.allow, title: "Allow", options: []),
                UNNotificationAction(
                    identifier: Action.allowAlways,
                    title: "Always allow",
                    options: []
                ),
                UNNotificationAction(
                    identifier: Action.deny,
                    title: "Deny",
                    options: [.destructive]
                ),
            ],
            intentIdentifiers: [],
            options: []
        )

        let plan = UNNotificationCategory(
            identifier: Category.plan,
            actions: [
                UNNotificationAction(identifier: Action.approvePlan, title: "Approve", options: []),
                UNNotificationAction(
                    identifier: Action.rejectPlan,
                    title: "Reject",
                    options: [.destructive]
                ),
            ],
            intentIdentifiers: [],
            options: []
        )

        // A question has its own options and free-text answers — there is nothing honest to put on a
        // banner, so this one only offers to open the panel where it can be answered properly.
        let question = UNNotificationCategory(
            identifier: Category.question,
            actions: [
                UNNotificationAction(
                    identifier: Action.open,
                    title: "Open panel",
                    options: [.foreground]
                ),
            ],
            intentIdentifiers: [],
            options: []
        )

        return [permission, plan, question]
    }

    func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.isAuthorized = settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
            }
        }
    }

    /// Asks for permission once, the first time we actually have something to post.
    ///
    /// Prompting at launch asks for something the user hasn't seen the value of yet; prompting when
    /// the first agent blocks explains itself.
    func requestAuthorizationIfNeeded() {
        guard !authorizationAsked, prefs.approvalNotifications != .never else { return }
        authorizationAsked = true
        center.requestAuthorization(options: [.alert]) { [weak self] granted, error in
            if let error {
                Log.approvals.error("notification authorization failed: \(error.localizedDescription)")
            }
            Task { @MainActor in self?.isAuthorized = granted }
        }
    }

    // MARK: - Posting

    func post(for request: ApprovalRequest, projectName: String?) {
        guard shouldPost() else { return }
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = headline(for: request)
        if let projectName { content.subtitle = projectName }
        content.body = body(for: request)
        content.categoryIdentifier = category(for: request)
        content.userInfo = ["requestID": request.id, "sessionID": request.sessionID]
        // Sound belongs to SoundEngine, which already has quiet hours and per-event assignments.
        content.sound = nil

        let notification = UNNotificationRequest(
            identifier: request.id,
            content: content,
            trigger: nil
        )
        center.add(notification) { error in
            guard let error else { return }
            Log.approvals.error("notification post failed: \(error.localizedDescription)")
        }
    }

    /// Pull a banner once its request is settled, wherever it was settled.
    func withdraw(_ requestID: String) {
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
    }

    private func shouldPost() -> Bool {
        // Quiet scenes mean quiet: a banner during a screen share is the one place a pending
        // approval must not appear.
        guard !QuietScenes.shared.isQuiet else { return false }

        switch prefs.approvalNotifications {
        case .never: return false
        case .always: return true
        case .whenPanelHidden: return !NotchController.shared.panelIsVisible
        }
    }

    private func headline(for request: ApprovalRequest) -> String {
        switch request.kind {
        case let .permission(tool, _): return "\(tool) needs permission"
        case .planReview: return "Plan needs review"
        case .question: return "Agent has a question"
        }
    }

    private func body(for request: ApprovalRequest) -> String {
        switch request.kind {
        case let .permission(tool, input):
            let detail = ActivityFormatter.describe(tool: tool, input: input)
            return detail.isEmpty ? tool : detail
        case let .planReview(plan):
            return String(plan.prefix(200))
        case let .question(set):
            return set.items.first?.question ?? "Open the panel to answer"
        }
    }

    private func category(for request: ApprovalRequest) -> String {
        switch request.kind {
        case .permission: return Category.permission
        case .planReview: return Category.plan
        case .question: return Category.question
        }
    }
}

extension ApprovalNotifier: UNUserNotificationCenterDelegate {
    /// Show the banner even when this app is frontmost — "frontmost" for a menu bar accessory means
    /// its Settings window is open, which is not where approvals are answered.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let requestID = response.notification.request.content.userInfo["requestID"] as? String
        let actionID = response.actionIdentifier

        Task { @MainActor in
            defer { completionHandler() }
            guard let requestID else { return }

            switch actionID {
            case Action.allow:
                PendingRequestRegistry.shared.resolve(requestID, with: .allow)
            case Action.allowAlways:
                PendingRequestRegistry.shared.resolve(requestID, with: .allowAlways)
            case Action.deny:
                PendingRequestRegistry.shared.resolve(requestID, with: .deny(reason: nil))
            case Action.approvePlan:
                PendingRequestRegistry.shared.resolve(requestID, with: .approvePlan(autoMode: false))
            case Action.rejectPlan:
                PendingRequestRegistry.shared.resolve(requestID, with: .rejectPlan(feedback: ""))
            default:
                // Tapping the banner body, or "Open panel": show the request rather than answer it.
                NotchController.shared.revealTemporarily()
            }
        }
    }
}
