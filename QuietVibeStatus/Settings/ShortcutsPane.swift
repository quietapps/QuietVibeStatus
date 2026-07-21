import SwiftUI

struct ShortcutsPane: View {
    @ObservedObject private var hotKeys = GlobalHotKeys.shared
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup {
                SettingsToggleRow(
                    title: "Enable keyboard shortcuts",
                    subtitle: "Turn off to release every global shortcut at once.",
                    isOn: $hotKeys.masterEnabled
                )
                SettingsToggleRow(
                    title: "System-wide approval shortcuts",
                    subtitle: "Lets ⌘Y and ⌘N approve from any app while a request is pending. Off by default because it takes those keys away from whatever you're using, and a stray press approves a request you haven't read.",
                    isOn: $prefs.globalApprovalShortcuts
                )
            }

            SettingsGroup(title: "Shortcuts") {
                ForEach(ShortcutAction.allCases) { action in
                    SettingsRow(title: action.title, subtitle: action.subtitle) {
                        HStack(spacing: 8) {
                            ShortcutRecorder(action: action, hotKeys: hotKeys)
                            Button("Reset") { hotKeys.resetBinding(for: action) }
                                .controlSize(.small)
                        }
                    }
                }
            }

            Text("Click a shortcut to record a new one, then press the keys. A modifier is required. Escape cancels.\n\n⌘Y and ⌘N always work inside the notch panel itself. The system-wide toggle above only controls whether they also work while another app has focus.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
