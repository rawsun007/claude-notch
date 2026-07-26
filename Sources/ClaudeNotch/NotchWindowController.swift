import AppKit
import SwiftUI
import Combine

/// NSPanel that overlaps the physical notch / menu-bar region and can become
/// key on demand (so our local NSEvent monitor receives Enter / Escape).
final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that passes mouse events THROUGH everywhere except the
/// currently-visible notch card. The panel is a big fixed-size window, so
/// without this, clicks anywhere in that large transparent area would be
/// swallowed instead of reaching the app underneath.
final class PassThroughHostingView: NSHostingView<NotchView> {
    weak var appState: AppState?
    var screenProvider: () -> NSScreen = { NSScreen.main ?? NSScreen.screens.first ?? NSScreen() }

    /// The clickable / droppable region: the notch card, pinned top-centre, with
    /// slack for a content-fit height that can run over the formula.
    private func cardRect() -> NSRect {
        guard let state = appState else { return .zero }
        let card = NotchView.size(for: state.mode, hovering: state.persistentNotchDisplay || state.isHovering, on: screenProvider(), state: state)
        let slack: CGFloat = 18
        // The droppable/hittable area must cover the invisible drop-catcher in
        // NotchView (300 wide x notchInset+60 tall, top-centre), or the OS never
        // routes a dragged file to it. This region sits over the hardware notch,
        // where there is nothing to click through to anyway.
        // Inset from THIS panel's screen, not the shared primary value — a
        // mirror over a non-notch external uses that screen's menu-bar band, so
        // its collapsed hit/drop region must match the pill it actually draws.
        // For the primary this equals state.notchTopInset, so it is unchanged.
        let inset = NotchView.notchInset(on: screenProvider())
        let w = max(card.width + slack * 2, 240)
        let h = max(card.height + slack * 2, inset + 30)
        return NSRect(x: bounds.midX - w / 2,
                      y: isFlipped ? 0 : (bounds.height - h),
                      width: w, height: h)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard appState != nil else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return cardRect().contains(local) ? super.hitTest(point) : nil
    }
}

@MainActor
final class NotchWindowController {
    let state: AppState
    let window: NotchPanel
    private let host: PassThroughHostingView
    private var cancellable: AnyCancellable?
    private var captureCancellable: AnyCancellable?
    private var screenObservers: [NSObjectProtocol] = []
    private var driftTimer: Timer?

    /// One extra panel per NON-primary screen, so the notch/pill is present on
    /// every display at once (the primary panel above still follows the cursor
    /// and owns hover + keyboard; these mirror the same shared state and are
    /// clickable/droppable because the buttons act on `state` directly). Keyed
    /// by display id so a mirror survives repositioning and only rebuilds when a
    /// display is actually added or removed. Empty in the single-screen case, so
    /// that path is byte-for-byte the old behavior.
    private var mirrors: [CGDirectDisplayID: NotchPanel] = [:]

    init(state: AppState) {
        self.state = state

        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        let winSize = NotchWindowController.windowSize(for: screen)
        // Born where it belongs. Created at the origin and moved afterwards, the
        // panel briefly existed at the bottom-left corner of the screen — which
        // the drift log caught on every single launch, and which is a card-shaped
        // thing sitting in the wrong place for as long as it takes the first
        // position() to run.
        let panel = NotchPanel(
            contentRect: NSRect(origin: NotchWindowController.origin(on: screen, size: winSize),
                                size: winSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        // ORDER MATTERS. `isFloatingPanel` is not an extra flag on top of the
        // level: setting it true assigns the level to .floating (3). It was being
        // set AFTER the level, so every level we thought we were choosing was
        // being thrown away, and the notch has been living at level 3 — under
        // ordinary windows, and under any app in full screen. That is why moving
        // the cursor to the notch inside a full-screen app did nothing: the notch
        // was behind the app, not ignoring the mouse.
        panel.isFloatingPanel = true
        // Set the level LAST so it is the one that survives.
        //
        // It used to be CGShieldingWindowLevel() (~2.1 billion). That does put
        // the panel over everything, but the WindowServer excludes windows at or
        // above the shielding level from drag-and-drop destination routing — a
        // dragged file is never delivered to such a window, which is exactly why
        // dropping a folder on the notch did nothing and the file fell to the
        // desktop. `.mainMenu + 3` (~27) is what boring.notch uses: it still sits
        // above the menu bar, and .fullScreenAuxiliary + .canJoinAllSpaces (set
        // in collectionBehavior above) are what actually float it over a
        // full-screen app's Space — the level does not need to be astronomical
        // for that. This level keeps the notch over full screen AND makes it a
        // real drag destination.
        panel.level = .mainMenu + 3
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        // Keep the notch out of screen shares / recordings / other apps'
        // screenshots — it renders commands, file paths, and code snippets.
        // .none excludes the window from capture; the user still sees it live.
        panel.sharingType = state.hideFromScreenCapture ? .none : .readOnly

        let host = PassThroughHostingView(rootView: NotchView(state: state))
        host.appState = state

        host.frame = NSRect(origin: .zero, size: winSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        self.window = panel
        self.host = host
        host.screenProvider = { [weak self] in self?.currentScreen() ?? NSScreen.main ?? NSScreen.screens.first ?? NSScreen() }

        position(on: screen)

        // The window NEVER resizes per mode — the SwiftUI card animates inside
        // it. On a mode/hover change we only (a) re-position if the active
        // screen changed and (b) grab key focus for interactive cards.
        cancellable = Publishers.CombineLatest(state.$mode, state.$isHovering)
            .receive(on: RunLoop.main)
            .sink { [weak self] mode, _ in
                guard let self else { return }
                self.position(on: self.currentScreen())
                self.syncMirrors()
                // Compose, question, and history host text fields (the
                // composer's editor; the question card's "Other" answer; the
                // history drawer's search box), so they must become key to
                // receive typing. Every other card's
                // Enter/Esc is handled by the global CGEventTap in
                // KeyboardMonitor WITHOUT stealing focus, so we don't hijack
                // the keyboard or interrupt their open animation.
                switch mode {
                case .compose, .question, .history:
                    self.window.makeKey()
                default:
                    break
                }
            }

        captureCancellable = state.$hideFromScreenCapture
            .receive(on: RunLoop.main)
            .sink { [weak self] hide in
                guard let self else { return }
                let type: NSWindow.SharingType = hide ? .none : .readOnly
                self.window.sharingType = type
                for panel in self.mirrors.values { panel.sharingType = type }
            }

        observeScreenChanges()
    }

    /// Re-pin the panel whenever the world moves under it.
    ///
    /// The panel used to reposition ONLY on a mode or hover change, which meant
    /// anything that moved the screen out from under it — a resolution change, a
    /// display sleep/wake, plugging in a monitor, switching Space — left it at a
    /// stale origin until the next card happened to open. A stale origin is very
    /// visible: the collapsed card is meant to hide exactly behind the hardware
    /// notch, so a card that is off by even a little stops being invisible and
    /// becomes a second, fake notch sitting next to the real one with its status
    /// bars on show.
    private func observeScreenChanges() {
        let center = NotificationCenter.default
        screenObservers.append(
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                               object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.repin() }
            }
        )
        screenObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.repin() }
                }
        )
        // The events above cover what macOS tells us about. They do not cover
        // everything that has been observed to displace a borderless panel, so
        // there is also a slow backstop: check the frame now and then and put it
        // back if it has moved. It costs nothing when nothing is wrong.
        driftTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.repin(onlyIfDrifted: true) }
        }
    }

    /// Put the panel back where it belongs. With `onlyIfDrifted`, does nothing
    /// unless it has actually moved (so the common case is a cheap comparison).
    private func repin(onlyIfDrifted: Bool = false) {
        let screen = currentScreen()
        if !onlyIfDrifted || hasDrifted(from: screen) {
            position(on: screen)
        }
        // Always reconcile mirrors: a display can be added/removed without the
        // primary panel itself drifting off its origin.
        syncMirrors()
    }

    /// True when the panel is no longer centred on the notch of `screen`, or has
    /// slipped off its top edge.
    private func hasDrifted(from screen: NSScreen) -> Bool {
        let target = expectedOrigin(on: screen)
        return abs(window.frame.origin.x - target.x) > 1 || abs(window.frame.origin.y - target.y) > 1
    }

    private func expectedOrigin(on screen: NSScreen) -> NSPoint {
        NotchWindowController.origin(on: screen, size: NotchWindowController.windowSize(for: screen))
    }

    /// Top of the screen, centred on the physical notch. Static so the panel can
    /// be *created* here rather than created somewhere else and moved.
    static func origin(on screen: NSScreen, size: CGSize) -> NSPoint {
        let s = screen.frame
        let centerX: CGFloat = {
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                return (left.maxX + right.minX) / 2
            }
            return s.midX
        }()
        return NSPoint(x: centerX - size.width / 2, y: s.maxY - size.height)
    }

    deinit {
        driftTimer?.invalidate()
        for o in screenObservers { NotificationCenter.default.removeObserver(o) }
    }

    /// Fixed window: wide enough for the biggest card, tall enough for the
    /// tallest drawer, capped to the screen.
    static func windowSize(for screen: NSScreen) -> CGSize {
        let h = min(760, screen.frame.height * 0.85)
        return CGSize(width: 780, height: h)
    }

    func show() {
        logScreenGeometry()
        position(on: currentScreen())
        window.orderFrontRegardless()
        syncMirrors()
    }

    private func currentScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSPointInRect(mouse, $0.frame) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    /// Pin the (fixed-size) window to the top, centred on the physical notch.
    /// Only resizes if the screen actually changed dimensions.
    private func position(on screen: NSScreen) {
        let target = NotchWindowController.windowSize(for: screen)
        let origin = expectedOrigin(on: screen)
        let was = window.frame.origin

        if abs(window.frame.width - target.width) > 1 || abs(window.frame.height - target.height) > 1 {
            window.setFrame(NSRect(origin: origin, size: target), display: false)
        } else if window.frame.origin != origin {
            window.setFrameOrigin(origin)
        }

        // A correction of more than a point means the panel had genuinely been
        // displaced (the "second notch beside the real one" bug). Worth a line:
        // it is the only way to find out what moved it.
        if abs(was.x - origin.x) > 1 || abs(was.y - origin.y) > 1 {
            debugAppend("[\(Date())] repin: \(was) → \(origin) on screen \(screen.frame)\n")
        }

        let inset = NotchView.notchInset(on: screen)
        if abs(state.notchTopInset - inset) > 0.5 { state.notchTopInset = inset }
    }

    // MARK: - Per-screen mirror panels

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Ensure exactly one mirror panel exists on every screen the primary panel
    /// is NOT currently on, and none linger on a removed display or on the
    /// primary's own screen. Cheap and idempotent — safe to call on every repin.
    private func syncMirrors() {
        let primaryID = Self.displayID(of: currentScreen())
        // Desired mirror screens: every attached screen except the primary's.
        var desired: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            let id = Self.displayID(of: screen)
            if id != primaryID { desired[id] = screen }
        }
        // Drop mirrors whose screen vanished or became the primary.
        for (id, panel) in mirrors where desired[id] == nil {
            panel.orderOut(nil)
            mirrors.removeValue(forKey: id)
        }
        // Add/reposition mirrors for the desired screens.
        for (id, screen) in desired {
            let panel = mirrors[id] ?? makeMirror(on: screen)
            mirrors[id] = panel
            positionMirror(panel, on: screen)
            panel.orderFrontRegardless()
        }
    }

    /// Build a mirror panel: same chrome as the primary, but pinned to a fixed
    /// screen and rendering NotchView with that screen as its geometry source.
    /// Non-key (it never steals focus); its buttons still work because they act
    /// on the shared AppState, and Enter/Esc are handled globally.
    private func makeMirror(on screen: NSScreen) -> NotchPanel {
        let size = NotchWindowController.windowSize(for: screen)
        let panel = NotchPanel(
            contentRect: NSRect(origin: NotchWindowController.origin(on: screen, size: size), size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 3
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.sharingType = state.hideFromScreenCapture ? .none : .readOnly

        let host = PassThroughHostingView(rootView: NotchView(state: state, screenOverride: screen))
        host.appState = state
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        host.screenProvider = { screen }
        panel.contentView = host
        return panel
    }

    private func positionMirror(_ panel: NotchPanel, on screen: NSScreen) {
        let size = NotchWindowController.windowSize(for: screen)
        let origin = NotchWindowController.origin(on: screen, size: size)
        if abs(panel.frame.width - size.width) > 1 || abs(panel.frame.height - size.height) > 1 {
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        } else if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
    }

    private func logScreenGeometry() {
        var lines: [String] = ["--- ClaudeNotch geometry @ \(Date()) ---"]
        for (i, screen) in NSScreen.screens.enumerated() {
            let main = screen == NSScreen.main ? " (main)" : ""
            lines.append("screen[\(i)]\(main): frame=\(screen.frame) safeAreaTop=\(screen.safeAreaInsets.top) window=\(NotchWindowController.windowSize(for: screen))")
        }
        debugAppend(lines.joined(separator: "\n") + "\n")
    }

    private func debugAppend(_ text: String) { DebugLog.append("geometry", text) }
}
