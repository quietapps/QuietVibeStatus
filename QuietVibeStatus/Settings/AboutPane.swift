import SwiftUI

struct AboutPane: View {
    private var version: String {
        let marketing = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(marketing) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 10) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 84, height: 84)
                }
                Text("Quiet Vibe Status")
                    .font(.system(size: 20, weight: .semibold))
                Text(version)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("A quiet place in the notch for your coding agents.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

            SettingsGroup {
                SettingsRow(
                    title: "Free and local",
                    subtitle: "No license, no account, no telemetry. Nothing leaves this Mac."
                ) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
                SettingsRow(
                    title: "Support folder",
                    subtitle: BridgeServer.supportDirectory.path
                ) {
                    Button("Reveal") {
                        NSWorkspace.shared.selectFile(
                            nil,
                            inFileViewerRootedAtPath: BridgeServer.supportDirectory.path
                        )
                    }
                }
            }

            SettingsGroup(title: "Part of Quiet Apps") {
                Text("Quiet Apps are small, focused macOS tools that stay out of your way. This one watches your coding agents so you don't have to keep checking on them.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }
        }
    }
}
