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

    /// Small zone right under the menu bar — what *triggers* a hover expand.
    static func triggerZone(on screen: NSScreen) -> NSRect {
        let s = screen.frame
        let width: CGFloat = 340
        let height: CGFloat = max(44, screen.safeAreaInsets.top + 12)
        return NSRect(x: s.midX - width / 2, y: s.maxY - height, width: width, height: height)
    }

    /// Once expanded, we stay expanded as long as cursor is inside this larger
    /// zone — covers any card size (response detail = 640×360, question card
    /// = 600×520). Prevents the "click expand arrow → it collapses" bug.
    static func keepZone(on screen: NSScreen) -> NSRect {
        let s = screen.frame
        let width: CGFloat = 700
        let height: CGFloat = 560
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
        let mouse = NSEvent.mouseLocation
        let screen = currentScreen()
        let inside: Bool
        if state.isHovering {
            inside = Self.keepZone(on: screen).contains(mouse)
        } else {
            inside = Self.triggerZone(on: screen).contains(mouse)
        }
        state.setHovering(inside)
    }
}
