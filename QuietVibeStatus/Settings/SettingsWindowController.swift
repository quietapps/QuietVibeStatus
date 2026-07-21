import AppKit
import SwiftUI

/// Owns the Settings window.
///
/// The app is an accessory (`LSUIElement`), so opening Settings has to temporarily promote it to a
/// regular app — otherwise the window opens behind whatever the user was working in and can't be
/// focused. `DockPolicy` puts it back once the window closes.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let windowDelegate = DockPolicyWindowDelegate()

    private init() {}

    func show() {
        if let window {
            promoteAndFocus(window)
            return
        }

        let root = SettingsView()
            .environmentObject(Preferences.shared)
            .environmentObject(IntegrationManager.shared)
            .environmentObject(StatusLineInstaller.shared)
            // The Display pane previews a real SessionCard, which reads the live store.
            .environmentObject(SessionStore.shared)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Quiet Vibe Status"
        // Let the split view draw its own sidebar material under a standard titlebar.
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: root)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = windowDelegate

        self.window = window
        promoteAndFocus(window)
    }

    private func promoteAndFocus(_ window: NSWindow) {
        DockPolicy.promote(for: window)
        window.makeKeyAndOrderFront(nil)
    }
}
