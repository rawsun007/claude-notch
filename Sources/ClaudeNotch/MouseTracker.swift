import AppKit

/// Watches global mouse movement and flips `state.isHovering` when the cursor
/// enters/leaves the hot zone at the top of the active screen.
@MainActor
final class MouseTracker {
    private weak var state: AppState?
    private var monitor: Any?
    private var timer: Timer?

    init(state: AppState) {
        self.state = state
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

    /// Rect (in global screen coords) where the cursor triggers the notch to
    /// expand. Wider than the visible idle notch so it's easy to hit.
    static func hotZone(on screen: NSScreen) -> NSRect {
        let s = screen.frame
        let width: CGFloat = 320
        let height: CGFloat = max(44, (screen.safeAreaInsets.top + 12))
        return NSRect(x: s.midX - width / 2, y: s.maxY - height, width: width, height: height)
    }

    private func currentScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSPointInRect(mouse, $0.frame) })
            ?? NSScreen.main
            ?? NSScreen.screens.first!
    }

    private func check() {
        guard let state else { return }
        let inside = Self.hotZone(on: currentScreen()).contains(NSEvent.mouseLocation)
        state.setHovering(inside)
    }
}
