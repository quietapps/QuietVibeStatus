import SwiftUI

@main
struct QuietVibeStatusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The app is menu-bar/notch only (LSUIElement); all windows are created imperatively.
        Settings {
            EmptyView()
        }
    }
}
