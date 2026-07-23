import SwiftUI

/// Root of everything painted in the notch panel.
///
/// The layout is anchored to the top-center of an oversized transparent window, so the pill can
/// grow into the full panel without the AppKit window frame having to animate.
///
/// Both the pill and the panel are always in the view tree, crossfading against each other inside
/// a single shape whose size animates. Swapping them structurally — the obvious approach — meant
/// SwiftUI tore down and rebuilt tracking areas mid-animation, which caused hover flicker, and it
/// gave nothing to animate *between*, so the notch snapped open with no motion at all.
struct NotchRootView: View {
    @EnvironmentObject private var controller: NotchController
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var prefs: Preferences
    /// Which display this panel is on. Notch geometry is per-screen, so the view resolves its own
    /// metrics rather than reading a single global value shared by every panel.
    let screenID: CGDirectDisplayID
    /// Plain reference, not an EnvironmentObject — see NotchInteractionModel.
    let interaction: NotchInteractionModel

    /// Natural height of the open panel, measured continuously so the morph always has a real
    /// target to grow toward rather than guessing on first open.
    @State private var panelHeight: CGFloat = 0
    /// Intrinsic size of the collapsed pill, reported by `CollapsedPill`.
    @State private var pillSize: CGSize = .zero
    /// Whether the open panel is in the view tree at all — see `morphingContent`.
    ///
    /// Follows `expanded`, but lags it on the way down so the fade-out is allowed to finish before
    /// the content is torn out from under it.
    @State private var showsPanel = false
    /// Cancels a pending unmount when the panel is reopened mid-fade.
    @State private var unmountTask: Task<Void, Never>?

    private var expanded: Bool { controller.presentation.isExpanded }

    private var metrics: NotchMetrics? {
        controller.metricsByScreen[screenID]
    }

    private var notchSize: CGSize {
        metrics?.size ?? CGSize(width: 190, height: 32)
    }

    /// Measured from what the pill actually drew, rather than re-deriving its layout here. On a
    /// display without a notch the pill sizes itself to its content, so there is no formula to copy.
    private var pillWidth: CGFloat {
        pillSize.width > 1 ? pillSize.width : notchSize.width + 68
    }

    private var currentSize: CGSize {
        expanded
            ? CGSize(width: prefs.maxPanelWidth, height: max(panelHeight, notchSize.height))
            : CGSize(width: pillWidth, height: max(pillSize.height, notchSize.height))
    }

    var body: some View {
        VStack(spacing: 0) {
            morphingContent
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Zero arrives as the panel unmounts; keeping the last real height means the next open has
        // somewhere to grow to instead of starting from nothing.
        .onPreferenceChange(PanelHeightKey.self) { if $0 > 0 { panelHeight = $0 } }
        .onAppear { showsPanel = expanded }
        .onChange(of: expanded) { _, isExpanded in
            unmountTask?.cancel()
            unmountTask = nil

            guard !isExpanded else {
                showsPanel = true
                return
            }

            unmountTask = Task {
                try? await Task.sleep(for: .seconds(0.45))
                guard !Task.isCancelled, !controller.presentation.isExpanded else { return }
                showsPanel = false
            }
        }
        .onPreferenceChange(PillSizeKey.self) {
            pillSize = $0
            // The controller needs the pill footprint to decide whether the pointer is really over
            // the notch, separately from the morphing content size.
            interaction.report(pillSize: $0)
        }
    }

    private var morphingContent: some View {
        ZStack(alignment: .top) {
            CollapsedPill(
                notchSize: notchSize,
                hasPhysicalNotch: metrics?.hasPhysicalNotch ?? false
            )
                .opacity(expanded ? 0 : 1)
                .allowsHitTesting(!expanded)

            // Mounted only while the panel is actually on screen.
            //
            // It used to stay in the tree permanently so its height was always measured, but the
            // activity glyph animates continuously whenever an agent is working, and every frame of
            // that animation drives an AppKit layout pass over the whole hosting view — including
            // this panel, with every session card, diff preview and risk strip in it, laid out at
            // full size behind a zero opacity. That was tens of percent of a core spent laying out
            // something nobody could see. `panelHeight` keeps its last value while unmounted, so the
            // morph still has a target to open toward.
            if showsPanel {
                ExpandedPanel(metrics: metrics)
                    .frame(width: prefs.maxPanelWidth)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
                        }
                    )
                    // Content rises the last few points as it fades in, so the panel reads as
                    // unfolding rather than as a box that blinks into existence at full size.
                    .offset(y: expanded ? 0 : -6)
                    .opacity(expanded ? 1 : 0)
                    .allowsHitTesting(expanded)
            }
        }
        .frame(width: currentSize.width, height: currentSize.height, alignment: .top)
        .background(chrome)
        .clipShape(NotchShape(topCornerRadius: 6, bottomCornerRadius: bottomRadius))
        .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 24, y: 10)
        .animation(Theme.morph, value: expanded)
        .animation(Theme.morph, value: panelHeight)
        .animation(Theme.morphFade, value: expanded)
        // Hit-test against the painted shape, not a bounding box, so the corners either side of
        // the notch flare don't grab the pointer.
        .contentShape(NotchShape(topCornerRadius: 6, bottomCornerRadius: bottomRadius))
        // The container is exactly the pill when collapsed and exactly the panel when open, so it
        // is the correct hover target in both states. An extra overlay rect used to do the opening
        // instead, but once it had to stay mounted it became a transparent sheet across the whole
        // panel, swallowing hover and clicks on the cards underneath.
        .onHover { hovering in
            if hovering {
                controller.hoverBegan()
            } else {
                controller.hoverEnded()
            }
        }
        // Report the painted size so the AppKit layer can hit-test only where we drew.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { interaction.report(contentSize: proxy.size) }
                    .onChange(of: proxy.size) { _, size in
                        interaction.report(contentSize: size)
                    }
            }
        )
    }

    private var bottomRadius: CGFloat {
        expanded ? Theme.rXl : 12
    }

    private var chrome: some View {
        NotchShape(topCornerRadius: 6, bottomCornerRadius: bottomRadius)
            .fill(Color.black)
            .overlay(
                NotchShape(topCornerRadius: 6, bottomCornerRadius: bottomRadius)
                    .stroke(Theme.darkLine.opacity(expanded ? 0.7 : 0), lineWidth: 0.5)
            )
    }
}

private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
