import AppKit
import ServiceManagement
import Combine
import IOKit.hid

@MainActor
final class MenuBarController: NSObject {
    let item: NSStatusItem
    let state: AppState

    private var allowlistItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!
    private var inputMonitoringItem: NSMenuItem!
    private var recentProjectsItem: NSMenuItem!
    private var recentProjectsMenu: NSMenu!
    private var statusItem: NSMenuItem!
    private var cancellables = Set<AnyCancellable>()
    private var permissionsTimer: Timer?

    init(state: AppState) {
        self.state = state
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "ClaudeNotch")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        let header = NSMenuItem(title: "ClaudeNotch — listening on :53127", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        statusItem = NSMenuItem(title: "No active session", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(.separator())

        // Start Claude in a folder
        let startHere = NSMenuItem(title: "Start Claude in folder…", action: #selector(startClaudePicker), keyEquivalent: "o")
        startHere.target = self
        menu.addItem(startHere)

        // Recent projects submenu (populated dynamically)
        recentProjectsMenu = NSMenu()
        recentProjectsItem = NSMenuItem(title: "Recent projects", action: nil, keyEquivalent: "")
        recentProjectsItem.submenu = recentProjectsMenu
        menu.addItem(recentProjectsItem)

        // Send message to current Claude session
        let sendMsg = NSMenuItem(title: "Send message to Claude…", action: #selector(sendMessagePrompt), keyEquivalent: "m")
        sendMsg.target = self
        menu.addItem(sendMsg)

        menu.addItem(.separator())

        let demoPerm = NSMenuItem(title: "Demo: tool permission (blocking)", action: #selector(triggerDemoPermission), keyEquivalent: "p")
        demoPerm.target = self
        menu.addItem(demoPerm)

        let demoNotif = NSMenuItem(title: "Demo: notification", action: #selector(triggerDemoNotification), keyEquivalent: "n")
        demoNotif.target = self
        menu.addItem(demoNotif)

        let demoDone = NSMenuItem(title: "Demo: task complete", action: #selector(triggerDemoCompleted), keyEquivalent: "c")
        demoDone.target = self
        menu.addItem(demoDone)

        let demoThink = NSMenuItem(title: "Demo: thinking pulse", action: #selector(triggerDemoThinking), keyEquivalent: "t")
        demoThink.target = self
        menu.addItem(demoThink)

        menu.addItem(.separator())

        allowlistItem = NSMenuItem(title: "Always-allowed (this session): —", action: #selector(clearAllowlist), keyEquivalent: "")
        allowlistItem.target = self
        menu.addItem(allowlistItem)

        accessibilityItem = NSMenuItem(title: "Accessibility: checking…", action: #selector(promptAccessibility), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        inputMonitoringItem = NSMenuItem(title: "Input Monitoring: checking…", action: #selector(promptInputMonitoring), keyEquivalent: "")
        inputMonitoringItem.target = self
        menu.addItem(inputMonitoringItem)

        loginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit ClaudeNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu

        state.$sessionAllowlist
            .receive(on: RunLoop.main)
            .sink { [weak self] set in self?.refreshAllowlist(set) }
            .store(in: &cancellables)

        state.$recentProjects
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshRecentProjects() }
            .store(in: &cancellables)

        Publishers.CombineLatest3(state.$currentProject, state.$lastActivity, state.$lastUserPrompt)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.refreshStatusLine() }
            .store(in: &cancellables)

        refreshLoginItem()
        refreshPermissions()
        refreshRecentProjects()
        refreshStatusLine()

        // macOS doesn't fire notifications when permissions toggle, so we poll.
        permissionsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPermissions() }
        }
    }

    private func refreshPermissions() {
        // Accessibility (for keystroke injection into terminal)
        if TerminalAutomator.isAccessibilityTrusted {
            accessibilityItem.state = .on
            accessibilityItem.title = "Accessibility: granted ✓  (clean question answers)"
            accessibilityItem.isEnabled = false
        } else {
            accessibilityItem.state = .off
            accessibilityItem.title = "Grant Accessibility (clean question answers)"
            accessibilityItem.isEnabled = true
        }

        // Input Monitoring (for Enter/Esc shortcuts in notch)
        let im = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if im == kIOHIDAccessTypeGranted {
            inputMonitoringItem.state = .on
            inputMonitoringItem.title = "Input Monitoring: granted ✓  (Enter / Esc shortcuts)"
            inputMonitoringItem.isEnabled = false
        } else {
            inputMonitoringItem.state = .off
            inputMonitoringItem.title = "Grant Input Monitoring (Enter / Esc shortcuts)"
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

    private func refreshAllowlist(_ set: Set<String>) {
        if set.isEmpty {
            allowlistItem.title = "Always-allowed (this session): —"
            allowlistItem.isEnabled = false
        } else {
            let list = set.sorted().joined(separator: ", ")
            allowlistItem.title = "Always-allowed: \(list)  —  click to clear"
            allowlistItem.isEnabled = true
        }
    }

    private func refreshLoginItem() {
        if #available(macOS 13.0, *) {
            let enabled = SMAppService.mainApp.status == .enabled
            loginItem.state = enabled ? .on : .off
            loginItem.isEnabled = (Bundle.main.bundlePath.hasSuffix(".app"))
            if !loginItem.isEnabled {
                loginItem.title = "Launch at login (build & open .app to enable)"
            } else {
                loginItem.title = "Launch at login"
            }
        } else {
            loginItem.isEnabled = false
        }
    }

    @objc private func triggerDemoPermission() {
        let semaphore = DispatchSemaphore(value: 0)
        let req = PermissionRequest(
            kind: .toolUse,
            title: "Run shell command",
            detail: "rm -rf node_modules && npm install",
            toolName: "Bash",
            source: "Demo",
            cwd: NSHomeDirectory(),
            resolver: { decision in
                NSLog("Demo permission resolved: \(decision.rawValue)")
                semaphore.signal()
            }
        )
        state.enqueuePermission(req)
        DispatchQueue.global().async { _ = semaphore.wait(timeout: .now() + 60) }
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
        ))
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
        } else if activity.isEmpty {
            statusItem.title = "Session: \(project)"
        } else {
            statusItem.title = "\(project) — \(activity)"
        }
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
        let alert = NSAlert()
        alert.messageText = "Send message to Claude"
        alert.informativeText = state.currentProject.isEmpty
            ? "Will type into the currently-frontmost terminal."
            : "Will type into the terminal running session: \(state.currentProject)"

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        input.placeholderString = "type your message…"
        alert.accessoryView = input
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")

        // Make sure the alert can take focus.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { input.becomeFirstResponder() }

        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return }
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let target = state.lastOriginatorBundleID
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            ?? "com.apple.Terminal"
        TerminalAutomator.sendText(text, toBundleID: target)
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
        }
        refreshLoginItem()
    }
}
