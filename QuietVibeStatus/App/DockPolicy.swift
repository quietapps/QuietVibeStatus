import AppKit

/// Keeps the app out of the Dock except while one of its windows is open.
///
/// The app ships as an accessory (`LSUIElement`) so the notch panel is the whole UI. A window
/// opened by an accessory app can't take focus properly, though — it lands behind whatever the
/// user was working in — so Settings and Onboarding promote the app to `.regular` while they're up.
///
/// Both can be open at once, so promotion is reference counted: the last window to close is the one
/// that drops the Dock icon.
@MainActor
enum DockPolicy {
    private static var holders: Set<ObjectIdentifier> = []

    /// Puts the app in the Dock and brings `window`'s owner forward.
    static func promote(for window: NSWindow) {
        holders.insert(ObjectIdentifier(window))
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Drops the Dock icon once the last promoted window has gone.
    ///
    /// Called from `windowWillClose`, which fires *before* the window is off screen. Changing the
    /// activation policy at that moment makes AppKit flash the window back up, so the demotion
    /// waits for the next run loop pass.
    static func demote(for window: NSWindow) {
        holders.remove(ObjectIdentifier(window))
        guard holders.isEmpty else { return }
        DispatchQueue.main.async {
            guard holders.isEmpty else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// Reports a promoted window's close back to `DockPolicy`.
///
/// `NSWindow.delegate` is weak, so whoever owns the window has to hold on to one of these.
@MainActor
final class DockPolicyWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DockPolicy.demote(for: window)
    }
}
