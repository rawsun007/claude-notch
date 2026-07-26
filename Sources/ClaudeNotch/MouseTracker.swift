import AppKit

/// Watches global mouse movement and flips `state.isHovering` when the cursor
/// enters/leaves the hot zone at the top of the active screen.
@MainActor
final class MouseTracker {
    private weak var state: AppState?
    private weak var window: NSWindow?
    private var monitor: Any?
    private var timer: Timer?

    /// Called when the cursor is at the top of a screen the notch is not
    /// currently on, so the owner can migrate the interactive panel there. On a
    /// single display this never fires (the hovered screen is the notch screen).
    var onWantScreen: ((NSScreen) -> Void)?

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
        // Follow the cursor across displays: if it is in the top trigger band of
        // a screen the notch is not on, ask the owner to migrate the interactive
        // panel there so that screen's pill can expand. Compared by frame (not
        // object identity) so a reconfigured NSScreen never causes churn. Single
        // display: the hovered screen IS the notch screen, so this is a no-op.
        let hovered = NSScreen.screens.first { Self.triggerZone(on: $0).contains(mouse) }
        if let hovered, hovered.frame != notchScreen().frame {
            onWantScreen?(hovered)
        }
        let screen = hovered ?? notchScreen()

        // A held mouse button over the notch means a drag (dragging a file in),
        // not a hover. Opening the normal status card in that moment is the
        // "usual notch flashes for a split second" bug. Suppress hover while a
        // button is down; the drop panel is driven by the drop flags instead.
        let dragging = NSEvent.pressedMouseButtons != 0

        // Once the button is released the drag is over. SwiftUI's DropDelegate
        // does not always deliver dropExited (a fast release, a drop just off the
        // target), which left the panel stuck green. The cursor's button state is
        // the authority: no button down means no live drag, so clear the flags.
        if !dragging {
            if state.isDropTarget { state.isDropTarget = false }
            if state.isDropHot { state.isDropHot = false }
        }

        let inside: Bool
        if dragging || Date() < state.suppressHoverUntil {
            inside = false
        } else if state.isHovering {
            inside = keepRegion(for: state).contains(mouse)
        } else {
            inside = Self.triggerZone(on: screen).contains(mouse)
        }
        state.setHovering(inside)
        updatePetCursor(state: state, mouse: mouse, screen: screen)
    }

    /// Tell the pet roughly where the cursor is so it can look at it. Only
    /// meaningful within a hand's reach of the notch — further out and the pet
    /// should just face front rather than staring off-screen.
    private func updatePetCursor(state: AppState, mouse: NSPoint, screen: NSScreen) {
        guard state.petEnabled, state.petActivity != .tucked else {
            if state.petCursorX != 0 { state.petCursorX = 0 }
            if state.petPetting { state.petPetting = false }
            return
        }
        let s = screen.frame
        let centerX = screen.notchCenterX
        let reach: CGFloat = 220
        let dx = mouse.x - centerX
        let nearVertically = mouse.y > s.maxY - 140
        let near = nearVertically && abs(dx) < reach
        let value = near ? Double(dx) : 0
        if abs(state.petCursorX - value) > 0.5 { state.petCursorX = value }
        // Petting freezes the pet's timeline, so a stuck `petPetting` pins it
        // out of the notch forever. SwiftUI's hover-ended doesn't always fire
        // (a menu or another window can take the mouse mid-hover), so the
        // cursor's actual position is the authority: nowhere near it, not
        // petting it.
        if !near, state.petPetting { state.petPetting = false }
    }

    /// The "stay-expanded" region. Derived from the TARGET size for the
    /// current mode — NOT the window frame (which is now a big fixed panel,
    /// so frame-based would never collapse). Centred on the physical notch,
    /// generously padded so small cursor drift never collapses the card.
    private func keepRegion(for state: AppState) -> NSRect {
        let screen = notchScreen()
        let s = screen.frame
        let target = NotchView.size(for: state.mode, hovering: true, on: screen, state: state)
        let centerX = screen.notchCenterX
        let width = max(target.width + 140, 460)
        let height = max(target.height + 90, 160)
        let top = s.maxY
        return NSRect(x: centerX - width / 2, y: top - height, width: width, height: height)
    }
}
