import SwiftUI

/// The resting state: a pill that merges with the physical notch.
///
/// In `Clean` style it stays close to notch-width and shows only a status dot and a count, so the
/// menu bar keeps its space. In `Detailed` it widens to name what's running.
///
/// On a display with a real notch the centre is reserved — nothing can be drawn behind the camera
/// housing, so content sits on shoulders either side. On a display *without* one there is no
/// obstruction, so the pill is one continuous run of content: reserving a gap there would mean
/// inventing a hole and then working around it.
struct CollapsedPill: View {
    let notchSize: CGSize
    let hasPhysicalNotch: Bool

    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var prefs: Preferences

    private var sessions: [Session] { store.visibleSessions }
    private var blocked: Int { store.blockedSessions.count }

    private var statusColor: Color {
        if blocked > 0 { return Theme.attention }
        if store.hasActiveWork { return Theme.blue }
        if sessions.contains(where: { $0.state == .failed }) { return Theme.danger }
        if sessions.contains(where: { $0.state == .complete }) { return Theme.success }
        return Theme.onDark3
    }

    private var isDetailed: Bool {
        prefs.notchStyle == .detailed && !sessions.isEmpty
    }

    var body: some View {
        Group {
            if hasPhysicalNotch {
                HStack(spacing: 0) {
                    leading
                        .frame(width: sideWidth, alignment: .leading)

                    // The physical notch cutout — nothing can be drawn here.
                    Color.clear.frame(width: notchSize.width)

                    trailing
                        .frame(width: sideWidth, alignment: .trailing)
                }
            } else {
                // No obstruction: glyph pinned left, count pinned right, label centred between
                // them. The side slots are a matched fixed width precisely so the label lands in
                // the true centre of the pill — letting them size to their content would drift the
                // label off-centre every time the count changed from "1 session" to "12 sessions".
                HStack(spacing: 0) {
                    leading
                        .frame(width: sideSlotWidth, alignment: .leading)

                    centreLabel
                        .frame(maxWidth: 260)
                        .layoutPriority(1)

                    trailing
                        .frame(width: sideSlotWidth, alignment: .trailing)
                }
            }
        }
        .frame(height: notchSize.height)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            NotchShape(topCornerRadius: 6, bottomCornerRadius: isDetailed ? 12 : 10)
                .fill(Color.black)
        )
        .animation(Theme.ease, value: isDetailed)
        .animation(Theme.ease, value: statusColor)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PillSizeKey.self, value: proxy.size)
            }
        )
    }

    private var sideWidth: CGFloat {
        isDetailed ? 92 : 34
    }

    /// Matched width for the glyph and count slots, so the centre label is genuinely centred.
    /// Wide enough for the longest count the pill realistically shows.
    private var sideSlotWidth: CGFloat {
        isDetailed ? 78 : 34
    }

    /// What the pill says it is doing.
    ///
    /// Prefers the live activity over the project name: "Bash: cd ~/Projects/…" tells you what the
    /// agent is doing right now, which is the thing worth reading at a glance. Falls back to the
    /// project when nothing is running.
    @ViewBuilder
    private var centreLabel: some View {
        if isDetailed, let session = sessions.first {
            if let activity = session.lastActivity, !activity.isEmpty {
                Text(activity)
                    .font(Theme.mono(10, weight: .medium))
                    .foregroundStyle(Theme.onDark)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            } else {
                Text(session.projectName)
                    .font(Theme.ui(10, weight: .semibold))
                    .foregroundStyle(Theme.onDark)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
        } else {
            Color.clear.frame(width: 0)
        }
    }

    @ViewBuilder
    private var leading: some View {
        HStack(spacing: 5) {
            ActivityGlyph(active: store.hasActiveWork, color: statusColor)
            // On a notched display the project name rides the left shoulder; without a notch it
            // moves to the centre label instead, so this slot stays just the glyph.
            if isDetailed, hasPhysicalNotch, let first = sessions.first {
                Text(first.projectName)
                    .font(Theme.ui(10, weight: .medium))
                    .foregroundStyle(Theme.onDark2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.leading, 10)
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 4) {
            if !sessions.isEmpty {
                Text("\(sessions.count)")
                    .font(Theme.mono(10, weight: .semibold))
                    .foregroundStyle(Theme.onDark)
                if isDetailed {
                    Text(sessions.count == 1 ? "session" : "sessions")
                        .font(Theme.ui(9))
                        .foregroundStyle(Theme.onDark3)
                }
            }
        }
        .padding(.trailing, 10)
    }
}


/// Reports the pill's intrinsic size so the notch container can size its morph and hover target to
/// what was actually drawn, rather than recomputing the same layout maths in two places.
struct PillSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
