import AppKit
import ServiceManagement
import Combine
import IOKit.hid

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    let item: NSStatusItem
    let state: AppState

    private var allowlistItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!
    private var inputMonitoringItem: NSMenuItem!
    private var recentProjectsItem: NSMenuItem!
    private var recentProjectsMenu: NSMenu!
    private var statusItem: NSMenuItem!
    private var persistentNotchItem: NSMenuItem!
    private var autoApproveItem: NSMenuItem!
    private var autoApproveMenu: NSMenu!
    private var snoozeItem: NSMenuItem!
    private var snoozeMenu: NSMenu!
    private var soundItem: NSMenuItem!
    private var soundMenu: NSMenu!
    // Keep-open row views for the Sound submenu — clicking these does not
    // dismiss the menu, so the user can preview multiple sounds.
    private var soundRowViews: [String: KeepOpenRowView] = [:]
    private var muteRowView: KeepOpenRowView?
    private var perToolRowView: KeepOpenRowView?
    private var updateItem: NSMenuItem!
    private var checkUpdateItem: NSMenuItem!
    private var insightsMenu: NSMenu!
    private var insightsItem: NSMenuItem!
    private var claudeUsageMenu: NSMenu!
    private var claudeUsageItem: NSMenuItem!
    private var cachedClaudeUsage: ClaudeUsageReader.Usage?
    private var claudeUsageComputing = false
    private var cancellables = Set<AnyCancellable>()
    private var permissionsTimer: Timer?
    private var isMenuOpen = false

    private let onboarding: OnboardingWindowController

    init(state: AppState, onboarding: OnboardingWindowController) {
        self.state = state
        self.onboarding = onboarding
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            button.image = MenuBarController.statusIcon()
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        let buildStamp = MenuBarController.buildTimestamp()
        let header = NSMenuItem(title: "ClaudeNotch  ·  build \(buildStamp)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        statusItem = NSMenuItem(title: "No Active Session", action: #selector(clearSession), keyEquivalent: "")
        statusItem.target = self
        menu.addItem(statusItem)

        // Hidden until the update checker finds a newer release.
        updateItem = NSMenuItem(title: "Update available", action: #selector(openUpdate), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)

        menu.addItem(.separator())

        // Start Claude in a folder
        let startHere = NSMenuItem(title: "Start Claude in Folder…", action: #selector(startClaudePicker), keyEquivalent: "o")
        startHere.target = self
        menu.addItem(startHere)

        // Recent projects submenu (populated dynamically)
        recentProjectsMenu = NSMenu()
        recentProjectsItem = NSMenuItem(title: "Recent Projects", action: nil, keyEquivalent: "")
        recentProjectsItem.submenu = recentProjectsMenu
        menu.addItem(recentProjectsItem)

        // Send message to current Claude session
        let sendMsg = NSMenuItem(title: "Send Message to Claude…", action: #selector(sendMessagePrompt), keyEquivalent: "m")
        sendMsg.target = self
        menu.addItem(sendMsg)

        menu.addItem(.separator())

        // Demos — grouped into a single submenu instead of cluttering the
        // top level.
        let demosMenu = NSMenu()
        func addDemo(_ title: String, _ sel: Selector, _ key: String) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            mi.target = self
            demosMenu.addItem(mi)
        }
        addDemo("Tool Permission",      #selector(triggerDemoPermission), "p")
        addDemo("Destructive Command",  #selector(triggerDemoDangerous),  "d")
        addDemo("Edit with Diff Preview", #selector(triggerDemoDiff),     "e")
        addDemo("Auto-Approve (Live Activity)", #selector(triggerDemoAutoApprove), "")
        addDemo("Notification",         #selector(triggerDemoNotification), "n")
        addDemo("Task Complete",        #selector(triggerDemoCompleted),  "c")
        addDemo("Thinking Pulse",       #selector(triggerDemoThinking),   "t")
        let demosItem = NSMenuItem(title: "Demos", action: nil, keyEquivalent: "")
        demosItem.submenu = demosMenu
        menu.addItem(demosItem)

        // Insights — local usage stats (rebuilt each time the menu opens).
        insightsMenu = NSMenu()
        insightsItem = NSMenuItem(title: "Insights", action: nil, keyEquivalent: "")
        insightsItem.submenu = insightsMenu
        menu.addItem(insightsItem)

        // Claude Usage — token usage + estimated cost from Claude Code's own
        // transcripts. Rebuilt on open; the parse runs off the main thread.
        claudeUsageMenu = NSMenu()
        claudeUsageItem = NSMenuItem(title: "Claude Usage", action: nil, keyEquivalent: "")
        claudeUsageItem.submenu = claudeUsageMenu
        menu.addItem(claudeUsageItem)

        // Permissions & setup — grouped into a submenu.
        let permsMenu = NSMenu()

        accessibilityItem = NSMenuItem(title: "Accessibility: Checking…", action: #selector(promptAccessibility), keyEquivalent: "")
        accessibilityItem.target = self
        permsMenu.addItem(accessibilityItem)

        inputMonitoringItem = NSMenuItem(title: "Input Monitoring: Checking…", action: #selector(promptInputMonitoring), keyEquivalent: "")
        inputMonitoringItem.target = self
        permsMenu.addItem(inputMonitoringItem)

        permsMenu.addItem(.separator())

        allowlistItem = NSMenuItem(title: "Always-Allow Rules: —", action: #selector(clearAllowlist), keyEquivalent: "")
        allowlistItem.target = self
        permsMenu.addItem(allowlistItem)

        let permsItem = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        permsItem.submenu = permsMenu
        menu.addItem(permsItem)

        menu.addItem(.separator())

        persistentNotchItem = NSMenuItem(title: "Persistent Notch Display", action: #selector(togglePersistentNotchDisplay), keyEquivalent: "")
        persistentNotchItem.target = self
        menu.addItem(persistentNotchItem)

        // Auto-Approve submenu: permanent toggle + timed windows.
        autoApproveMenu = NSMenu()
        autoApproveItem = NSMenuItem(title: "Auto-Approve", action: nil, keyEquivalent: "")
        autoApproveItem.submenu = autoApproveMenu
        menu.addItem(autoApproveItem)

        // Snooze submenu: pause non-blocking cards for a window.
        snoozeMenu = NSMenu()
        snoozeItem = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: "")
        snoozeItem.submenu = snoozeMenu
        menu.addItem(snoozeItem)

        // Sound submenu: mute + per-tool toggle + alert sound picker, all as
        // keep-open rows so you can audition multiple sounds in one go.
        soundMenu = NSMenu()
        soundItem = NSMenuItem(title: "Sound", action: nil, keyEquivalent: "")
        soundItem.submenu = soundMenu
        menu.addItem(soundItem)

        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        let setupItem = NSMenuItem(title: "Setup…", action: #selector(showOnboarding), keyEquivalent: ",")
        setupItem.target = self
        menu.addItem(setupItem)

        checkUpdateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesNow), keyEquivalent: "")
        checkUpdateItem.target = self
        menu.addItem(checkUpdateItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit ClaudeNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self
        item.menu = menu

        state.$allowRules
            .receive(on: RunLoop.main)
            .sink { [weak self] set in self?.refreshAllowlist(set) }
            .store(in: &cancellables)

        state.$recentProjects
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshRecentProjects() }
            .store(in: &cancellables)

        Publishers.CombineLatest3(state.$currentProject, state.$lastActivity, state.$lastUserPrompt)
            .throttle(for: .milliseconds(400), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _, _, _ in self?.refreshStatusLine() }
            .store(in: &cancellables)

        refreshLoginItem()
        refreshPermissions()
        refreshRecentProjects()
        refreshStatusLine()
        refreshPrefs()
        refreshInsights()
        refreshClaudeUsage()

        // Slower poll (12s) so background ticks don't compete with menu redraw
        // — we also explicitly refresh just-in-time when the menu opens.
        permissionsTimer = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isMenuOpen else { return }
                self.refreshPermissions()
            }
        }

        // Update checker: surfaces "Update available" in the menu when a newer
        // release is published. Callbacks fire on the main thread.
        UpdateChecker.shared.onUpdateAvailable = { [weak self] version, userInitiated in
            self?.handleUpdateAvailable(version, userInitiated: userInitiated)
        }
        UpdateChecker.shared.onUpToDate = { [weak self] in
            self?.presentUpToDate()
        }
        UpdateChecker.shared.onCheckFailed = { [weak self] in
            self?.presentCheckFailed()
        }
        UpdateChecker.shared.start()
    }

    // NSMenuDelegate — pause background refreshes while the user is in the menu
    // and refresh once on open so the state is fresh without churn.
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isMenuOpen = true
            self.refreshPermissions()
            self.refreshStatusLine()
            self.refreshRecentProjects()
            self.refreshPrefs()
            self.refreshInsights()
            self.refreshClaudeUsage()
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        Task { @MainActor [weak self] in self?.isMenuOpen = false }
    }

    private func refreshPermissions() {
        // Accessibility (for keystroke injection into terminal)
        if TerminalAutomator.isAccessibilityTrusted {
            accessibilityItem.state = .on
            accessibilityItem.title = "Accessibility: Granted"
            accessibilityItem.isEnabled = false
        } else {
            accessibilityItem.state = .off
            accessibilityItem.title = "Grant Accessibility…"
            accessibilityItem.isEnabled = true
        }

        // Input Monitoring (for Enter/Esc shortcuts in notch)
        let im = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if im == kIOHIDAccessTypeGranted {
            inputMonitoringItem.state = .on
            inputMonitoringItem.title = "Input Monitoring: Granted"
            inputMonitoringItem.isEnabled = false
        } else {
            inputMonitoringItem.state = .off
            inputMonitoringItem.title = "Grant Input Monitoring…"
            inputMonitoringItem.isEnabled = true
        }
    }

    @objc private func promptAccessibility() {
        TerminalAutomator.requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshPermissions()
    }

    @objc private func promptInputMonitoring() {
        // Triggers the macOS request dialog the first time.
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        refreshPermissions()
    }

    private func refreshAllowlist(_ rules: Set<AllowRule>) {
        if rules.isEmpty {
            allowlistItem.title = "Always-Allow Rules: —"
            allowlistItem.isEnabled = false
        } else {
            let labels = rules.map(\.displayLabel).sorted()
            let preview = labels.prefix(3).joined(separator: ", ")
            let more = labels.count > 3 ? " +\(labels.count - 3) more" : ""
            allowlistItem.title = "Always-Allow: \(preview)\(more)  —  Click to Clear All"
            allowlistItem.isEnabled = true
        }
    }

    private func refreshLoginItem() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            loginItem.state = (status == .enabled) ? .on : .off
            loginItem.isEnabled = (Bundle.main.bundlePath.hasSuffix(".app"))
            if !loginItem.isEnabled {
                loginItem.title = "Launch at Login (install to /Applications first)"
            } else if status == .requiresApproval {
                loginItem.title = "Launch at Login — Approve in System Settings…"
            } else {
                loginItem.title = "Launch at Login"
            }
        } else {
            loginItem.isEnabled = false
        }
    }

    @objc private func triggerDemoPermission() {
        let cmd = "npm install"
        let req = PermissionRequest(
            kind: .toolUse,
            title: "Run shell command",
            detail: cmd,
            toolName: "Bash",
            source: "Demo",
            cwd: NSHomeDirectory(),
            dangerReasons: [],
            resolver: { decision, _ in
                NSLog("Demo permission resolved: \(decision.rawValue)")
            }
        )
        state.enqueuePermission(req, bypassRules: true)
    }

    /// Destructive command demo — exercises the red banner + hold-to-allow
    /// flow without waiting for Claude Code to actually issue an rm -rf.
    @objc private func triggerDemoDangerous() {
        let cmd = "rm -rf /tmp/cache && sudo chmod -R 777 /Library/LaunchAgents"
        let toolInput: [String: Any] = ["command": cmd]
        let reasons = ToolPreviewParser.dangerReasons(for: "Bash", input: toolInput)
        let req = PermissionRequest(
            kind: .toolUse,
            title: "Run shell command",
            detail: cmd,
            toolName: "Bash",
            source: "Demo",
            cwd: NSHomeDirectory(),
            dangerReasons: reasons,
            resolver: { decision, _ in
                NSLog("Demo dangerous resolved: \(decision.rawValue)")
            }
        )
        state.enqueuePermission(req, bypassRules: true)
    }

    /// Edit demo — exercises the diff-preview block (red old / green new).
    @objc private func triggerDemoDiff() {
        let oldText = "let x = 42\nprint(\"hello\")\nreturn x"
        let newText = "let x = 100\nprint(\"hello, world\")\nreturn x * 2"
        let toolInput: [String: Any] = [
            "file_path": "/Users/example/main.swift",
            "old_string": oldText,
            "new_string": newText
        ]
        let preview = ToolPreviewParser.preview(for: "Edit", input: toolInput)
        let req = PermissionRequest(
            kind: .toolUse,
            title: "Edit file",
            detail: "/Users/example/main.swift",
            toolName: "Edit",
            source: "Demo",
            cwd: "/Users/example",
            preview: preview,
            resolver: { decision, _ in
                NSLog("Demo diff resolved: \(decision.rawValue)")
            }
        )
        state.enqueuePermission(req, bypassRules: true)
    }

    /// Auto-approve demo — shows the button-less "live activity" card exactly
    /// as it appears when Auto-Approve silently allows an edit.
    @objc private func triggerDemoAutoApprove() {
        let oldText = "timeout = 30"
        let newText = "timeout = 60"
        let toolInput: [String: Any] = [
            "file_path": "/Users/example/config.swift",
            "old_string": oldText,
            "new_string": newText
        ]
        let preview = ToolPreviewParser.preview(for: "Edit", input: toolInput)
        let req = PermissionRequest(
            kind: .toolUse,
            title: "Edit file",
            detail: "/Users/example/config.swift",
            toolName: "Edit",
            source: "Demo",
            cwd: "/Users/example",
            preview: preview,
            resolver: { _, _ in }
        )
        state.demoAutoApprove(req)
    }

    @objc private func triggerDemoNotification() {
        state.enqueuePermission(.init(
            kind: .notification,
            title: "Claude is waiting for your input",
            detail: "Open IDE to continue",
            toolName: "Notification",
            source: "Demo",
            cwd: "",
            resolver: { _, _ in }
        ), bypassRules: true)
    }

    @objc private func triggerDemoCompleted() {
        state.enqueueCompleted(.init(
            title: "Done — 14 files changed, tests green",
            detail: "Refactored auth middleware and re-ran the suite.",
            source: "Demo",
            cwd: NSHomeDirectory()
        ))
    }

    @objc private func triggerDemoThinking() {
        state.pingThinking(label: "Editing AuthMiddleware.swift")
    }

    @objc private func clearAllowlist() {
        state.clearAllowlist()
    }

    private func refreshStatusLine() {
        let project = state.currentProject
        let activity = state.lastActivity
        if project.isEmpty {
            statusItem.title = "No active session"
            statusItem.isEnabled = false
        } else if activity.isEmpty {
            statusItem.title = "\(project)  —  click to clear"
            statusItem.isEnabled = true
        } else {
            statusItem.title = "\(project) — \(activity)  (click to clear)"
            statusItem.isEnabled = true
        }
    }

    @objc private func clearSession() {
        state.clearSession()
    }

    private func refreshRecentProjects() {
        recentProjectsMenu.removeAllItems()
        if state.recentProjects.isEmpty {
            let empty = NSMenuItem(title: "(no projects yet — start Claude in any folder)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentProjectsMenu.addItem(empty)
            return
        }
        for cwd in state.recentProjects {
            let basename = (cwd as NSString).lastPathComponent
            let item = NSMenuItem(title: "↻  \(basename)  —  \(cwd)", action: #selector(launchRecentProject(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = cwd
            item.toolTip = cwd
            recentProjectsMenu.addItem(item)
        }
    }

    @objc private func startClaudePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Start Claude here"
        panel.message = "Pick a folder. Terminal.app will open with `cd <folder> && claude`."
        if panel.runModal() == .OK, let url = panel.url {
            TerminalAutomator.startClaude(in: url.path)
        }
    }

    @objc private func launchRecentProject(_ sender: NSMenuItem) {
        guard let cwd = sender.representedObject as? String else { return }
        TerminalAutomator.startClaude(in: cwd)
    }

    @objc private func sendMessagePrompt() {
        // Open the compose card in the notch itself — feels native and
        // doesn't rely on NSAlert (which is unreliable for accessory apps).
        state.beginCompose()
    }

    /// Modification time of the running binary — gives us a "build XYZ" stamp
    /// so we can see at a glance whether the user is on the latest build.
    private static func buildTimestamp() -> String {
        let path = Bundle.main.executablePath ?? ""
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let date = attrs[.modificationDate] as? Date {
            let df = DateFormatter()
            df.dateFormat = "MMM d HH:mm"
            return df.string(from: date)
        }
        return "?"
    }

    @objc private func showOnboarding() {
        onboarding.show()
    }

    // MARK: - Updates

    private func handleUpdateAvailable(_ version: String, userInitiated: Bool) {
        updateItem.title = "↑ Update available: v\(version) — Download"
        updateItem.isHidden = false
        checkUpdateItem.title = "Check for Updates…"
        checkUpdateItem.isEnabled = true
        guard userInitiated else { return }
        // Bring the alert to the front — accessory apps need to activate first
        // or the alert ends up behind everything.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText = "ClaudeNotch v\(version) is available. You're on v\(UpdateChecker.shared.currentVersion)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            openUpdate()
        }
    }

    @objc private func openUpdate() {
        if let url = URL(string: UpdateChecker.shared.releasesPage) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkForUpdatesNow() {
        checkUpdateItem.title = "Checking for Updates…"
        checkUpdateItem.isEnabled = false
        UpdateChecker.shared.check(userInitiated: true)
        // Safety net: if no callback fires in 10s (network hang), re-enable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.checkUpdateItem.title = "Check for Updates…"
            self?.checkUpdateItem.isEnabled = true
        }
    }

    private func presentUpToDate() {
        checkUpdateItem.title = "Check for Updates…"
        checkUpdateItem.isEnabled = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "ClaudeNotch v\(UpdateChecker.shared.currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentCheckFailed() {
        checkUpdateItem.title = "Check for Updates…"
        checkUpdateItem.isEnabled = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = "Something went wrong reaching GitHub. Check your internet connection and try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Auto-Approve / Snooze / Sound actions

    @objc private func toggleAutoApprove() {
        state.setAutoApprove(!state.autoApprove)
        refreshPrefs()
    }

    @objc private func autoApproveForAction(_ sender: NSMenuItem) {
        state.enableAutoApprove(forMinutes: sender.tag)
        refreshPrefs()
    }

    @objc private func turnOffAutoApprove() {
        state.setAutoApprove(false)
        refreshPrefs()
    }

    @objc private func snoozeForAction(_ sender: NSMenuItem) {
        state.snooze(forMinutes: sender.tag)
        refreshPrefs()
    }

    @objc private func cancelSnoozeAction() {
        state.cancelSnooze()
        refreshPrefs()
    }

    @objc private func togglePersistentNotchDisplay() {
        state.setPersistentNotchDisplay(!state.persistentNotchDisplay)
        refreshPrefs()
    }

    @objc private func dismissDigest() {
        state.markDigestShown()
        refreshInsights()
    }

    // MARK: - Refresh

    private func refreshPrefs() {
        persistentNotchItem.state = state.persistentNotchDisplay ? .on : .off
        refreshAutoApproveMenu()
        refreshSnoozeMenu()
        refreshSoundMenu()
    }

    private func refreshAutoApproveMenu() {
        autoApproveMenu.removeAllItems()

        if state.autoApprove {
            if let until = state.autoApproveUntil {
                let remaining = max(0, Int(ceil(until.timeIntervalSinceNow / 60)))
                autoApproveItem.title = "Auto-Approve: On (\(remaining)m left)"
            } else {
                autoApproveItem.title = "Auto-Approve: On"
            }
        } else {
            autoApproveItem.title = "Auto-Approve"
        }

        let toggle = NSMenuItem(title: "Auto-Approve All", action: #selector(toggleAutoApprove), keyEquivalent: "")
        toggle.target = self
        toggle.state = (state.autoApprove && state.autoApproveUntil == nil) ? .on : .off
        autoApproveMenu.addItem(toggle)
        autoApproveMenu.addItem(.separator())

        for minutes in [5, 15, 30, 60] {
            let label = minutes < 60 ? "For \(minutes) minutes" : "For 1 hour"
            let mi = NSMenuItem(title: label, action: #selector(autoApproveForAction(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = minutes
            autoApproveMenu.addItem(mi)
        }

        if state.autoApprove {
            autoApproveMenu.addItem(.separator())
            let cancel = NSMenuItem(title: "Turn off", action: #selector(turnOffAutoApprove), keyEquivalent: "")
            cancel.target = self
            autoApproveMenu.addItem(cancel)
        }
    }

    private func refreshSnoozeMenu() {
        snoozeMenu.removeAllItems()

        if let until = state.snoozedUntil, until > Date() {
            let remaining = max(0, Int(ceil(until.timeIntervalSinceNow / 60)))
            snoozeItem.title = "Snooze: \(remaining)m left"
        } else {
            snoozeItem.title = "Snooze"
        }

        let header = NSMenuItem(title: "Suppress non-blocking cards for…", action: nil, keyEquivalent: "")
        header.isEnabled = false
        snoozeMenu.addItem(header)

        for minutes in [15, 30, 60, 120] {
            let label: String
            if minutes < 60 { label = "\(minutes) minutes" }
            else if minutes == 60 { label = "1 hour" }
            else { label = "\(minutes/60) hours" }
            let mi = NSMenuItem(title: label, action: #selector(snoozeForAction(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = minutes
            snoozeMenu.addItem(mi)
        }

        if state.isSnoozed {
            snoozeMenu.addItem(.separator())
            let cancel = NSMenuItem(title: "Cancel snooze", action: #selector(cancelSnoozeAction), keyEquivalent: "")
            cancel.target = self
            snoozeMenu.addItem(cancel)
        }
    }

    private func refreshSoundMenu() {
        soundMenu.removeAllItems()
        soundRowViews.removeAll()

        // Mute toggle — keep-open so the user can toggle and then immediately
        // pick / preview sounds without re-opening the menu.
        let mute = KeepOpenRowView(
            title: state.soundMuted ? "Sounds Muted" : "Mute Sounds",
            checked: state.soundMuted
        )
        mute.handler = { [weak self] in
            guard let self else { return }
            self.state.setSoundMuted(!self.state.soundMuted)
            self.muteRowView?.update(
                title: self.state.soundMuted ? "Sounds Muted" : "Mute Sounds",
                checked: self.state.soundMuted
            )
        }
        let muteHolder = NSMenuItem()
        muteHolder.view = mute
        soundMenu.addItem(muteHolder)
        muteRowView = mute

        // Per-tool toggle — keep-open.
        let perTool = KeepOpenRowView(title: "Per-tool sounds", checked: state.perToolSounds)
        perTool.handler = { [weak self] in
            guard let self else { return }
            self.state.setPerToolSounds(!self.state.perToolSounds)
            self.perToolRowView?.update(title: "Per-tool sounds", checked: self.state.perToolSounds)
        }
        let perToolHolder = NSMenuItem()
        perToolHolder.view = perTool
        soundMenu.addItem(perToolHolder)
        perToolRowView = perTool

        soundMenu.addItem(.separator())
        let header = NSMenuItem(title: "Alert sound (click to preview)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        soundMenu.addItem(header)

        // Sound picker — keep-open per row, plays a preview on click.
        for sound in AppState.availableSounds {
            let row = KeepOpenRowView(title: sound, checked: sound == state.alertSound)
            row.handler = { [weak self] in
                guard let self else { return }
                let previous = self.state.alertSound
                self.state.setAlertSound(sound)
                if !self.state.soundMuted {
                    NSSound(named: NSSound.Name(sound))?.play()
                }
                self.soundRowViews[previous]?.update(title: previous, checked: false)
                self.soundRowViews[sound]?.update(title: sound, checked: true)
            }
            let holder = NSMenuItem()
            holder.view = row
            soundMenu.addItem(holder)
            soundRowViews[sound] = row
        }
    }

    private func refreshInsights() {
        insightsMenu.removeAllItems()
        let s = state.stats

        func row(_ title: String, enabled: Bool = false) {
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.isEnabled = enabled
            insightsMenu.addItem(mi)
        }

        // Daily digest — shown once per day when yesterday had activity.
        if state.shouldShowDigest, let y = state.yesterdayCounts {
            row("🌙  Yesterday: \(y.tools) tools  ·  \(y.allowed) allowed  ·  \(y.denied) denied  ·  \(y.dangerousFlagged) risky")
            let dismiss = NSMenuItem(title: "Dismiss digest", action: #selector(dismissDigest), keyEquivalent: "")
            dismiss.target = self
            insightsMenu.addItem(dismiss)
            insightsMenu.addItem(.separator())
        }

        if let t = state.stats.dailyCounts[AppState.dayKey(Date())] {
            row("Today:  \(t.tools) tools  ·  \(t.allowed) allowed  ·  \(t.denied) denied")
        } else {
            row("Today:  no activity yet")
        }
        row("This session:  \(state.sessionTools) tools · \(state.sessionAllowed) allowed · \(state.sessionDenied) denied")
        insightsMenu.addItem(.separator())
        row("Approved:  \(s.allowed)   (\(s.autoApproved) auto)")
        row("Denied:  \(s.denied)")
        row("Risky commands flagged:  \(s.dangerousFlagged)")
        row("Questions answered:  \(s.questionsAnswered)")

        let top = s.toolCounts.sorted { $0.value > $1.value }.prefix(5)
        if !top.isEmpty {
            insightsMenu.addItem(.separator())
            row("Most-used tools")
            for (tool, n) in top { row("    \(tool):  \(n)") }
        }

        insightsMenu.addItem(.separator())
        row("Active days:  \(state.activeDayCount)    ·    Streak:  \(state.currentStreak)🔥")
        if let first = s.firstUsed {
            let df = DateFormatter()
            df.dateStyle = .medium
            row("Using ClaudeNotch since \(df.string(from: first))")
        }

        insightsMenu.addItem(.separator())
        appendHeatmap()
    }

    /// Render the cached usage immediately, then recompute in the background if
    /// the cache is missing or older than ~30s (parsing transcripts hits disk).
    private func refreshClaudeUsage() {
        renderClaudeUsage()
        let stale = cachedClaudeUsage.map { Date().timeIntervalSince($0.computedAt) > 30 } ?? true
        guard stale, !claudeUsageComputing else { return }
        claudeUsageComputing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let usage = ClaudeUsageReader.compute()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cachedClaudeUsage = usage
                self.claudeUsageComputing = false
                self.renderClaudeUsage()
            }
        }
    }

    private func renderClaudeUsage() {
        claudeUsageMenu.removeAllItems()
        func row(_ title: String) {
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            claudeUsageMenu.addItem(mi)
        }
        func monoRow(_ title: String) {
            let mono = NSFont.userFixedPitchFont(ofSize: NSFont.systemFontSize) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            mi.attributedTitle = NSAttributedString(string: title, attributes: [.font: mono])
            claudeUsageMenu.addItem(mi)
        }
        guard let u = cachedClaudeUsage else {
            row(claudeUsageComputing ? "Computing…" : "No usage data yet")
            return
        }
        guard u.hasData else {
            row("No Claude usage in the last 7 days")
            return
        }
        let tk = ClaudeUsageReader.fmtTokens
        let mn = ClaudeUsageReader.fmtMoney
        if u.today.total > 0 {
            row("Today:  \(tk(u.today.total)) tokens  ·  ~\(mn(u.today.costUSD))")
            if u.todayVsAverage > 0 {
                row(String(format: "    %.1f× your daily average", u.todayVsAverage))
            }
        } else {
            row("Today:  no activity yet")
        }
        row("This week:  \(tk(u.week.total)) tokens  ·  ~\(mn(u.week.costUSD))")

        // 7-day token sparkline.
        let spark = ClaudeUsageReader.sparkline(daily: u.dailyTokens)
        claudeUsageMenu.addItem(.separator())
        row("Tokens — last 7 days")
        monoRow("    " + spark.bars)
        monoRow("    " + spark.labels)

        claudeUsageMenu.addItem(.separator())
        if u.sessionsWeek > 0 {
            row("Sessions (7 days):  \(u.sessionsWeek)  ·  ~\(tk(u.avgTokensPerSession))/session")
        }
        if u.cacheHitRate > 0 {
            row("Cache:  \(Int((u.cacheHitRate * 100).rounded()))% reused  ·  saved ~\(mn(u.cacheSavingsUSD))")
        }
        if !u.topHours.isEmpty {
            row("Busiest:  " + u.topHours.map { ClaudeUsageReader.hourLabel($0) }.joined(separator: "  ·  "))
        }

        let byModel = u.weekByModel.sorted { $0.value.total > $1.value.total }
        if !byModel.isEmpty {
            claudeUsageMenu.addItem(.separator())
            row("By model (7 days)")
            for (model, t) in byModel {
                row("    \(model):  \(tk(t.total))  ·  ~\(mn(t.costUSD))")
            }
        }

        let byProject = u.weekByProject.sorted { $0.value.total > $1.value.total }.prefix(6)
        if !byProject.isEmpty {
            claudeUsageMenu.addItem(.separator())
            row("By project (7 days)")
            for (cwd, t) in byProject {
                row("    \(ClaudeUsageReader.projectName(cwd)):  \(tk(t.total))  ·  ~\(mn(t.costUSD))")
            }
        }

        claudeUsageMenu.addItem(.separator())
        row("Est. cost if billed at public API rates")
    }

    /// Append a 7×7 text heatmap of the last 49 days to the Insights submenu.
    private func appendHeatmap() {
        let symbols = ["·", "▫", "▪", "▣", "■"]
        let mono = NSFont.userFixedPitchFont(ofSize: NSFont.systemFontSize) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)

        let header = NSMenuItem(title: "Activity — last 7 weeks", action: nil, keyEquivalent: "")
        header.isEnabled = false
        insightsMenu.addItem(header)

        let cal = Calendar.current
        var grid: [[Int]] = Array(repeating: Array(repeating: 0, count: 7), count: 7)
        for i in 0..<49 {
            guard let day = cal.date(byAdding: .day, value: -(48 - i), to: Date()) else { continue }
            let n = state.stats.dailyCounts[AppState.dayKey(day)]?.tools ?? 0
            let level: Int
            switch n {
            case 0:      level = 0
            case 1...5:  level = 1
            case 6...15: level = 2
            case 16...30: level = 3
            default:     level = 4
            }
            grid[i / 7][i % 7] = level
        }

        for row in grid {
            let s = "    " + row.map { symbols[$0] }.joined(separator: "  ")
            let mi = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            mi.attributedTitle = NSAttributedString(string: s, attributes: [.font: mono])
            insightsMenu.addItem(mi)
        }

        let legend = "    less  " + symbols.joined(separator: " ") + "  more"
        let leg = NSMenuItem(title: legend, action: nil, keyEquivalent: "")
        leg.isEnabled = false
        leg.attributedTitle = NSAttributedString(string: legend, attributes: [.font: mono])
        insightsMenu.addItem(leg)
    }

    /// Our bundled notch+spark glyph, falling back to an SF Symbol if the
    /// asset is missing (e.g. running the raw binary, not the .app).
    private static func statusIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "menubar", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            return img
        }
        return NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "ClaudeNotch")
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            } else {
                try svc.register()
            }
        } catch {
            NSLog("ClaudeNotch: login item toggle failed — \(error)")
            presentLoginError(error)
        }
        refreshLoginItem()

        // If macOS now needs the user to approve the login item (common for
        // ad-hoc-signed apps), take them straight to the Login Items pane.
        if svc.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func presentLoginError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't change Launch at Login"
        alert.informativeText = "\(error.localizedDescription)\n\nMake sure ClaudeNotch is in /Applications, then try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// A menu-row view that does NOT dismiss the surrounding menu when clicked,
/// so the user can toggle / preview repeatedly in one open session.
///
/// Standard NSMenuItem actions tear down the menu the moment they fire. By
/// using `NSMenuItem.view = KeepOpenRowView`, the click hits this view's
/// `mouseDown` first and we deliberately don't propagate to `super`, so the
/// menu's tracking loop keeps running.
@MainActor
final class KeepOpenRowView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let check = NSImageView()
    var handler: () -> Void = {}
    private var trackingArea: NSTrackingArea?

    init(title: String, checked: Bool, width: CGFloat = 220) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        wantsLayer = true
        layer?.cornerRadius = 4

        label.translatesAutoresizingMaskIntoConstraints = false
        check.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .labelColor
        check.contentTintColor = .labelColor
        addSubview(check)
        addSubview(label)
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 14),
            check.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        update(title: title, checked: checked)
    }

    required init?(coder: NSCoder) { nil }

    func update(title: String, checked: Bool) {
        label.stringValue = title
        check.image = checked ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) : nil
    }

    override func mouseDown(with event: NSEvent) {
        handler()
        // Deliberately not calling super — that's what keeps the menu open.
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedMenuItemColor.cgColor
        label.textColor = .selectedMenuItemTextColor
        check.contentTintColor = .selectedMenuItemTextColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        label.textColor = .labelColor
        check.contentTintColor = .labelColor
    }
}
