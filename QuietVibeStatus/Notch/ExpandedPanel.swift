import SwiftUI

/// The open panel: header, session list, footer.
struct ExpandedPanel: View {
    @EnvironmentObject private var controller: NotchController
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject private var registry = PendingRequestRegistry.shared
    @State private var listHeight: CGFloat = 0

    /// Notch geometry for the display this panel is on.
    let metrics: NotchMetrics?

    private var notchWidth: CGFloat {
        metrics?.size.width ?? 190
    }

    private var notchHeight: CGFloat {
        metrics?.size.height ?? 32
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                notchWidth: notchWidth,
                notchHeight: notchHeight,
                hasPhysicalNotch: metrics?.hasPhysicalNotch ?? false
            )

            Divider().overlay(Theme.darkLine)

            if store.visibleSessions.isEmpty, registry.requests.isEmpty {
                EmptyPanelState()
                    .frame(height: 120)
            } else {
                sessionList
            }
        }
        // No background, border, or shadow here on purpose. NotchRootView owns a single shape that
        // morphs between the pill and the panel; if this view drew its own chrome there would be
        // two shapes to keep in sync and the growth would visibly double up.
    }

    /// A completion reveal is a glance, not a browse: it gets its own smaller allowance so a
    /// finished task doesn't drop the full-height panel over your work. It still has to be tall
    /// enough to read — the previous two-cards-worth ceiling truncated the very update the reveal
    /// had opened to show.
    private var heightAllowance: CGFloat {
        controller.presentation == .revealed
            ? min(prefs.revealMaxHeight, prefs.maxPanelHeight)
            : prefs.maxPanelHeight
    }

    /// Panel height, rounded up so the frame is never a fraction shorter than the content it
    /// measured. A frame of 247.0 around 247.33 of content reads as overflow to the scroll view and
    /// flashes the indicator even when nothing needs scrolling.
    private var panelHeight: CGFloat {
        min(listHeight.rounded(.up), heightAllowance)
    }

    /// The content genuinely doesn't fit. The one-point slack absorbs sub-pixel measurement jitter
    /// so the elapsed-time tick can't toggle the indicator on and off between hovers.
    private var isScrollable: Bool {
        listHeight > heightAllowance + 1
    }

    private var sessionList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: Theme.s2) {
                    // Anything waiting on a decision goes first — that's why the panel opened.
                    ForEach(registry.requests) { request in
                        ApprovalCard(request: request)
                            .id("approval-\(request.id)")
                    }

                    if prefs.groupByProject {
                        ForEach(store.groupedSessions) { group in
                            ProjectGroupSection(group: group)
                        }
                    } else {
                        ForEach(store.visibleSessions) { session in
                            SessionCard(session: session)
                                .id(session.id)
                        }
                    }
                }
                .padding(Theme.s3)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            // Hug the content instead of always claiming the full allowance, so two short cards
            // don't leave a tall empty void hanging off the notch.
            .frame(height: panelHeight)
            .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            .scrollIndicators(isScrollable ? .automatic : .never)
            .scrollDisabled(!isScrollable)
            .onChange(of: store.highlightedID) { _, id in
                guard let id else { return }
                withAnimation(Theme.ease) { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }
}

/// One project's block in the list.
///
/// A project with several sessions gets a heading and its cards are indented behind a rail, so the
/// group has a visible end. Without it the next project's single card sat flush under the last
/// grouped card and read as another member of the group above.
///
/// A project with one session gets neither: a heading over a lone card is noise, the card already
/// names its own project, and with no rail beside it there is nothing to mistake it for.
private struct ProjectGroupSection: View {
    let group: SessionStore.ProjectGroup

    var body: some View {
        if group.sessions.count > 1 {
            VStack(alignment: .leading, spacing: Theme.s2) {
                ProjectGroupHeader(group: group)

                VStack(spacing: Theme.s2) {
                    ForEach(group.sessions) { session in
                        SessionCard(session: session)
                            .id(session.id)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Theme.onDark3.opacity(0.25))
                        .frame(width: 2)
                        .padding(.vertical, 2)
                }
            }
        } else {
            ForEach(group.sessions) { session in
                SessionCard(session: session)
                    .id(session.id)
            }
        }
    }
}

/// The heading above a multi-session project.
private struct ProjectGroupHeader: View {
    let group: SessionStore.ProjectGroup

    var body: some View {
        HStack(spacing: Theme.s1) {
            Image(systemName: "folder")
                .font(.system(size: 9))
            Text(group.name)
                .font(Theme.ui(10, weight: .semibold))
            Text("\(group.sessions.count)")
                .font(Theme.mono(9, weight: .medium))
                .foregroundStyle(Theme.onDark3)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(Theme.onDark3.opacity(0.15))
                )
            Spacer()
        }
        .foregroundStyle(Theme.onDark2)
        .padding(.top, Theme.s1)
    }
}

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct EmptyPanelState: View {
    var body: some View {
        VStack(spacing: Theme.s2) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.onDark3)
            Text("No active sessions")
                .font(Theme.ui(12, weight: .medium))
                .foregroundStyle(Theme.onDark2)
            Text("Start an agent and it shows up here.")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.onDark3)
        }
        .frame(maxWidth: .infinity)
    }
}
