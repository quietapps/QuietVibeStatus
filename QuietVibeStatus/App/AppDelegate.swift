import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Unit tests load this app as their host. Starting the real services would bind the bridge
        // socket out from under the copy the user is actually running, rewrite their agent hook
        // configs, and put a second panel on screen — so the test host stays inert.
        guard !Self.isRunningTests else { return }

        setUpStatusItem()

        Task { @MainActor in
            NotchController.shared.start()
            // Before the socket opens, so a hook arriving in the same moment updates a restored
            // card instead of creating a second one for the same session.
            SessionStore.shared.restore()
            SessionHistory.shared.load()
            BridgeServer.shared.start()
            IntegrationManager.shared.syncOnLaunch()
            GlobalHotKeys.shared.start()
            UsageStore.shared.start()

            if !Preferences.shared.hasCompletedOnboarding {
                OnboardingWindowController.shared.show()
            }
        }
    }

    func applicationWillTerminate(_: Notification) {
        guard !Self.isRunningTests else { return }
        BridgeServer.shared.stop()
        // A debounced write would never land during termination.
        MainActor.assumeIsolated {
            SessionStore.shared.saveNow()
            SessionHistory.shared.saveNow()
        }
    }

    /// True when this process was launched as an XCTest host rather than by the user.
    static let isRunningTests = NSClassFromString("XCTestCase") != nil

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "chart.bar.doc.horizontal",
            accessibilityDescription: "Quiet Vibe Status"
        )
        item.button?.image?.isTemplate = true
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(withTitle: "Quiet Vibe Status", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let toggle = NSMenuItem(
            title: "Show Panel",
            action: #selector(togglePanel),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let clear = NSMenuItem(
            title: "Clear All Sessions",
            action: #selector(clearSessions),
            keyEquivalent: ""
        )
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        return menu
    }

    @objc private func openSettings() {
        Task { @MainActor in SettingsWindowController.shared.show() }
    }

    @objc private func togglePanel() {
        Task { @MainActor in NotchController.shared.revealTemporarily() }
    }

    @objc private func clearSessions() {
        Task { @MainActor in SessionStore.shared.removeAll() }
    }
}
