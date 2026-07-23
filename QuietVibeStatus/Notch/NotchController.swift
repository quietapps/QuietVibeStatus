import AppKit
import Combine
import SwiftUI

/// How the notch is currently presented.
enum NotchPresentation: Equatable {
    /// Just the pill under the notch.
    case collapsed
    /// Full panel, opened by hover.
    case hovered
    /// Full panel, opened by an event (completion, warning) — auto-collapses after the dwell time.
    case revealed
    /// Full panel, opened because something is blocking on the user. Stays until resolved.
    case attention
    /// Full panel, pinned open by a click.
    case pinned

    var isExpanded: Bool { self != .collapsed }
    /// Whether this presentation should survive the mouse leaving the panel.
    var isSticky: Bool { self == .attention || self == .pinned }
}

/// Owns the notch panel: placement, expansion state, and the rules about when to show up.
@MainActor
final class NotchController: ObservableObject {
    static let shared = NotchController()

    @Published private(set) var presentation: NotchPresentation = .collapsed
    /// Notch geometry per display. Two displays can have different notches — or none at all — so
    /// each panel reads the entry for the screen it is on rather than a single global value.
    @Published private(set) var metricsByScreen: [CGDirectDisplayID: NotchMetrics] = [:]

    /// One panel per targeted display. In `All Displays` mode this is every screen; otherwise it
    /// holds a single entry that moves as the target changes.
    private var panels: [CGDirectDisplayID: NotchPanel] = [:]
    private var interactions: [CGDirectDisplayID: NotchInteractionModel] = [:]
    private var hiddenScreens: Set<CGDirectDisplayID> = []

    private var dwellTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    /// Pending collapse after the pointer appears to have left; see `hoverEnded`.
    private var leaveTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private let prefs = Preferences.shared
    private let store = SessionStore.shared

    /// Panel is sized to the largest it could ever need, then paints a smaller pill inside.
    private var panelSize: CGSize {
        CGSize(width: prefs.maxPanelWidth + 80, height: prefs.maxPanelHeight + 80)
    }

    /// Watches the pointer while the panels are click-through, so they can be armed before it
    /// arrives — see `updatePassthrough`.
    private var pointerMonitor: Any?
    /// Which panels currently accept mouse events, so the flag is only written when it changes.
    private var interactivePanels: Set<CGDirectDisplayID> = []

    private init() {}

    // MARK: - Lifecycle

    func start() {
        rebuildPanels()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildPanels() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.refreshVisibility() }
            .store(in: &cancellables)

        // Follow-focus: when the active app moves to another display, the notch follows.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.prefs.displayTarget == .followFocus else { return }
                self.rebuildPanelsIfTargetsChanged()
            }
            .store(in: &cancellables)

        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshVisibility() }
            .store(in: &cancellables)

        // The panels are click-through except where the pointer is actually over what they paint.
        //
        // This replaces resizing the window to match the content. Resizing worked — the dead zone
        // went away — but every resize rebuilds the window's tracking areas, and the spurious hover
        // enter/exit that produced drove the presentation, which resized the window again: the panel
        // flapped open and shut tens of times a second. A fixed window with a moving passthrough
        // flag has no such loop, and `hitTest` alone can't do it because returning nil drops a click
        // rather than passing it to the window underneath.
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePassthrough()
            }
        }
        updatePassthrough()

        // A panel that opens on its own — an approval, a completion reveal — appears under a
        // pointer that never moved, so no pointer event will arrive to arm it. Without this the
        // card was visible but its buttons weren't clickable: the clicks went straight through to
        // the window behind.
        $presentation
            .removeDuplicates()
            .sink { [weak self] _ in
                // After the state has settled into the frame SwiftUI will draw for it.
                Task { @MainActor in self?.updatePassthrough() }
            }
            .store(in: &cancellables)

        // Outside-click dismissal for completion reveals. A global monitor observes clicks in
        // other apps without consuming them, so this never steals a click from your editor.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.prefs.dismissRevealOnOutsideClick else { return }
                guard self.presentation == .revealed else { return }
                guard !self.pointerIsOverContent else { return }
                self.collapseNow()
            }
        }

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshVisibility()
                self.rebuildPanelsIfTargetsChanged()
                // Backstop: the panel's painted size also changes as cards come and go, which no
                // pointer event announces.
                self.updatePassthrough()
            }
        }
    }

    // MARK: - Placement

    /// Which displays should carry a panel right now.
    private func targetScreens() -> [NSScreen] {
        switch prefs.displayTarget {
        case .allDisplays:
            return NSScreen.screens
        case .builtIn:
            return [NSScreen.notched ?? NSScreen.main].compactMap { $0 }
        case .followFocus:
            return [NSScreen.screenUnderPointer ?? NSScreen.notched ?? NSScreen.main].compactMap { $0 }
        }
    }

    private func rebuildPanels() {
        let screens = targetScreens()
        var wanted: Set<CGDirectDisplayID> = []

        for screen in screens {
            guard let id = screen.displayID else { continue }
            wanted.insert(id)

            metricsByScreen[id] = NotchMetrics.forScreen(screen)

            let panel = panels[id] ?? makePanel(for: id)
            panels[id] = panel

            applyFrame(to: panel, on: screen, id: id)
            panel.orderFrontRegardless()
        }

        // Retire panels on displays we no longer target — an unplugged monitor, or a mode change
        // from All Displays back to one.
        for (id, panel) in panels where !wanted.contains(id) {
            panel.orderOut(nil)
            panels.removeValue(forKey: id)
            interactions.removeValue(forKey: id)
            metricsByScreen.removeValue(forKey: id)
            hiddenScreens.remove(id)
        }

        refreshVisibility()
    }

    /// Pins one panel's window under the notch at its full, fixed size.
    ///
    /// The window is always the size of the open panel, so most of it is transparent. It does not
    /// resize between states — that path was tried and rejected, because every resize rebuilt the
    /// window's tracking areas and the spurious hover enter/exit that produced drove the panel to
    /// flap open and shut. Instead the transparent region is made click-through at runtime by
    /// `updatePassthrough`, so a fixed-size window still lets clicks reach whatever is behind it.
    private func applyFrame(to panel: NotchPanel, on screen: NSScreen, id _: CGDirectDisplayID) {
        let size = panelSize
        let frame = CGRect(
            origin: CGPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - size.height
            ),
            size: size
        )
        // The window is one fixed size for the life of the panel; only a display change moves it.
        // Setting a frame it already has would rebuild its tracking areas for nothing.
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: false)
    }

    /// Lets clicks through wherever a panel isn't painting anything.
    ///
    /// A panel is the size of the *open* panel at all times, so most of it is transparent. Those
    /// transparent points belong to whatever is behind them: `ignoresMouseEvents` is the only thing
    /// that actually hands the click to the window underneath.
    ///
    /// The pointer is watched globally rather than through SwiftUI's hover, because a click-through
    /// window receives no events at all — it has to be armed *before* the pointer arrives, and the
    /// global monitor sees the moves that are being delivered to other apps. Once armed, the panel
    /// takes events normally and SwiftUI's own hover drives the opening.
    private func updatePassthrough() {
        let painted = paintedRects()
        let location = NSEvent.mouseLocation

        for (id, panel) in panels {
            // A hidden panel is never interactive, whatever the pointer is doing.
            let interactive = !hiddenScreens.contains(id)
                && (painted[id]?.contains(location) ?? false)

            guard interactive != interactivePanels.contains(id) else { continue }
            if interactive { interactivePanels.insert(id) } else { interactivePanels.remove(id) }
            panel.ignoresMouseEvents = !interactive
        }
    }

    /// The interactive region of each panel, in screen coordinates.
    ///
    /// Collapsed, that is the pill's own footprint and nothing else — the whole point is that the
    /// rest of the screen under this oversized window stays clickable.
    ///
    /// Expanded, it is the panel's *maximum* footprint, not the measured content. The content height
    /// animates open over a third of a second and the measurement lags it, so gating on the live
    /// size left every card below the current height click-through until the animation and the
    /// measurement caught up — which under a stationary pointer they never did. The max footprint is
    /// a fixed rectangle available the instant the panel starts opening, so a card is clickable as
    /// soon as it is visible. Clicks in the transparent margin outside `maxPanelWidth`, or below the
    /// tallest the panel could be, still pass through.
    private func paintedRects() -> [CGDirectDisplayID: CGRect] {
        var rects: [CGDirectDisplayID: CGRect] = [:]

        for (id, panel) in panels {
            let size: CGSize
            if presentation == .collapsed {
                let pill = interactions[id]?.pillSize ?? .zero
                if pill.width > 1, pill.height > 1 {
                    size = pill
                } else if let metrics = metricsByScreen[id] {
                    size = CGSize(width: metrics.size.width + 68, height: metrics.size.height)
                } else {
                    continue
                }
            } else {
                size = CGSize(width: prefs.maxPanelWidth, height: prefs.maxPanelHeight)
            }

            rects[id] = CGRect(
                x: panel.frame.midX - size.width / 2,
                y: panel.frame.maxY - size.height,
                width: size.width,
                height: size.height
            )
        }

        return rects
    }

    private func rebuildPanelsIfTargetsChanged() {
        let wanted = Set(targetScreens().compactMap(\.displayID))
        guard wanted != Set(panels.keys) else { return }
        rebuildPanels()
    }

    private func makePanel(for id: CGDirectDisplayID) -> NotchPanel {
        let panel = NotchPanel(contentRect: CGRect(origin: .zero, size: panelSize))
        let container = PassthroughContainerView()
        container.autoresizingMask = [.width, .height]

        let interaction = NotchInteractionModel()
        interactions[id] = interaction
        // As the panel grows or shrinks under a stationary pointer, re-decide what takes clicks —
        // otherwise a card the pointer is already sitting over stays click-through until the next
        // pointer move or the periodic sweep.
        interaction.onSizeChange = { [weak self] in
            Task { @MainActor in self?.updatePassthrough() }
        }

        let root = NotchRootView(screenID: id, interaction: interaction)
            .environmentObject(self)
            .environmentObject(store)
            .environmentObject(prefs)

        // Click-through for the transparent parts is handled at the window level (see
        // `updatePassthrough`), so the container hit-tests normally.
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        container.addSubview(hosting)
        panel.contentView = container

        return panel
    }

    // MARK: - Visibility

    /// Applies the "should the notch even be on screen right now" rules, per display.
    ///
    /// Fullscreen is a property of one screen, not of the app, so with panels on several displays
    /// each is judged on its own — a fullscreen video on one monitor shouldn't blank the notch on
    /// the other.
    private func refreshVisibility() {
        let screensByID = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                screen.displayID.map { ($0, screen) }
            }
        )

        for (id, panel) in panels {
            var hide = false

            if prefs.hideInFullscreen, let screen = screensByID[id], screen.hasFullscreenWindow {
                hide = true
            }
            if prefs.autoHideWhenEmpty, store.sessions.isEmpty, presentation == .collapsed {
                hide = true
            }

            let wasHidden = hiddenScreens.contains(id)
            guard hide != wasHidden else { continue }

            if hide { hiddenScreens.insert(id) } else { hiddenScreens.remove(id) }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = hide ? 0 : 1
            }
        }

        // A fully transparent window still hit-tests, so a hidden panel has to stop taking events —
        // but that flag has one owner, `updatePassthrough`, or the two fight over it.
        updatePassthrough()
    }

    /// Whether a panel is on screen anywhere the user could actually see it.
    ///
    /// False when every panel is hidden — fullscreen on each display, or auto-hidden — which is
    /// exactly when a blocking request needs to reach you some other way.
    var panelIsVisible: Bool {
        guard !panels.isEmpty else { return false }
        return hiddenScreens.count < panels.count
    }

    // MARK: - Expansion

    func hoverBegan() {
        // Any pending collapse is stale the moment the pointer is back over the panel.
        leaveTask?.cancel()
        leaveTask = nil

        guard prefs.expandOnHover, !presentation.isSticky else { return }
        guard presentation != .hovered else { return }

        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            guard let self else { return }
            let delay = self.prefs.hoverDuration
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Checked here and nowhere else. SwiftUI reports hover against the container's animated
            // frame, so a panel shrinking past a stationary pointer fires an enter event from dead
            // space well below the pill; by the time the hover delay has run, the geometry has
            // settled and that event can be told apart from a real one. Gating the *arrival* of the
            // event as well, as 1.0.8 did, only added a way for a legitimate hover to be dropped.
            guard self.pointerIsOverTrigger else { return }
            // No suppression check here on purpose: hovering the notch is a deliberate request to
            // see the panel. Smart suppression exists to stop the panel *auto*-expanding over the
            // window you're working in — applying it to hover meant the notch simply refused to
            // open while an agent's app was frontmost, which is most of the time.
            // Retire cards whose agent died since the last sweep, so the panel never opens on a
            // session that ended a few seconds ago.
            self.store.pruneDeadSessions()
            withAnimation(Theme.easeSlow) { self.presentation = .hovered }
        }
    }

    /// The pointer left the trigger area before the hover delay elapsed — drop the pending open.
    func hoverCancelled() {
        hoverTask?.cancel()
        hoverTask = nil
    }

    /// Collapsing is deliberately delayed and then double-checked against the real pointer position.
    ///
    /// Expanding swaps the pill view out for the panel view, which tears down one SwiftUI tracking
    /// area and builds another. In the gap SwiftUI reports "not hovering" even though the pointer
    /// never moved. Collapsing on that immediately put the pill back under the cursor, which
    /// re-triggered hover — the panel flickered open and shut. The grace period absorbs the gap,
    /// and the geometry check means a stale event can never close a panel you're still pointing at.
    func hoverEnded() {
        hoverTask?.cancel()
        guard prefs.autoCollapseOnMouseLeave else { return }
        guard presentation == .hovered else { return }

        leaveTask?.cancel()
        leaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.hoverGracePeriod * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.presentation == .hovered else { return }
            guard !self.pointerIsOverContent else { return }
            self.collapseNow()
        }
    }

    /// Collapse, then re-arm hover if the pointer is still sitting over the pill.
    ///
    /// SwiftUI only reports hover on a transition. When the panel shrinks out from under a
    /// stationary pointer there is no fresh enter event, so without this the notch would ignore
    /// hover until the mouse moved — the intermittent "hover stopped working" case.
    private func collapseNow() {
        withAnimation(Theme.easeSlow) { presentation = .collapsed }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, self.presentation == .collapsed else { return }
            // Check the pill footprint, not the content size. The collapse animation runs ~0.35s
            // but this fires after 120ms, so `contentSize` is still mid-shrink and panel-sized —
            // testing against it re-opened the notch whenever the pointer sat anywhere in the
            // former panel's area, well away from the pill itself.
            guard self.pointerIsOverPill else { return }
            self.hoverBegan()
        }
    }

    /// How long to wait before believing the pointer really left.
    private static let hoverGracePeriod: Double = 0.25

    /// The region that may open the notch, or hold it open, right now.
    ///
    /// Collapsed, that is the pill and nothing else: the panel's footprint is stale in that state
    /// and treating it as live made the empty screen under the notch behave like a trigger.
    /// Expanded, the whole painted panel counts, so moving across the cards keeps it up.
    private var pointerIsOverTrigger: Bool {
        presentation == .collapsed ? pointerIsOverPill : pointerIsOverContent
    }

    /// Whether the pointer is inside the region SwiftUI actually painted, on *any* panel.
    private var pointerIsOverContent: Bool {
        pointerIsOver { interactions[$0]?.contentSize }
    }

    /// Whether the pointer is over the collapsed pill, on *any* panel.
    ///
    /// Uses the stable pill footprint rather than the morphing content size, so it stays honest
    /// while the panel is animating open or shut.
    ///
    /// A panel that has not reported its pill yet falls back to the notch's own metrics instead of
    /// counting as "pointer isn't here". Reporting is what proves the panel has laid out, and on a
    /// second display that can lag behind the first — treating unmeasured as absent left that screen
    /// refusing to open until something else made it lay out.
    private var pointerIsOverPill: Bool {
        pointerIsOver { id in
            if let measured = interactions[id]?.pillSize, measured.width > 1, measured.height > 1 {
                return measured
            }
            guard let metrics = metricsByScreen[id] else { return nil }
            // Same fallback the pill view uses before it has drawn once.
            return CGSize(width: metrics.size.width + 68, height: metrics.size.height)
        }
    }

    private func pointerIsOver(_ size: (CGDirectDisplayID) -> CGSize?) -> Bool {
        let location = NSEvent.mouseLocation

        // No usable geometry anywhere means we cannot answer the question. Say yes: a hover the
        // user actually made must not be dropped because a panel hasn't measured itself yet.
        let known = panels.keys.compactMap(size).filter { $0.width > 1 && $0.height > 1 }
        guard !known.isEmpty else { return true }

        return panels.contains { id, panel in
            guard let size = size(id), size.width > 1, size.height > 1 else { return false }

            // Content is anchored to the top-center of the panel; AppKit's origin is bottom-left.
            let rect = CGRect(
                x: panel.frame.midX - size.width / 2,
                y: panel.frame.maxY - size.height,
                width: size.width,
                height: size.height
            )
            return rect.contains(location)
        }
    }

    func togglePinned() {
        withAnimation(Theme.easeSlow) {
            presentation = presentation == .pinned ? .collapsed : .pinned
        }
    }

    /// Open the panel the way a completion does: visible for the dwell time, then back to the pill.
    ///
    /// This is what the menu bar's "Show Panel" uses. Pinning it open instead meant the only way
    /// back to the pill was to go find the menu item again.
    func revealTemporarily() {
        guard presentation != .attention else { return }
        withAnimation(Theme.easeSlow) { presentation = .revealed }
        scheduleDwellCollapse()
    }

    func collapse() {
        dwellTask?.cancel()
        collapseNow()
    }

    /// Open the panel because a session finished or errored, then close after the dwell time.
    func reveal(for session: Session) {
        guard prefs.expandForCompletions else { return }
        guard !shouldSuppressReveal(for: session) else { return }
        store.highlightedID = session.id
        withAnimation(Theme.easeSlow) { presentation = .revealed }
        scheduleDwellCollapse()
    }

    /// Open and stay open — something is blocking on the user.
    func demandAttention(sessionID: String) {
        dwellTask?.cancel()
        store.highlightedID = sessionID
        withAnimation(Theme.easeSlow) { presentation = .attention }
    }

    /// Called when the last blocking card is resolved.
    func attentionResolved() {
        guard presentation == .attention else { return }
        if store.blockedSessions.isEmpty {
            withAnimation(Theme.easeSlow) { presentation = .collapsed }
        }
    }

    private func scheduleDwellCollapse() {
        dwellTask?.cancel()
        let dwell = prefs.autoRevealDwell
        // "Until dismissed": leave it up. Hover-collapse, a click elsewhere, and the collapse
        // shortcut all still close it, so this can't strand the panel open.
        guard dwell > 0 else { return }
        dwellTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.presentation == .revealed else { return }
            self.collapseNow()
        }
    }

    /// Smart suppression: if you're already looking at the host of *this* session, an automatic
    /// reveal would cover the thing it is telling you about.
    ///
    /// Scoped to the session's own host. Matching any known terminal or IDE was far too broad —
    /// with Cursor frontmost, every session in the list counted as "you're already looking at it".
    private func shouldSuppressReveal(for session: Session) -> Bool {
        guard prefs.smartSuppression else { return false }
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        guard let host = session.runningHost, let hostID = host.bundleID else { return false }
        return front == hostID
    }
}
