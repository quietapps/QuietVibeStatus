import SwiftUI

/// The strip that wraps around the physical notch at the top of the open panel.
struct PanelHeader: View {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let hasPhysicalNotch: Bool

    @EnvironmentObject private var controller: NotchController
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: Theme.s2) {
                ActivityGlyph(active: store.hasActiveWork, color: statusColor, size: 13)
                Text(summary)
                    .font(Theme.ui(11, weight: .medium))
                    .foregroundStyle(Theme.onDark2)
                    .lineLimit(1)
            }
            .padding(.leading, Theme.s3)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Reserve the camera housing only where there is one. On a plain display the header
            // simply spans the full width.
            if hasPhysicalNotch {
                Color.clear.frame(width: notchWidth)
            }

            HStack(spacing: Theme.s2) {
                if prefs.showUsageLimits {
                    UsageBadge()
                }
                HeaderButton(icon: prefs.soundEnabled ? "speaker.wave.2" : "speaker.slash") {
                    prefs.soundEnabled.toggle()
                }
                HeaderButton(icon: "gearshape") {
                    SettingsWindowController.shared.show()
                }
            }
            .padding(.trailing, Theme.s3)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: max(notchHeight, 30))
    }

    private var statusColor: Color {
        if !store.blockedSessions.isEmpty { return Theme.attention }
        if store.hasActiveWork { return Theme.blue }
        return Theme.onDark3
    }

    private var summary: String {
        let count = store.visibleSessions.count
        let blocked = store.blockedSessions.count
        if blocked > 0 {
            return blocked == 1 ? "1 needs you" : "\(blocked) need you"
        }
        if count == 0 { return "Idle" }
        return count == 1 ? "1 session" : "\(count) sessions"
    }
}

struct HeaderButton: View {
    let icon: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Theme.onDark : Theme.onDark3)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                        .fill(hovering ? Theme.dark3 : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
