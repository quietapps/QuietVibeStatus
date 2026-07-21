import AppKit
import Foundation

/// Detects situations where the app should stay silent and out of the way — Focus mode, a locked
/// screen, or an active screen recording / share.
///
/// Each check is deliberately cheap and polled, because none of these have a reliable public
/// notification we can subscribe to.
final class QuietScenes {
    static let shared = QuietScenes()

    private var prefs: Preferences { Preferences.shared }
    private var cachedFocus = false
    private var lastFocusCheck = Date.distantPast

    private init() {}

    /// True when any enabled quiet scene is currently active.
    var isQuiet: Bool {
        if prefs.quietInFocusMode, isFocusModeOn { return true }
        if prefs.quietWhenLocked, isScreenLocked { return true }
        if prefs.quietWhenRecording, isScreenBeingCaptured { return true }
        return false
    }

    // MARK: - Focus

    /// macOS exposes Focus state through a plist that Do Not Disturb writes. There is no public
    /// API, so this is read with a short cache to keep it off the hot path.
    var isFocusModeOn: Bool {
        if Date().timeIntervalSince(lastFocusCheck) < 5 { return cachedFocus }
        lastFocusCheck = Date()

        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")

        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let records = root["data"] as? [[String: Any]]
        else {
            cachedFocus = false
            return false
        }

        cachedFocus = records.contains { record in
            guard let assertions = record["storeAssertionRecords"] as? [[String: Any]] else {
                return false
            }
            return !assertions.isEmpty
        }
        return cachedFocus
    }

    // MARK: - Lock

    var isScreenLocked: Bool {
        guard
            let info = CGSessionCopyCurrentDictionary() as? [String: Any],
            let locked = info["CGSSessionScreenIsLocked"] as? Int
        else { return false }
        return locked == 1
    }

    // MARK: - Screen capture

    /// True while something is likely capturing the screen — screen sharing, a recording, or a
    /// meeting app sharing a window.
    ///
    /// macOS has no public API for "is my screen being recorded" (`CGDisplayIsCaptured` was
    /// removed), so this looks for the apps that do it. It errs toward false: a missed detection
    /// only means a sound plays, while a false positive would silence the app for no reason.
    var isScreenBeingCaptured: Bool {
        let capturing: Set<String> = [
            "com.apple.screensharing",
            "com.apple.ScreenSharing",
            "com.apple.QuickTimePlayerX",
            "us.zoom.xos",
            "com.microsoft.teams2",
            "com.microsoft.teams",
            "com.hnc.Discord",
            "com.obsproject.obs-studio",
            "com.loom.desktop",
        ]
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return !running.isDisjoint(with: capturing)
    }
}
