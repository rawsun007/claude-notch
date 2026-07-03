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
        let card = NotchView.size(for: state.mode, hovering: state.persistentNotchDisplay || state.isHovering, on: screenProvider())
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

    init(state: AppState) {
        self.state = state

        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        let winSize = NotchWindowController.windowSize(for: screen)
        let panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: winSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.isFloatingPanel = true
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
        let s = screen.frame
        let centerX: CGFloat = {
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                return (left.maxX + right.minX) / 2
            }
            return s.midX
        }()
        let target = NotchWindowController.windowSize(for: screen)
        let origin = NSPoint(x: centerX - target.width / 2, y: s.maxY - target.height)

        if abs(window.frame.width - target.width) > 1 || abs(window.frame.height - target.height) > 1 {
            window.setFrame(NSRect(origin: origin, size: target), display: false)
        } else if window.frame.origin != origin {
            window.setFrameOrigin(origin)
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
