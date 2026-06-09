import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    var notch: NotchWindowController!
    var menu: MenuBarController!
    var server: EventServer!
    var mouse: MouseTracker!
    var keys: KeyboardMonitor!
    let notifications = NotificationBridge()
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

        installEditMenu()

        onboarding.appState = state

        notch = NotchWindowController(state: state)
        notch.show()

        menu = MenuBarController(state: state, onboarding: onboarding)

        mouse = MouseTracker(state: state, window: notch.window)
        mouse.start()

        keys = KeyboardMonitor(state: state)
        keys.start()

        // Mirror blocking permission cards to native notifications (actionable
        // from the lock screen / another Space; auto-respects Focus).
        notifications.state = state
        state.permissionMirror = notifications
        notifications.start()

        server = EventServer(port: 53127, state: state)
        do {
            try server.start()
        } catch {
            NSLog("ClaudeNotch: failed to start event server: \(error)")
        }

        // Auto-migrate already-installed users to the statusLine forwarder (the
        // source of authoritative context-% and real 5h/weekly plan-limit usage)
        // without making them re-run Setup. install() is idempotent, backs up
        // settings.json, and chains any existing statusLine.
        if HookInstaller.isInstalled && !HookInstaller.statusLineWired {
            DispatchQueue.global(qos: .utility).async {
                try? HookInstaller.install()
            }
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

    /// Install a minimal main menu with a standard Edit menu. Without it, this
    /// accessory (LSUIElement) app has no menu at all, so ⌘X / ⌘C / ⌘V / ⌘A are
    /// never dispatched to the focused field: typing worked, but pasting into
    /// the "type your own answer" field, the compose box, and the search field
    /// did nothing because the key equivalents had no menu item to map them to
    /// the cut:/copy:/paste:/selectAll: responder actions. The menu bar stays
    /// hidden for an accessory app; only the key equivalents matter here.
    private func installEditMenu() {
        let mainMenu = NSMenu()

        // Conventional first submenu (the app menu). Left empty — we only need
        // its presence so the Edit menu sits where AppKit expects it.
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        mainMenu.addItem(editItem)

        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }
}
