import SwiftUI

struct IntegrationsPane: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var manager: IntegrationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "CLI Hooks") {
                ForEach(manager.integrations) { integration in
                    SettingsRow(
                        title: integration.displayName,
                        subtitle: integration.isInstalled ? nil : "Not installed on this Mac"
                    ) {
                        HStack(spacing: 8) {
                            if manager.activeAgents.contains(integration.agent) {
                                Label("Active", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)
                                    .labelStyle(.titleAndIcon)
                            }
                            Toggle("", isOn: binding(for: integration))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(!integration.isInstalled)
                        }
                    }
                }
            }

            Text("Hooks are merged into each CLI's own config file. Existing hooks — yours or another tool's — are left untouched, and a `.qvs-backup` copy is kept next to each file.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !manager.rivalHooks.isEmpty {
                SettingsGroup(title: "Another monitor is also watching") {
                    ForEach(manager.rivalHooks) { rival in
                        SettingsRow(
                            title: rival.displayName,
                            subtitle: rival.summary + ". Both apps receive every event, so you get duplicate cards, doubled sounds, and two apps racing to answer the same permission request."
                        ) {
                            Button("Remove hooks", role: .destructive) {
                                try? manager.removeRivalHooks(rival)
                            }
                        }
                    }
                }
            }

            SettingsGroup {
                SettingsToggleRow(
                    title: "Auto-configure new CLIs",
                    subtitle: "New supported CLIs are set up automatically.",
                    isOn: $prefs.autoConfigureNewCLIs
                )
            }

            SettingsGroup(title: "Maintenance") {
                SettingsRow(
                    title: "Re-apply hooks",
                    subtitle: "Repairs hook entries that another tool overwrote."
                ) {
                    Button("Repair") { manager.syncOnLaunch() }
                }
                SettingsRow(
                    title: "Remove all integrations",
                    subtitle: "Deletes every hook, the status line bridge, and the support folder."
                ) {
                    Button("Uninstall", role: .destructive) { manager.uninstallEverything() }
                }
            }
        }
        .onAppear {
            manager.refreshStatus()
            manager.refreshRivalHooks()
        }
    }

    private func binding(for integration: Integration) -> Binding<Bool> {
        Binding(
            get: { prefs.enabledAgents.contains(integration.agent.rawValue) },
            set: { manager.setEnabled($0, for: integration.agent) }
        )
    }
}
