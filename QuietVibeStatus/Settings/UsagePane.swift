import SwiftUI

struct UsagePane: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var statusLine: StatusLineInstaller
    @ObservedObject private var usage = UsageStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Usage limits") {
                SettingsToggleRow(
                    title: "Show usage limits",
                    subtitle: "Display subscription usage limits in the notch panel header",
                    isOn: $prefs.showUsageLimits
                )
                SettingsRow(title: "Display value") {
                    Picker("", selection: $prefs.usageDisplayValue) {
                        Text("Used").tag("used")
                        Text("Remaining").tag("remaining")
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                SettingsRow(title: "Preferred provider") {
                    Picker("", selection: $prefs.usageProvider) {
                        Text("Auto (follow session)").tag("auto")
                        Text("Claude").tag("claude")
                        Text("Codex").tag("codex")
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
            }

            SettingsGroup(title: "Claude usage bridge") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(bridgeExplanation)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if statusLine.isInstalled {
                        Button("Remove bridge") { statusLine.remove() }
                    } else {
                        Button("Install bridge") { statusLine.install() }
                    }
                }
                .padding(12)
            }

            if let current = usage.displayed {
                SettingsGroup(title: "Current") {
                    SettingsRow(title: "\(current.provider) · 5 hour") {
                        Text(windowText(current.short))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    SettingsRow(title: "\(current.provider) · 7 day") {
                        Text(windowText(current.long))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { statusLine.refresh() }
    }

    private var bridgeExplanation: String {
        statusLine.isInstalled
            ? "Quiet Vibe Status is reading Claude usage from your status line input. Your existing status line display stays unchanged; removing the bridge only removes this connection."
            : "Claude Code publishes subscription limits only through the status line. Installing the bridge chains in front of your existing status line command, caches the limits, and passes your own output through untouched."
    }

    private func windowText(_ window: UsageWindow?) -> String {
        guard let window else { return "—" }
        let value = prefs.usageDisplayValue == "remaining"
            ? window.remainingPercentage
            : window.usedPercentage
        let suffix = window.resetText.map { " · resets in \($0)" } ?? ""
        return "\(Int(value))%\(suffix)"
    }
}
