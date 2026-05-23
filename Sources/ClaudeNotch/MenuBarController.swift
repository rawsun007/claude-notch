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
    private var autoApproveItem: NSMenuItem!
    private var muteItem: NSMenuItem!
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

        autoApproveItem = NSMenuItem(title: "Auto-Approve All", action: #selector(toggleAutoApprove), keyEquivalent: "")
        autoApproveItem.target = self
        menu.addItem(autoApproveItem)

        muteItem = NSMenuItem(title: "Mute Sounds", action: #selector(toggleMute), keyEquivalent: "")
        muteItem.target = self
        menu.addItem(muteItem)

        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        let setupItem = NSMenuItem(title: "Setup…", action: #selector(showOnboarding), keyEquivalent: ",")
        setupItem.target = self
        menu.addItem(setupItem)

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

        // Slower poll (12s) so background ticks don't compete with menu redraw
        // — we also explicitly refresh just-in-time when the menu opens.
        permissionsTimer = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isMenuOpen else { return }
                self.refreshPermissions()
            }
        }
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
            resolver: { decision in
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
            resolver: { decision in
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
            resolver: { decision in
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
            resolver: { _ in }
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
            resolver: { _ in }
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

    @objc private func toggleAutoApprove() {
        state.setAutoApprove(!state.autoApprove)
        refreshPrefs()
    }

    @objc private func toggleMute() {
        state.setSoundMuted(!state.soundMuted)
        refreshPrefs()
    }

    private func refreshPrefs() {
        autoApproveItem.state = state.autoApprove ? .on : .off
        autoApproveItem.title = state.autoApprove ? "Auto-Approve All: On" : "Auto-Approve All"
        muteItem.state = state.soundMuted ? .on : .off
        muteItem.title = state.soundMuted ? "Sounds Muted" : "Mute Sounds"
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
