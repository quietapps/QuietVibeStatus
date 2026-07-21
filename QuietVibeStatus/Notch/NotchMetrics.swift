import AppKit

/// Physical notch geometry for a given screen.
///
/// macOS exposes the notch through `NSScreen.auxiliaryTopLeftArea` / `safeAreaInsets`; on displays
/// without a notch we synthesize a pill-sized region under the menu bar so external monitors get a
/// compact floating bar in the same place.
struct NotchMetrics {
    var size: CGSize
    var hasPhysicalNotch: Bool
    var screenFrame: CGRect

    static func forScreen(_ screen: NSScreen) -> NotchMetrics {
        let prefs = Preferences.shared
        let adjustW = CGFloat(prefs.notchWidthAdjust)
        let adjustH = CGFloat(prefs.notchHeightAdjust)

        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0
        {
            // The notch is the gap between the two auxiliary areas.
            let width = rightArea.minX - leftArea.maxX
            let height = screen.safeAreaInsets.top
            return NotchMetrics(
                size: CGSize(width: width + adjustW, height: height + adjustH),
                hasPhysicalNotch: true,
                screenFrame: screen.frame
            )
        }

        // No notch: a pill the height of the menu bar.
        return NotchMetrics(
            size: CGSize(width: 190 + adjustW, height: Self.menuBarHeight + adjustH),
            hasPhysicalNotch: false,
            screenFrame: screen.frame
        )
    }

    /// One menu-bar height for every display without a notch, so the pills match.
    ///
    /// Deriving this per screen from `frame.height - visibleFrame.height` is wrong twice over: that
    /// difference also contains the Dock, so a display with the Dock reported a taller "menu bar"
    /// than one without, and a secondary display with no menu bar at all reported zero. Both
    /// happened here, which is why two identical monitors ended up with different pill heights.
    static var menuBarHeight: CGFloat {
        // The screen at the origin owns the real menu bar; measure its top inset only.
        if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            let topInset = primary.frame.maxY - primary.visibleFrame.maxY
            if topInset > 5 { return topInset }
        }
        if let height = NSApp.mainMenu?.menuBarHeight, height > 5 {
            return height
        }
        return 24
    }
}

extension NSScreen {
    /// The screen with a physical notch, if this Mac has one.
    static var notched: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    /// The screen the notch should live on, per the user's Display setting.
    ///
    /// `NSScreen.main` is the wrong answer for an accessory app: it means "screen with the key
    /// window", and this app never takes key, so at launch it resolves to whichever display last
    /// had focus. That put the pill on an external monitor while the user was looking at their
    /// MacBook's actual notch. Follow-focus tracks the pointer instead, and every mode falls back
    /// to the notched display rather than to `main`.
    static func notchTarget() -> NSScreen? {
        switch Preferences.shared.displayTarget {
        case .builtIn:
            return notched ?? NSScreen.main ?? NSScreen.screens.first
        case .followFocus, .allDisplays:
            return screenUnderPointer ?? notched ?? NSScreen.main ?? NSScreen.screens.first
        }
    }

    static var screenUnderPointer: NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }

    /// Whether a fullscreen window currently owns this screen, so the panel can hide itself.
    ///
    /// Detected from the menu bar: a fullscreen app hides it, which pushes `visibleFrame` up to the
    /// top of `frame`. The catch is that a secondary display may never show a menu bar at all, so a
    /// collapsed gap there means nothing — an earlier version of this hid the panel permanently on
    /// a second monitor. So a screen only counts as fullscreen if we have previously seen it with a
    /// menu bar of its own.
    var hasFullscreenWindow: Bool {
        let gap = frame.maxY - visibleFrame.maxY
        MenuBarBaseline.record(gap: gap, for: self)
        guard MenuBarBaseline.everHadMenuBar(self) else { return false }
        // A visible menu bar is ~24pt or more; under this it is hidden.
        return gap < 5
    }

    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}

/// Remembers which displays have ever shown a menu bar, so a collapsed menu bar can be read as
/// "a fullscreen window is covering this screen" rather than "this screen never had one".
enum MenuBarBaseline {
    private static var seen: [CGDirectDisplayID: Bool] = [:]

    static func record(gap: CGFloat, for screen: NSScreen) {
        guard let id = screen.displayID else { return }
        if gap > 20 { seen[id] = true }
    }

    static func everHadMenuBar(_ screen: NSScreen) -> Bool {
        guard let id = screen.displayID else { return false }
        return seen[id] ?? false
    }
}
