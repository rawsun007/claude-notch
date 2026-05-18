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
        window?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first!
    }

    private func check() {
        guard let state else { return }
        let mouse = NSEvent.mouseLocation
        let screen = notchScreen()
        let inside: Bool
        if state.isHovering {
            // Once expanded, keep it open as long as the cursor is anywhere
            // near the visible panel. We use the panel's actual frame
            // (padded) — this is robust to display changes, panel resizes
            // and cursor flips between screens.
            inside = keepRegion().contains(mouse)
        } else {
            inside = Self.triggerZone(on: screen).contains(mouse)
        }
        state.setHovering(inside)
    }

    /// The "stay-expanded" region: the actual notch window frame, generously
    /// padded so the cursor has slack while moving toward / over the UI.
    /// Falls back to a fixed top-of-screen rect if we don't have a window yet.
    private func keepRegion() -> NSRect {
        guard let frame = window?.frame, frame.width > 0 else {
            let s = notchScreen().frame
            return NSRect(x: s.midX - 360, y: s.maxY - 580, width: 720, height: 580)
        }
        // Pad: 60pt horizontal slack so the cursor approaching from the side
        // counts as inside; 40pt below the panel so a small drift down
        // doesn't immediately collapse; extend UP to the top of the screen
        // so the cursor going over the physical notch / menu bar is fine.
        let screenTop = notchScreen().frame.maxY
        let top = max(frame.maxY, screenTop)
        let bottom = frame.minY - 40
        return NSRect(
            x: frame.minX - 60,
            y: bottom,
            width: frame.width + 120,
            height: top - bottom
        )
    }
}
