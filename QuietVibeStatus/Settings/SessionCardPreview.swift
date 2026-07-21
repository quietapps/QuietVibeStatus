import SwiftUI

/// Live preview of a session card, rendered on the notch's own black surface.
///
/// This renders the **real** `SessionCard` with a sample session rather than a mock-up. A hand-built
/// facsimile would drift from the panel the first time either changed; sharing the view means
/// whatever you see here is literally what the notch draws.
///
/// The card is laid out at the panel's true width and then scaled to fit, so proportions match the
/// notch exactly. Critically it sits in an `overlay`, which takes its size *from* this view rather
/// than contributing to it — otherwise a card laid out at 800pt pushed the Settings window itself
/// out to 800pt every time the Max panel width slider moved.
struct SessionCardPreview: View {
    @EnvironmentObject private var prefs: Preferences

    /// Width available inside the settings pane.
    @State private var available: CGFloat = 0
    /// Natural height of the card at full size, measured from the card itself so the preview
    /// resizes correctly when a toggle or the font size changes its content.
    @State private var cardHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Color.clear
                .frame(height: max(cardHeight * scale, 60))
                .frame(maxWidth: .infinity)
                .background(widthReader)
                .overlay(alignment: .topLeading) {
                    card.scaleEffect(scale, anchor: .topLeading)
                }
                .clipped()
                .animation(Theme.ease, value: cardHeight)
        }
        .onPreferenceChange(PreviewCardHeightKey.self) { cardHeight = $0 }
    }

    private var card: some View {
        SessionCard(session: .preview)
            .padding(.vertical, 6)
            .frame(width: prefs.maxPanelWidth)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
            // Inert: this is an illustration, not a live card. Without this, clicking it would try
            // to jump to a terminal and the archive button would file a fake session away.
            .allowsHitTesting(false)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: PreviewCardHeightKey.self, value: proxy.size.height)
                }
            )
    }

    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { available = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in available = width }
        }
    }

    /// Shrink only as much as needed. A panel narrower than the pane is shown at full size rather
    /// than blown up, so the preview never reads as bigger than the real thing.
    private var scale: CGFloat {
        guard available > 1 else { return 1 }
        return min(1, available / prefs.maxPanelWidth)
    }
}

private struct PreviewCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
