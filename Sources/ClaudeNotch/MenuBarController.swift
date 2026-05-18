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
            button.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "ClaudeNotch")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        let buildStamp = MenuBarController.buildTimestamp()
        let header = NSMenuItem(title: "ClaudeNotch — :53127 — build \(buildStamp)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        statusItem = NSMenuItem(title: "No active session", action: #selector(clearSession), keyEquivalent: "")
        statusItem.target = self
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

        let setupItem = NSMenuItem(title: "Setup…", action: #selector(showOnboarding), keyEquivalent: ",")
        setupItem.target = self
        menu.addItem(setupItem)

        let quit = NSMenuItem(title: "Quit ClaudeNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self
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
            .throttle(for: .milliseconds(400), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _, _, _ in self?.refreshStatusLine() }
            .store(in: &cancellables)

        refreshLoginItem()
        refreshPermissions()
        refreshRecentProjects()
        refreshStatusLine()

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
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        Task { @MainActor [weak self] in self?.isMenuOpen = false }
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
