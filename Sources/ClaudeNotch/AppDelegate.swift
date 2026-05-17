import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    var notch: NotchWindowController!
    var menu: MenuBarController!
    var server: EventServer!
    var mouse: MouseTracker!
    var keys: KeyboardMonitor!

    func applicationDidFinishLaunching(_ notification: Notification) {
        notch = NotchWindowController(state: state)
        notch.show()

        menu = MenuBarController(state: state)

        mouse = MouseTracker(state: state)
        mouse.start()

        keys = KeyboardMonitor(state: state)
        keys.start()

        server = EventServer(port: 53127, state: state)
        do {
            try server.start()
        } catch {
            NSLog("ClaudeNotch: failed to start event server: \(error)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
