import Combine
import SwiftUI

/// Every user-facing setting, in one observable object backed by `UserDefaults`.
///
/// Settings panes bind directly to these properties; the rest of the app reads them. Defaults here
/// are the shipping defaults — they should match what a fresh install shows in Settings.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    /// Tests run inside the app as their host, so writing to the standard defaults would edit the
    /// settings of the copy the user actually runs. They get a throwaway suite instead.
    private let defaults: UserDefaults = {
        guard AppDelegate.isRunningTests else { return .standard }
        let suite = UserDefaults(suiteName: "app.quiet.QuietVibeStatus.tests") ?? .standard
        suite.removePersistentDomain(forName: "app.quiet.QuietVibeStatus.tests")
        return suite
    }()

    private init() {}

    // MARK: General — expansion

    @Stored("expandOnHover", default: true) var expandOnHover: Bool
    @Stored("hoverDuration", default: 0.15) var hoverDuration: Double
    /// Don't auto-expand when the agent's own terminal tab is already frontmost.
    @Stored("smartSuppression", default: true) var smartSuppression: Bool

    // MARK: General — visibility

    @Stored("hideInFullscreen", default: true) var hideInFullscreen: Bool
    @Stored("autoHideWhenEmpty", default: false) var autoHideWhenEmpty: Bool

    // MARK: General — dismissal

    @Stored("autoCollapseOnMouseLeave", default: true) var autoCollapseOnMouseLeave: Bool
    /// How long a completion/warning reveal stays open, in seconds. `0` keeps it open until it is
    /// dismissed.
    ///
    /// Five seconds was too short to read what a finished agent had actually done — the panel was
    /// gone before you had looked away from your editor.
    @Stored("autoRevealDwell", default: 12.0) var autoRevealDwell: Double
    @Stored("dismissRevealOnOutsideClick", default: false) var dismissRevealOnOutsideClick: Bool
    /// Seconds before a session with no clear close signal is cleaned up.
    @Stored("idleCleanupSeconds", default: 7200.0) var idleCleanupSeconds: Double
    /// Whether live session cards survive a restart of the app.
    ///
    /// Agents keep running while the app is quit or updated, so without this the panel comes back
    /// empty. Turning it off also deletes the saved file, which is the setting to use if you would
    /// rather no prompt text ever touched the disk.
    @Stored("restoreSessionsOnLaunch", default: true) var restoreSessionsOnLaunch: Bool
    /// Whether finished sessions are logged for later review.
    @Stored("keepSessionHistory", default: true) var keepSessionHistory: Bool

    // MARK: General — interaction

    @Stored("disableClickToJump", default: false) var disableClickToJump: Bool
    /// Minutes an unanswered approval holds the agent's hook open before it is handed back to the
    /// agent's own prompt. `0` waits forever, which is what the hook timeout allows but also means
    /// a card you never saw can block an agent all day.
    @Stored("approvalTimeoutMinutes", default: 15.0) var approvalTimeoutMinutes: Double

    // MARK: Notifications

    @Stored("expandForCompletions", default: true) var expandForCompletions: Bool
    @Stored("subagentNotifications", default: SubagentNotificationPolicy.withMainAgent.rawValue)
    var subagentNotificationsRaw: String

    var subagentNotifications: SubagentNotificationPolicy {
        get { SubagentNotificationPolicy(rawValue: subagentNotificationsRaw) ?? .withMainAgent }
        set { subagentNotificationsRaw = newValue.rawValue }
    }

    /// Banner notifications for requests that are blocking an agent.
    ///
    /// Defaults to the panel-can't-be-seen case: the notch is the right place to answer when you can
    /// see it, and a banner on top of a visible card is just noise. In fullscreen, or on a Mac whose
    /// panel is on another display, there is nothing to see and the banner is the whole point.
    @Stored("approvalNotifications", default: ApprovalNotificationPolicy.whenPanelHidden.rawValue)
    var approvalNotificationsRaw: String

    var approvalNotifications: ApprovalNotificationPolicy {
        get { ApprovalNotificationPolicy(rawValue: approvalNotificationsRaw) ?? .whenPanelHidden }
        set { approvalNotificationsRaw = newValue.rawValue }
    }

    /// Flag destructive-looking commands on approval cards.
    @Stored("showRiskWarnings", default: true) var showRiskWarnings: Bool

    // MARK: Quiet scenes

    @Stored("quietInFocusMode", default: false) var quietInFocusMode: Bool
    @Stored("quietWhenLocked", default: false) var quietWhenLocked: Bool
    @Stored("quietWhenRecording", default: false) var quietWhenRecording: Bool

    // MARK: Filters

    @Stored("filterCodexInternalWorkers", default: true) var filterCodexInternalWorkers: Bool
    @Stored("directoryFilters", default: [String]()) var directoryFilters: [String]
    @Stored("promptFilters", default: [String]()) var promptFilters: [String]
    @Stored("promptFilterMatchType", default: "prefix") var promptFilterMatchType: String

    // MARK: Display

    @Stored("notchStyle", default: NotchStyle.detailed.rawValue) var notchStyleRaw: String

    var notchStyle: NotchStyle {
        get { NotchStyle(rawValue: notchStyleRaw) ?? .detailed }
        set { notchStyleRaw = newValue.rawValue }
    }

    /// Defaults to every display: on a multi-monitor desk the pill is visible wherever you happen
    /// to be looking, so a fresh install is never invisible because the app picked the other screen.
    @Stored("displayTarget", default: DisplayTarget.allDisplays.rawValue) var displayTargetRaw: String

    var displayTarget: DisplayTarget {
        get { DisplayTarget(rawValue: displayTargetRaw) ?? .allDisplays }
        set { displayTargetRaw = newValue.rawValue }
    }

    @Stored("contentFontSize", default: 11.0) var contentFontSize: Double
    /// Ceiling for a completion/warning reveal, in points.
    ///
    /// Reveals get their own ceiling so a finished task doesn't drop a full-height panel over your
    /// work. The old one was derived from a single card's height and cut most reveals off after two
    /// rows — generous enough to read, still short of the full panel, is the useful middle.
    @Stored("revealMaxHeight", default: 400.0) var revealMaxHeight: Double
    @Stored("maxPanelHeight", default: 560.0) var maxPanelHeight: Double
    @Stored("maxPanelWidth", default: 640.0) var maxPanelWidth: Double

    @Stored("activityAnimation", default: ActivityAnimation.equalizer.rawValue)
    var activityAnimationRaw: String

    var activityAnimation: ActivityAnimation {
        get { ActivityAnimation(rawValue: activityAnimationRaw) ?? .equalizer }
        set { activityAnimationRaw = newValue.rawValue }
    }

    @Stored("showProjectName", default: true) var showProjectName: Bool
    @Stored("showWorktree", default: true) var showWorktree: Bool
    @Stored("showModel", default: true) var showModel: Bool
    @Stored("showSubagents", default: true) var showSubagents: Bool
    @Stored("groupByProject", default: false) var groupByProject: Bool
    @Stored("showSessionCost", default: true) var showSessionCost: Bool
    @Stored("showActivityDetail", default: true) var showActivityDetail: Bool

    /// Manual nudges for MacBook models whose notch metrics we can't read exactly.
    @Stored("notchWidthAdjust", default: 0.0) var notchWidthAdjust: Double
    @Stored("notchHeightAdjust", default: 0.0) var notchHeightAdjust: Double

    // MARK: Sound

    @Stored("soundEnabled", default: true) var soundEnabled: Bool
    @Stored("soundVolume", default: 0.3) var soundVolume: Double
    @Stored("quietHoursEnabled", default: false) var quietHoursEnabled: Bool
    @Stored("quietHoursStart", default: 22.0) var quietHoursStart: Double
    @Stored("quietHoursEnd", default: 8.0) var quietHoursEnd: Double
    /// Event id -> sound id ("off", a built-in name, or "custom:<filename>").
    @Stored("soundAssignments", default: [String: String]()) var soundAssignments: [String: String]

    // MARK: Usage

    @Stored("showUsageLimits", default: true) var showUsageLimits: Bool
    @Stored("usageDisplayValue", default: "used") var usageDisplayValue: String
    @Stored("usageProvider", default: "auto") var usageProvider: String

    // MARK: Integrations

    @Stored("enabledAgents", default: [AgentKind.claude.rawValue]) var enabledAgents: [String]
    @Stored("autoConfigureNewCLIs", default: true) var autoConfigureNewCLIs: Bool

    /// Register ⌘Y / ⌘N as system-wide hot keys while a request is pending. Off by default: it
    /// shadows those keys in every other app, and a mistaken press approves an unread request.
    @Stored("globalApprovalShortcuts", default: false) var globalApprovalShortcuts: Bool

    // MARK: System

    @Stored("launchAtLogin", default: false) var launchAtLogin: Bool
    @Stored("hasCompletedOnboarding", default: false) var hasCompletedOnboarding: Bool


    // MARK: - Storage plumbing

    /// A `UserDefaults`-backed property that publishes changes on the shared `Preferences` object.
    @propertyWrapper
    struct Stored<Value> {
        let key: String
        let defaultValue: Value

        init(_ key: String, default defaultValue: Value) {
            self.key = key
            self.defaultValue = defaultValue
        }

        var wrappedValue: Value {
            get { fatalError("accessed without enclosing instance") }
            set { fatalError("accessed without enclosing instance") }
        }

        static subscript(
            _enclosingInstance instance: Preferences,
            wrapped _: ReferenceWritableKeyPath<Preferences, Value>,
            storage storageKeyPath: ReferenceWritableKeyPath<Preferences, Self>
        ) -> Value {
            get {
                let box = instance[keyPath: storageKeyPath]
                return instance.defaults.object(forKey: box.key) as? Value ?? box.defaultValue
            }
            set {
                let box = instance[keyPath: storageKeyPath]
                instance.objectWillChange.send()
                instance.defaults.set(newValue, forKey: box.key)
            }
        }
    }
}

enum NotchStyle: String, CaseIterable {
    case clean
    case detailed

    var title: String { self == .clean ? "Clean" : "Detailed" }
    var subtitle: String {
        self == .clean ? "More space for menu bar" : "Session titles & status at a glance"
    }
}

enum DisplayTarget: String, CaseIterable {
    case followFocus
    case builtIn
    case allDisplays

    var title: String {
        switch self {
        case .followFocus: return "Follow Focus"
        case .builtIn: return "Built-in Display"
        case .allDisplays: return "All Displays"
        }
    }
}

enum ApprovalNotificationPolicy: String, CaseIterable {
    case never
    case whenPanelHidden
    case always

    var title: String {
        switch self {
        case .never: return "Never"
        case .whenPanelHidden: return "When the panel can't be seen"
        case .always: return "Always"
        }
    }
}

enum SubagentNotificationPolicy: String, CaseIterable {
    case immediately
    case withMainAgent
    case never

    var title: String {
        switch self {
        case .immediately: return "Immediately"
        case .withMainAgent: return "As the main agent responds"
        case .never: return "Never"
        }
    }
}
