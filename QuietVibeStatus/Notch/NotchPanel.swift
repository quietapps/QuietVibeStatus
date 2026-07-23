import AppKit
import SwiftUI

/// A borderless always-on-top panel pinned under the notch.
///
/// Key behaviors: it never takes key or main focus (so typing keeps going to your terminal), it
/// joins every Space, and it sits above the menu bar so the pill can visually merge with the notch.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        // Above the menu bar, present on every Space, ignored by ⌘-tab and Exposé.
        level = .init(Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The panel does accept clicks (Allow/Deny buttons), it just must not steal focus.
    override var acceptsFirstResponder: Bool { false }
}

/// Hosts the SwiftUI notch content.
///
/// The panel window is deliberately much larger than the visible pill so the content can grow
/// without an AppKit frame animation fighting the SwiftUI one, which leaves most of the window
/// transparent. Passing clicks through those transparent pixels is handled at the *window* level by
/// `NotchController.updatePassthrough` toggling `ignoresMouseEvents`, so this view hit-tests
/// normally. It used to gate hit-testing here too, against a separately-tracked painted rect — but
/// two independent notions of "what is clickable" drifted apart, and a click that the window
/// accepted was then dropped here because this rect was stale, falling through to the app behind.
final class PassthroughContainerView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Hosting view that acts on the very first click.
///
/// The notch panel never becomes key — that's deliberate, so typing keeps going to your terminal.
/// But AppKit swallows the first click into a non-active window unless the view under the pointer
/// opts in, and `NSHostingView` doesn't. Without this, Allow and Deny simply did nothing whenever
/// another app was frontmost, which is exactly when you need them.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor @preconcurrency required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor @preconcurrency required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Holds the currently interactive region so `PassthroughContainerView` can hit-test it.
///
/// Deliberately *not* an `ObservableObject`. The SwiftUI view that measures the content is the same
/// one that reports it here, and the measured size changes on every frame of the expand animation.
/// If reporting a size invalidated that view, each frame would restart the transition and it would
/// never settle — which showed up as the pill and the panel both stuck on screen at half opacity.
/// Plain storage that the AppKit layer reads on demand keeps the data flowing one way.
final class NotchInteractionModel {
    private(set) var contentSize: CGSize = .zero
    /// Size of the collapsed pill, independent of the expand animation.
    ///
    /// `contentSize` morphs continuously as the panel grows and shrinks, so it can't be trusted to
    /// describe the pill's footprint mid-animation. The pill view is always laid out, so this stays
    /// the pill's real size in every state — the honest target for "is the pointer over the notch".
    private(set) var pillSize: CGSize = .zero

    /// Called after either size is reported, so the controller can re-evaluate click-through as the
    /// panel grows or shrinks. A plain closure rather than a publisher: it drives only AppKit state
    /// (`ignoresMouseEvents`), never a SwiftUI view, so it can't feed back into the layout that
    /// produced it — which is exactly the loop that made an Observable version of this unusable.
    var onSizeChange: (() -> Void)?

    func report(contentSize size: CGSize) {
        guard size != contentSize else { return }
        contentSize = size
        onSizeChange?()
    }

    func report(pillSize size: CGSize) {
        guard size != pillSize else { return }
        pillSize = size
        onSizeChange?()
    }
}
