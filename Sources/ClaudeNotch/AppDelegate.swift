import AppKit
import Carbon.HIToolbox

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
    let settings = SettingsWindowController()
    let settingsHotkey = GlobalHotkey()
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Leave a local crash report behind on an uncaught exception or fatal
        // signal, so a bug report has something to attach. Installed first so it
        // is in place before anything else can fault.
        CrashReporter.install()

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
        settings.appState = state
        settings.onOpenSetup = { [weak self] in self?.onboarding.show() }

        notch = NotchWindowController(state: state)
        notch.show()

        menu = MenuBarController(state: state, onboarding: onboarding, settings: settings)

        mouse = MouseTracker(state: state, window: notch.window)
        // Let the notch follow the cursor onto another display so its pill can
        // hover-expand there without waiting for the drift timer.
        mouse.onWantScreen = { [weak notch] screen in notch?.migrate(to: screen) }
        mouse.start()

        keys = KeyboardMonitor(state: state)
        keys.start()

        // Mirror blocking permission cards to native notifications (actionable
        // from the lock screen / another Space; auto-respects Focus).
        notifications.state = state
        state.permissionMirror = notifications
        notifications.start()
        // Fire the daily spend digest notification (if enabled) shortly after
        // launch so the notification bridge has time to get authorized.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.state.fireDigestIfNeeded()
            self?.state.fireWeeklyDigestIfNeeded()
        }

        // Which plan this Mac is signed into, and how close its limits are. Read
        // from Claude Code's own cache on a slow timer: no hook reports it, and
        // it changes when Claude Code talks to the API rather than when a session
        // does anything.
        state.ensurePlanTimer()

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
        if HookInstaller.isInstalled && (!HookInstaller.statusLineWired || !HookInstaller.hooksCurrent) {
            DispatchQueue.global(qos: .utility).async {
                try? HookInstaller.install()
            }
        }

        // Claude Code executes the scripts in ~/.claudenotch/bin on every hook,
        // so whatever is in that directory runs as you dozens of times an hour.
        // The directory is 0700, which stops another account writing into it,
        // but nothing noticed if something already had. Compare the installed
        // copies against the ones in the bundle and say so when they differ.
        //
        // Drift detection, not authentication: an attacker who can write there
        // can rewrite the app too. What it catches is the realistic case, an
        // edit nobody remembers making or a half-finished update.
        if HookInstaller.isInstalled {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let drifted = HookInstaller.driftedScripts()
                guard !drifted.isEmpty else { return }
                DispatchQueue.main.async { self?.reportDriftedHooks(drifted) }
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

        // ⌥⌘, anywhere → open settings (leaves the normal ⌘, alone).
        settingsHotkey.onFire = { [weak self] in self?.settings.show() }
        settingsHotkey.register(keyCode: UInt32(kVK_ANSI_Comma),
                                modifiers: UInt32(cmdKey | optionKey))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - claudenotch:// URLs

    /// Handle `claudenotch://` links. See URLScheme.swift for the grammar and
    /// for why a project arrives as a name rather than as a path.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let action = NotchURL.parse(url) else {
                NSLog("ClaudeNotch: ignoring unrecognised URL \(url.scheme ?? "?")://…")
                continue
            }
            run(action)
        }
    }

    /// Also the AppleScript entry point (see AppleScriptSupport.swift), hence
    /// not private.
    func run(_ action: NotchURLAction) {
        switch action {
        case .open:
            // Same effect as putting the cursor on the notch, so a link can
            // reveal the card without the user reaching for the trackpad.
            state.setHovering(true)
            notch.window.makeKey()
        case .settings:
            settings.show()
        case .history:
            state.openHistory()
        case .standup:
            menu.copyStandup()
        case .compose(let project):
            state.beginCompose(project: project)
            notch.window.makeKey()
        case .resume(let project):
            resumeForScripting(project: project)
        }
    }

    // MARK: - Scripting

    /// Resume the newest session, or the newest one in a named project.
    ///
    /// The name is matched against the sessions Claude Code has already written
    /// to disk; nothing is launched from the URL or the script itself, so a
    /// caller can only reopen a directory the user has genuinely worked in.
    ///
    /// The scan reads hundreds of transcripts, so it runs off the main thread
    /// and reports back through `found`. AppleScript suspends its command
    /// around that rather than freezing the notch while it waits.
    func resumeForScripting(project: String?, found: (@Sendable @MainActor (Bool) -> Void)? = nil) {
        let includeCodex = HookInstaller.isCodexInstalled
        Task.detached(priority: .userInitiated) {
            let session: ResumableSession?
            if let project {
                session = SessionResumer.allAgentSessionsByProject(includeCodex: includeCodex)
                    .first { $0.project == project }?
                    .sessions.first
            } else {
                session = SessionResumer.mostRecent(includeCodex: includeCodex)
            }
            await MainActor.run {
                if let session {
                    TerminalAutomator.resume(model: session.model, sessionId: session.id, in: session.cwd)
                }
                found?(session != nil)
            }
        }
    }

    func composeForScripting(project: String?) {
        run(.compose(project: project))
    }

    /// Build today's standup, copy it, and hand the text back so a script can
    /// post it somewhere instead of going through the clipboard.
    func standupForScripting(done: @escaping @Sendable @MainActor (String) -> Void) {
        let records = state.sessionHistory
        let dirs = state.recentProjects
        Task.detached(priority: .userInitiated) {
            let text = AppState.standupText(records: records, extraDirs: dirs, days: 1)
            await MainActor.run {
                NSPasteboard.copyString(text)
                done(text)
            }
        }
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

        // Conventional first submenu (the app menu). Carries the standard
        // Settings… ⌘, so the shortcut opens the settings window whenever a
        // ClaudeNotch window is focused or the app is active (an accessory app
        // can't claim ⌘, globally, but this covers every in-app case).
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsMI = appMenu.addItem(withTitle: "Settings…",
                                         action: #selector(openSettingsFromMenu),
                                         keyEquivalent: ",")
        settingsMI.target = self
        appItem.submenu = appMenu
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

        // Window menu so ⌘W closes and ⌘M minimizes the focused window (the
        // settings and onboarding windows had no way to close from the keyboard).
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettingsFromMenu() {
        settings.show()
    }

    /// Say that an installed hook script no longer matches the shipped one, and
    /// offer to put the shipped copy back.
    ///
    /// A card rather than a silent repair: overwriting a file somebody may have
    /// edited on purpose, without telling them, is its own kind of rude, and if
    /// the edit was NOT on purpose then it is the thing they most need to know
    /// about. Either way it is their call.
    @MainActor
    private func reportDriftedHooks(_ names: [String]) {
        let list = names.joined(separator: ", ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = names.count == 1
            ? "A hook script has changed"
            : "\(names.count) hook scripts have changed"
        alert.informativeText = """
        \(list) in ~/.claudenotch/bin no longer matches the copy this version \
        of ClaudeNotch ships. Claude Code runs these on every hook, so they run \
        as you.

        If you edited them yourself, keep them. If you did not, replacing them \
        puts the shipped copies back.
        """
        alert.addButton(withTitle: "Keep Mine")
        alert.addButton(withTitle: "Replace")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? HookInstaller.repairScripts()
        }
    }
}
