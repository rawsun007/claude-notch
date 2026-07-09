import AppKit

/// Watches global mouse movement and flips `state.isHovering` when the cursor
/// enters/leaves the hot zone at the top of the active screen.
@MainActor
final class MouseTracker {
    private weak var state: AppState?
    private weak var window: NSWindow?
    private var monitor: Any?
    private var timer: Timer?

    init(state: AppState, window: NSWindow? = nil) {
        self.state = state
        self.window = window
    }

    func attach(window: NSWindow) {
        self.window = window
    }

    func start() {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        // Backup poll — catches the case where the mouse comes to rest inside
        // the hot zone without further movement, or moves into a region
        // global monitors don't fire for (e.g. while another app is active).
        timer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        check()
    }

    func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        timer?.invalidate()
        timer = nil
    }

    /// Small zone right under the menu bar — what *triggers* a hover expand.
    /// Anchored to the screen the notch window is currently rendering on
    /// (not the screen the cursor is on) so a cursor wandering to another
    /// display doesn't drag the trigger zone with it.
    static func triggerZone(on screen: NSScreen) -> NSRect {
        let s = screen.frame
        let width: CGFloat = 340
        let height: CGFloat = max(44, screen.safeAreaInsets.top + 12)
        return NSRect(x: s.midX - width / 2, y: s.maxY - height, width: width, height: height)
    }

    /// The screen the notch is actually rendering on right now. Falls back
    /// to NSScreen.main if the window hasn't been placed yet.
    private func notchScreen() -> NSScreen {
        // Never force-unwrap screens.first: when no display is attached (lid
        // closed with no external, or mid display-reconfiguration) all of these
        // are nil/empty and .first! would crash. Fall back to a default
        // NSScreen like the rest of the app (NotchWindowController) does.
        window?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
            ?? NSScreen()
    }

    private func check() {
        guard let state else { return }
        let mouse = NSEvent.mouseLocation
        let screen = notchScreen()
        let inside: Bool
        if state.isHovering {
            inside = keepRegion(for: state).contains(mouse)
        } else {
            inside = Self.triggerZone(on: screen).contains(mouse)
        }
        state.setHovering(inside)
    }

    /// The "stay-expanded" region. Derived from the TARGET size for the
    /// current mode — NOT the window frame (which is now a big fixed panel,
    /// so frame-based would never collapse). Centred on the physical notch,
    /// generously padded so small cursor drift never collapses the card.
    private func keepRegion(for state: AppState) -> NSRect {
        let screen = notchScreen()
        let s = screen.frame
        let target = NotchView.size(for: state.mode, hovering: true, on: screen, state: state)
        let centerX: CGFloat = {
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                return (left.maxX + right.minX) / 2
            }
            return s.midX
        }()
        let width = max(target.width + 140, 460)
        let height = max(target.height + 90, 160)
        let top = s.maxY
        return NSRect(x: centerX - width / 2, y: top - height, width: width, height: height)
    }
}
