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

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let state = appState else { return super.hitTest(point) }
        let card = NotchView.size(for: state.mode, hovering: state.persistentNotchDisplay || state.isHovering, on: screenProvider(), state: state)
        // The card is pinned to the top-centre of our bounds. Add slack so
        // the card's actual (content-fit) height — which can exceed the
        // formula a touch — is always clickable.
        let slack: CGFloat = 18
        let w = card.width + slack * 2
        let h = card.height + slack * 2
        let x = bounds.midX - w / 2
        let y = isFlipped ? 0 : (bounds.height - h)
        let cardRect = NSRect(x: x, y: y, width: w, height: h)
        let local = convert(point, from: superview)
        return cardRect.contains(local) ? super.hitTest(point) : nil
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
        // Set the level LAST so it is the one that survives. Above the shielding
        // level, which is what puts it over a full-screen window; .canJoinAllSpaces
        // is what stops it staying behind on the desktop's Space while the
        // full-screen app owns its own.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
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
                self?.window.sharingType = hide ? .none : .readOnly
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
        if onlyIfDrifted, !hasDrifted(from: screen) { return }
        position(on: screen)
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

    private func logScreenGeometry() {
        var lines: [String] = ["--- ClaudeNotch geometry @ \(Date()) ---"]
        for (i, screen) in NSScreen.screens.enumerated() {
            let main = screen == NSScreen.main ? " (main)" : ""
            lines.append("screen[\(i)]\(main): frame=\(screen.frame) safeAreaTop=\(screen.safeAreaInsets.top) window=\(NotchWindowController.windowSize(for: screen))")
        }
        debugAppend(lines.joined(separator: "\n") + "\n")
    }

    private func debugAppend(_ text: String) {
        let url = URL(fileURLWithPath: "/tmp/claudenotch-debug.log")
        if let data = text.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
