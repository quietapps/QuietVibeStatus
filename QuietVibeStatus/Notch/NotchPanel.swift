import AppKit
import Combine
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

/// Hosts the SwiftUI notch content and passes clicks through everywhere the content isn't painted.
///
/// The panel's frame is deliberately much larger than the visible pill so the panel can grow
/// without an AppKit frame animation fighting the SwiftUI one. That means most of the panel is
/// transparent, and without this hit-test override those transparent pixels would swallow clicks
/// meant for the window underneath.
final class PassthroughContainerView: NSView {
    /// Region, in this view's coordinates, that should receive mouse events.
    var activeRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard activeRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

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

/// Publishes the currently interactive region so `PassthroughContainerView` can hit-test it.
///
/// Deliberately *not* an `ObservableObject`. The SwiftUI view that measures the content is the same
/// one that reports it here, and the measured size changes on every frame of the expand animation.
/// If reporting a size invalidated that view, each frame would restart the transition and it would
/// never settle — which showed up as the pill and the panel both stuck on screen at half opacity.
/// A subject the AppKit layer subscribes to keeps the data flowing one way.
final class NotchInteractionModel {
    private(set) var contentSize: CGSize = .zero

    let contentSizeChanged = PassthroughSubject<CGSize, Never>()

    func report(contentSize size: CGSize) {
        guard size != contentSize else { return }
        contentSize = size
        contentSizeChanged.send(size)
    }
}
