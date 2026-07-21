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
    private var panelSubscriptions: [CGDirectDisplayID: AnyCancellable] = [:]
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

            let size = panelSize
            panel.setFrame(
                CGRect(
                    origin: CGPoint(
                        x: screen.frame.midX - size.width / 2,
                        y: screen.frame.maxY - size.height
                    ),
                    size: size
                ),
                display: false
            )
            panel.orderFrontRegardless()
        }

        // Retire panels on displays we no longer target — an unplugged monitor, or a mode change
        // from All Displays back to one.
        for (id, panel) in panels where !wanted.contains(id) {
            panel.orderOut(nil)
            panels.removeValue(forKey: id)
            interactions.removeValue(forKey: id)
            panelSubscriptions.removeValue(forKey: id)
            metricsByScreen.removeValue(forKey: id)
            hiddenScreens.remove(id)
        }

        refreshVisibility()
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

        let root = NotchRootView(screenID: id, interaction: interaction)
            .environmentObject(self)
            .environmentObject(store)
            .environmentObject(prefs)

        let hosting = FirstMouseHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        container.addSubview(hosting)
        panel.contentView = container

        // Keep the passthrough region in sync with what SwiftUI actually painted.
        panelSubscriptions[id] = interaction.contentSizeChanged
            .receive(on: RunLoop.main)
            .sink { [weak container, weak panel] size in
                guard let container, let panel else { return }
                let w = max(size.width, 1)
                let h = max(size.height, 1)
                container.activeRect = CGRect(
                    x: (panel.frame.width - w) / 2,
                    y: panel.frame.height - h,
                    width: w,
                    height: h
                )
            }

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

    /// Whether the pointer is inside the region SwiftUI actually painted, on *any* panel.
    private var pointerIsOverContent: Bool {
        pointerIsOver { interactions[$0]?.contentSize }
    }

    /// Whether the pointer is over the collapsed pill, on *any* panel.
    ///
    /// Uses the stable pill footprint rather than the morphing content size, so it stays honest
    /// while the panel is animating open or shut.
    private var pointerIsOverPill: Bool {
        pointerIsOver { interactions[$0]?.pillSize }
    }

    private func pointerIsOver(_ size: (CGDirectDisplayID) -> CGSize?) -> Bool {
        let location = NSEvent.mouseLocation

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
