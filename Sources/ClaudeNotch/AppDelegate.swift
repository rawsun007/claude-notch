import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    var notch: NotchWindowController!
    var menu: MenuBarController!
    var server: EventServer!
    var mouse: MouseTracker!
    var keys: KeyboardMonitor!
    let onboarding = OnboardingWindowController()
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent App Nap. Without this, when ANOTHER app is active macOS
        // throttles our background process and the notch's SwiftUI spring
        // animation gets skipped — the card pops in instantly. Holding a
        // user-initiated activity keeps us animating at full rate always.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "Notch overlay animations"
        )

        onboarding.appState = state

        notch = NotchWindowController(state: state)
        notch.show()

        menu = MenuBarController(state: state, onboarding: onboarding)

        mouse = MouseTracker(state: state, window: notch.window)
        mouse.start()

        keys = KeyboardMonitor(state: state)
        keys.start()

        server = EventServer(port: 53127, state: state)
        do {
            try server.start()
        } catch {
            NSLog("ClaudeNotch: failed to start event server: \(error)")
        }

        if OnboardingWindowController.shouldAutoShow {
            // Defer slightly so the menu bar icon appears first — feels less
            // abrupt than the window jumping up at the exact same moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.onboarding.show()
            }
        }

        // ⌥⌘N anywhere → focus the notch into compose mode.
        GlobalHotkey.shared.onFire = { [weak self] in
            self?.state.summonCompose()
            self?.notch.window.makeKey()
        }
        GlobalHotkey.shared.registerDefault()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
