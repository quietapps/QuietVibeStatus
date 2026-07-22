import ServiceManagement
import SwiftUI

struct GeneralPane: View {
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "System") {
                SettingsToggleRow(title: "Launch at Login", isOn: launchAtLogin)
            }

            SettingsGroup(title: "Expansion") {
                SettingsToggleRow(title: "Expand notch on hover", isOn: $prefs.expandOnHover)
                SettingsSliderRow(
                    title: "Hover duration",
                    value: $prefs.hoverDuration,
                    range: 0 ... 1,
                    step: 0.05
                ) { String(format: "%.2fs", $0) }
                SettingsToggleRow(
                    title: "Smart suppression",
                    subtitle: "Don't auto-expand when the agent's terminal tab is in focus",
                    isOn: $prefs.smartSuppression
                )
            }

            SettingsGroup(title: "Visibility") {
                SettingsToggleRow(title: "Hide in fullscreen", isOn: $prefs.hideInFullscreen)
                SettingsToggleRow(
                    title: "Auto-hide when no active sessions",
                    isOn: $prefs.autoHideWhenEmpty
                )
            }

            SettingsGroup(title: "Dismissal") {
                SettingsToggleRow(
                    title: "Auto-collapse on mouse leave",
                    isOn: $prefs.autoCollapseOnMouseLeave
                )
                SettingsRow(
                    title: "Auto reveal dwell",
                    subtitle: "How long the panel stays open for completion and warning reveals. Move the pointer onto it and away again to close it sooner."
                ) {
                    Picker("", selection: $prefs.autoRevealDwell) {
                        ForEach([3.0, 5.0, 8.0, 12.0, 20.0, 30.0, 60.0], id: \.self) { value in
                            Text("\(Int(value))s").tag(value)
                        }
                        Divider()
                        Text("Until dismissed").tag(0.0)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                SettingsToggleRow(
                    title: "Dismiss auto reveal on outside click",
                    subtitle: "Clicking anywhere outside the notch panel immediately closes completion and warning reveals, ignoring the remaining dwell time.",
                    isOn: $prefs.dismissRevealOnOutsideClick
                )
                SettingsRow(
                    title: "Idle session cleanup",
                    subtitle: "Applies only to sessions without a clear close signal (Codex, Cursor)."
                ) {
                    Picker("", selection: $prefs.idleCleanupSeconds) {
                        Text("30 minutes").tag(1800.0)
                        Text("1 hour").tag(3600.0)
                        Text("2 hours (default)").tag(7200.0)
                        Text("6 hours").tag(21600.0)
                        Text("Never").tag(Double.greatestFiniteMagnitude)
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                SettingsToggleRow(
                    title: "Restore sessions on launch",
                    subtitle: "Agents keep running while the app is quit or updating. Cards for sessions whose process is still alive come back; the rest are dropped. Turning this off deletes the saved file.",
                    isOn: $prefs.restoreSessionsOnLaunch
                )
                SettingsRow(
                    title: "Hand approvals back after",
                    subtitle: "An unanswered request blocks the agent for as long as its card sits there. When this elapses the agent is released and asks in its own terminal instead — nothing is approved or denied for you."
                ) {
                    Picker("", selection: $prefs.approvalTimeoutMinutes) {
                        Text("5 minutes").tag(5.0)
                        Text("15 minutes (default)").tag(15.0)
                        Text("1 hour").tag(60.0)
                        Text("Never").tag(0.0)
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            SettingsGroup(title: "Interaction") {
                SettingsToggleRow(
                    title: "Disable click-to-jump",
                    subtitle: "When enabled, clicking a session won't switch to its terminal or IDE.",
                    isOn: $prefs.disableClickToJump
                )
            }

            SettingsGroup(title: "Quit") {
                SettingsRow(
                    title: "Quit Quiet Vibe Status",
                    subtitle: "Your agents keep running. Restart the app from Applications or Spotlight."
                ) {
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }
        }
    }

    /// Login items are managed by the system, so mirror the real registration state rather than
    /// trusting our stored flag — the user can remove the item in System Settings at any time.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    prefs.launchAtLogin = enabled
                } catch {
                    Log.integrations.error("login item failed: \(error.localizedDescription)")
                }
            }
        )
    }
}
