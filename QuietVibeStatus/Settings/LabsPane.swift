import SwiftUI

struct LabsPane: View {
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Diagnostics and escape hatches. Nothing here is required for normal use.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            SettingsGroup(title: "Diagnostics") {
                SettingsRow(
                    title: "Reveal support folder",
                    subtitle: BridgeServer.supportDirectory.path
                ) {
                    Button("Open") {
                        NSWorkspace.shared.selectFile(
                            nil,
                            inFileViewerRootedAtPath: BridgeServer.supportDirectory.path
                        )
                    }
                }
                SettingsRow(
                    title: "Restart bridge server",
                    subtitle: "Rebinds the Unix socket agents connect to."
                ) {
                    Button("Restart") { BridgeServer.shared.start() }
                }
            }
        }
    }
}
