import AppKit
import ServiceManagement
import Combine
import IOKit.hid

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    let item: NSStatusItem
    let state: AppState

    private var allowlistItem: NSMenuItem!
    private var allowlistMenu: NSMenu!
    private var loginItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!
    private var inputMonitoringItem: NSMenuItem!
    private var recentProjectsItem: NSMenuItem!
    private var resumeLastItem: NSMenuItem!
    private var crashLogsItem: NSMenuItem!
    // Cached most-recent session so the menu handler doesn't have to re-scan
    // disk on click; refreshed off-main in menuWillOpen.
    private var lastResumable: ResumableSession?
    private var recentProjectsMenu: NSMenu!
    private var statusItem: NSMenuItem!
    private var persistentNotchItem: NSMenuItem!
    private var petModeItem: NSMenuItem!
    private var breakRemindersItem: NSMenuItem!
    private var longRunItem: NSMenuItem!
    private var rateLimitItem: NSMenuItem!
    var autoApproveItem: NSMenuItem!
    var autoApproveMenu: NSMenu!
    var snoozeItem: NSMenuItem!
    var snoozeMenu: NSMenu!
    private var soundItem: NSMenuItem!
    var soundMenu: NSMenu!
    var costBudgetItem: NSMenuItem!
    var costBudgetMenu: NSMenu!
    var statusBarItem: NSMenuItem!
    var statusBarMenu: NSMenu!
    var notchTitleItem: NSMenuItem!
    var notchTitleMenu: NSMenu!
    private var touchIDItem: NSMenuItem?   // only when this Mac has biometrics
    private var notifyMirrorItem: NSMenuItem!
    private var completionNotifItem: NSMenuItem!
    private var digestNotifItem: NSMenuItem!
    private var screenCaptureItem: NSMenuItem!
    private var touchedFilesMenu: NSMenu!
    private var touchedFilesItem: NSMenuItem!
    private var menuSpendItem: NSMenuItem!
    // Keep-open row views for the Sound submenu — clicking these does not
    // dismiss the menu, so the user can preview multiple sounds.
    var soundRowViews: [String: KeepOpenRowView] = [:]
    var muteRowView: KeepOpenRowView?
    var perToolRowView: KeepOpenRowView?
    private var updateItem: NSMenuItem!
    private var serverItem: NSMenuItem!
    private var spendItem: NSMenuItem!
    private var spendMenu: NSMenu!
    private var checkUpdateItem: NSMenuItem!
    var insightsMenu: NSMenu!
    private var insightsItem: NSMenuItem!
    var claudeUsageMenu: NSMenu!
    private var claudeUsageItem: NSMenuItem!
    var cachedClaudeUsage: ClaudeUsageReader.Usage?
    var claudeUsageComputing = false
    private var cancellables = Set<AnyCancellable>()
    private var permissionsTimer: Timer?
    private var isMenuOpen = false

    private let onboarding: OnboardingWindowController
    private let settings: SettingsWindowController

    init(state: AppState, onboarding: OnboardingWindowController, settings: SettingsWindowController) {
        self.state = state
        self.onboarding = onboarding
        self.settings = settings
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            button.image = MenuBarController.statusIcon()
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        let buildStamp = MenuBarController.buildTimestamp()
        let header = NSMenuItem(title: String(format: L("%1$@  ·  build %2$@", comment: "Menu header. %1$@ is the app name, %2$@ a build timestamp"), AppInfo.displayName, buildStamp),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        statusItem = NSMenuItem(title: L("No Active Session", comment: "Menu item shown when no agent is running"),
                                action: #selector(clearSession), keyEquivalent: "")
        statusItem.target = self
        menu.addItem(statusItem)

        // Hidden while the hook server is listening, which is almost always.
        // When it is not, this is the most important row in the menu: nothing
        // else the app shows means anything if it is not receiving hooks.
        serverItem = NSMenuItem(title: L("Not receiving prompts", comment: "Menu item shown when the hook server is not listening"),
                                action: #selector(showServerProblem), keyEquivalent: "")
        serverItem.target = self
        serverItem.isHidden = true
        menu.addItem(serverItem)

        // Hidden until the update checker finds a newer release.
        updateItem = NSMenuItem(title: L("Update available", comment: "Menu item: a newer release exists"),
                                action: #selector(openUpdate), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)

        // Spend breakdown submenu (today / 5-hour / week), filled on menu open.
        spendMenu = NSMenu()
        spendItem = NSMenuItem(title: L("Spend", comment: "Menu item opening the cost breakdown"), action: nil, keyEquivalent: "")
        spendItem.submenu = spendMenu
        menu.addItem(spendItem)

        menu.addItem(.separator())

        // Start Claude in a folder
        let startHere = NSMenuItem(title: L("Start Claude in Folder…", comment: "Menu item: pick a folder and launch Claude there"),
                                   action: #selector(startClaudePicker), keyEquivalent: "o")
        startHere.target = self
        menu.addItem(startHere)

        // Resume the most recent Claude Code session on disk — one click back
        // into where you were after a terminal was closed by accident. Title +
        // enabled state are refreshed in menuWillOpen from what's on disk.
        resumeLastItem = NSMenuItem(title: L("Resume Last Session", comment: "Menu item: reopen the most recent session"),
                                    action: #selector(resumeLast), keyEquivalent: "")
        resumeLastItem.target = self
        menu.addItem(resumeLastItem)

        // One-click standup: copy today's "what I shipped" to the clipboard,
        // built from finished sessions + git commits, ready to paste.
        let standupMI = NSMenuItem(title: L("Copy Today's Standup", comment: "Menu item: copy a summary of today's work"),
                                   action: #selector(copyStandup), keyEquivalent: "")
        standupMI.target = self
        menu.addItem(standupMI)

        // Recent projects submenu (populated dynamically)
        recentProjectsMenu = NSMenu()
        recentProjectsItem = NSMenuItem(title: L("Recent Projects", comment: "Menu item opening the recent-project launcher"), action: nil, keyEquivalent: "")
        recentProjectsItem.submenu = recentProjectsMenu
        menu.addItem(recentProjectsItem)

        // Files Claude edited this session (populated dynamically); click to open.
        touchedFilesMenu = NSMenu()
        touchedFilesItem = NSMenuItem(title: L("Files Touched", comment: "Menu item listing the files edited this session"), action: nil, keyEquivalent: "")
        touchedFilesItem.submenu = touchedFilesMenu
        touchedFilesItem.isHidden = true
        // Migrated to Settings > Session; created (refresh code still runs on it)
        // but no longer shown in the slimmed menu.

        menu.addItem(.separator())

        // EVERYTHING below is created but NOT added to the menu. All of these
        // settings, toggles, and submenus now live in the Settings window
        // (⌥⌘,). The objects stay alive so the existing menu-refresh code and
        // the @objc toggle handlers keep compiling and running untouched; they
        // simply aren't shown. The menu is now: session status, quick task
        // actions, Settings, Quit.

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
        // Same list Settings builds its rows from, so a verdict added there
        // turns up here too. The index rides on the item's tag rather than a
        // selector per verdict, which would quietly send a fourth one to the
        // wrong handler.
        for (index, item) in DemoCards.auditVerdicts.enumerated() {
            let mi = NSMenuItem(title: item.title,
                                action: #selector(triggerDemoAudit(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.tag = index
            demosMenu.addItem(mi)
        }
        addDemo("Thinking Pulse",       #selector(triggerDemoThinking),   "t")
        addDemo("Cost Budget Alert",    #selector(triggerDemoBudget),     "")
        addDemo("Budget Hard-Stop",     #selector(triggerDemoBudgetBlock), "")

        // Pet Mode's activities fire on their own schedule, so some are rare
        // and none are reproducible on demand. This plays any of them now —
        // for showing the thing off, and for eyeballing the pose math.
        //
        // Keep-open rows (as the sound previews use): you almost never want to
        // watch exactly one activity, and reopening the menu and walking back
        // down to Demos > Pet between each is the whole friction.
        demosMenu.addItem(.separator())
        let petMenu = NSMenu()
        func addPetRow(_ title: String, _ activities: @escaping () -> [PetActivity]) {
            let row = KeepOpenRowView(title: title, checked: false, width: 200)
            row.handler = { [weak self] in self?.state.demoPet(activities()) }
            let holder = NSMenuItem()
            holder.view = row
            petMenu.addItem(holder)
        }
        let everyday = PetActivity.everydayCases
        let specials = PetActivity.specialCases
        addPetRow("Play All") { everyday + specials }
        petMenu.addItem(.separator())
        for activity in everyday {
            addPetRow(activity.title) { [activity] }
        }
        // Guest appearances sit under their own heading, dated, so a costume
        // reads as a thing from a particular month and not as a stray animation.
        if !specials.isEmpty {
            petMenu.addItem(.separator())
            let header = NSMenuItem(title: "Guest appearances", action: nil, keyEquivalent: "")
            header.isEnabled = false
            petMenu.addItem(header)
            for activity in specials {
                guard let guest = activity.special else { continue }
                addPetRow("\(guest.name), \(SettingsView.arrivedLabel(guest.addedOn).lowercased())") {
                    [activity]
                }
            }
        }
        let petItem = NSMenuItem(title: "Pet", action: nil, keyEquivalent: "")
        petItem.submenu = petMenu
        demosMenu.addItem(petItem)

        let demosItem = NSMenuItem(title: "Demos", action: nil, keyEquivalent: "")
        demosItem.submenu = demosMenu
        _ = demosItem

        // Insights — local usage stats (rebuilt each time the menu opens).
        insightsMenu = NSMenu()
        insightsItem = NSMenuItem(title: L("Insights", comment: "Submenu: local usage statistics"), action: nil, keyEquivalent: "")
        insightsItem.submenu = insightsMenu

        // Claude Usage — token usage + estimated cost from Claude Code's own
        // transcripts. Rebuilt on open; the parse runs off the main thread.
        claudeUsageMenu = NSMenu()
        claudeUsageItem = NSMenuItem(title: L("Claude Usage", comment: "Submenu: token usage read from the transcripts"), action: nil, keyEquivalent: "")
        claudeUsageItem.submenu = claudeUsageMenu

        // Permissions & setup — grouped into a submenu.
        let permsMenu = NSMenu()

        accessibilityItem = NSMenuItem(title: L("Accessibility: Checking…", comment: "Permission row before the check finishes"),
                                       action: #selector(promptAccessibility), keyEquivalent: "")
        accessibilityItem.target = self
        permsMenu.addItem(accessibilityItem)

        inputMonitoringItem = NSMenuItem(title: L("Input Monitoring: Checking…", comment: "Permission row before the check finishes"),
                                         action: #selector(promptInputMonitoring), keyEquivalent: "")
        inputMonitoringItem.target = self
        permsMenu.addItem(inputMonitoringItem)

        permsMenu.addItem(.separator())

        allowlistMenu = NSMenu()
        allowlistItem = NSMenuItem(title: L("Always-Allow Rules: —", comment: "Submenu title when there are no allow rules"), action: nil, keyEquivalent: "")
        allowlistItem.submenu = allowlistMenu
        permsMenu.addItem(allowlistItem)

        // Touch ID / Face ID confirmation for destructive commands — only offered
        // on Macs that actually have biometrics.
        if BiometricAuth.isAvailable {
            permsMenu.addItem(.separator())
            let ti = NSMenuItem(title: String(format: L("Require %@ for dangerous commands", comment: "Toggle. %@ is Touch ID or Face ID"), BiometricAuth.label),
                                action: #selector(toggleTouchID), keyEquivalent: "")
            ti.target = self
            ti.state = state.requireTouchID ? .on : .off
            permsMenu.addItem(ti)
            touchIDItem = ti
        }

        permsMenu.addItem(.separator())
        notifyMirrorItem = NSMenuItem(title: L("Mirror Alerts to Notifications", comment: "Toggle: also post cards to Notification Center"),
                                      action: #selector(toggleNotificationMirror), keyEquivalent: "")
        notifyMirrorItem.target = self
        notifyMirrorItem.toolTip = L("Also send blocking permission prompts to Notification Center so you can Allow or Deny from the lock screen or another Space. Respects Do Not Disturb.", comment: "Tooltip on the notification mirror toggle")
        notifyMirrorItem.state = state.mirrorToNotificationCenter ? .on : .off
        permsMenu.addItem(notifyMirrorItem)

        completionNotifItem = NSMenuItem(title: L("Notify When Claude Finishes", comment: "Toggle: notify on task completion"),
                                         action: #selector(toggleCompletionNotifications), keyEquivalent: "")
        completionNotifItem.target = self
        completionNotifItem.toolTip = L("Send a native notification when a Claude task completes and you are in another app. Off by default.", comment: "Tooltip on the completion notification toggle")
        completionNotifItem.state = state.completionNotificationsEnabled ? .on : .off
        permsMenu.addItem(completionNotifItem)

        digestNotifItem = NSMenuItem(title: L("Daily Spend Digest", comment: "Toggle: a morning summary of yesterday's spend"),
                                     action: #selector(toggleDigestNotifications), keyEquivalent: "")
        digestNotifItem.target = self
        digestNotifItem.toolTip = L("Send a morning notification with yesterday's cost, session count, and top project. Off by default.", comment: "Tooltip on the daily digest toggle")
        digestNotifItem.state = state.digestNotificationsEnabled ? .on : .off
        permsMenu.addItem(digestNotifItem)

        permsMenu.addItem(.separator())
        screenCaptureItem = NSMenuItem(title: L("Hide from Screen Recordings", comment: "Toggle: keep the notch out of screen shares"),
                                       action: #selector(toggleScreenCapture), keyEquivalent: "")
        screenCaptureItem.target = self
        screenCaptureItem.toolTip = L("Keep the notch out of screen shares, recordings, and other apps' screenshots. You still see it live; viewers don't. On by default.", comment: "Tooltip on the hide-from-capture toggle")
        screenCaptureItem.state = state.hideFromScreenCapture ? .on : .off
        permsMenu.addItem(screenCaptureItem)

        let permsItem = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        permsItem.submenu = permsMenu
        _ = permsItem

        persistentNotchItem = NSMenuItem(title: L("Persistent Notch Display", comment: "Toggle: keep the notch card open"),
                                         action: #selector(togglePersistentNotchDisplay), keyEquivalent: "")
        persistentNotchItem.target = self

        petModeItem = NSMenuItem(title: L("Pet Mode", comment: "Toggle: show the pet in the notch"), action: #selector(togglePetMode), keyEquivalent: "")
        petModeItem.target = self

        breakRemindersItem = NSMenuItem(title: L("Break Reminders", comment: "Toggle: remind me to take a break"),
                                       action: #selector(toggleBreakReminders), keyEquivalent: "")
        breakRemindersItem.target = self

        longRunItem = NSMenuItem(title: L("Alert on Long Tool Runs", comment: "Toggle: warn when a tool call takes a long time"),
                                 action: #selector(toggleLongRun), keyEquivalent: "")
        longRunItem.target = self

        rateLimitItem = NSMenuItem(title: L("Warn Near Rate Limits", comment: "Toggle: warn as a usage limit approaches"),
                                   action: #selector(toggleRateLimit), keyEquivalent: "")
        rateLimitItem.target = self

        menuSpendItem = NSMenuItem(title: L("Show Today's Spend in Menu Bar", comment: "Toggle: put the day's cost in the menu bar"),
                                   action: #selector(toggleMenuSpend), keyEquivalent: "")
        menuSpendItem.target = self
        menuSpendItem.state = state.showSpendInMenuBar ? .on : .off

        // Auto-Approve submenu: permanent toggle + timed windows.
        autoApproveMenu = NSMenu()
        autoApproveItem = NSMenuItem(title: L("Auto-Approve", comment: "Submenu: approve requests without asking"), action: nil, keyEquivalent: "")
        autoApproveItem.submenu = autoApproveMenu

        // Snooze submenu: pause non-blocking cards for a window.
        snoozeMenu = NSMenu()
        snoozeItem = NSMenuItem(title: L("Snooze", comment: "Submenu: pause non-blocking cards"), action: nil, keyEquivalent: "")
        snoozeItem.submenu = snoozeMenu

        // Sound submenu: mute + per-tool toggle + alert sound picker.
        soundMenu = NSMenu()
        soundItem = NSMenuItem(title: L("Sound", comment: "Submenu: alert sound settings"), action: nil, keyEquivalent: "")
        soundItem.submenu = soundMenu

        // Cost Budget submenu: per-session + daily $ caps with a heads-up alert.
        costBudgetMenu = NSMenu()
        costBudgetItem = NSMenuItem(title: L("Cost Budget", comment: "Submenu: spending caps"), action: nil, keyEquivalent: "")
        costBudgetItem.submenu = costBudgetMenu

        // Status Bar submenu: what the bottom bar shows + context-window override.
        statusBarMenu = NSMenu()
        statusBarItem = NSMenuItem(title: L("Status Bar", comment: "Submenu: what the notch status bar shows"), action: nil, keyEquivalent: "")
        statusBarItem.submenu = statusBarMenu

        // Notch Title submenu: what the first segment of the title shows.
        notchTitleMenu = NSMenu()
        notchTitleItem = NSMenuItem(title: L("Notch Title", comment: "Submenu: what the notch title shows"), action: nil, keyEquivalent: "")
        notchTitleItem.submenu = notchTitleMenu

        loginItem = NSMenuItem(title: L("Launch at Login", comment: "Toggle: start the app when the Mac logs in"),
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self

        checkUpdateItem = NSMenuItem(title: L("Check for Updates…", comment: "Menu item: look for a newer release now"),
                                     action: #selector(checkForUpdatesNow), keyEquivalent: "")
        checkUpdateItem.target = self

        // The one config entry the menu keeps: open the full settings window.
        let settingsItem = NSMenuItem(title: L("Settings…", comment: "Menu item: open the settings window"),
                                      action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command, .option]
        settingsItem.target = self
        menu.addItem(settingsItem)

        let feedback = NSMenuItem(title: L("Send Feedback…", comment: "Menu item: report a bug or ask for a feature"),
                                  action: #selector(sendFeedback), keyEquivalent: "")
        feedback.target = self
        menu.addItem(feedback)

        // Only appears once a crash report has actually been written, so it's a
        // "grab this file for your bug report" shortcut, not permanent clutter.
        crashLogsItem = NSMenuItem(title: L("Reveal Crash Logs…", comment: "Menu item: show the crash report files in Finder"),
                                   action: #selector(revealCrashLogs), keyEquivalent: "")
        crashLogsItem.target = self
        crashLogsItem.isHidden = true
        menu.addItem(crashLogsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: String(format: L("Quit %@", comment: "Menu item: quit the app. %@ is the app name"), AppInfo.displayName),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

        state.$sessions
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refreshBadge() }
            .store(in: &cancellables)

        // The plan is read on a timer rather than pushed by a hook, so the badge
        // has to follow the value instead of the session that caused it.
        state.$plan
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshBadge() }
            .store(in: &cancellables)

        // A dead hook server changes the meaning of every other row in this
        // menu, so it drives the icon as well as its own item.
        state.$serverStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.refreshServerHealth(status) }
            .store(in: &cancellables)

        refreshLoginItem()
        refreshPermissions()
        refreshRecentProjects()
        refreshStatusLine()
        refreshBadge()
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
            // The menu now shows only the session status and the recent-projects
            // launcher; everything else moved to Settings. Refresh just those two
            // (and skip the expensive insights / Claude-usage parses that fed the
            // now-hidden submenus).
            self.refreshStatusLine()
            self.refreshRecentProjects()
            self.refreshResumeLast()
            self.refreshSpend()
            self.crashLogsItem?.isHidden = !CrashReporter.hasReports
        }
    }

    /// Fill the Spend submenu with today / 5-hour / week cost, computed off the
    /// main thread from Claude Code's transcripts.
    private func refreshSpend() {
        Task.detached(priority: .utility) {
            let u = ClaudeUsageReader.compute()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.spendMenu.removeAllItems()
                for (label, cost) in [(L("Today", comment: "Spend submenu row: cost so far today"), u.today.costUSD),
                                      (L("Last 5 hours", comment: "Spend submenu row: cost in the rolling five-hour window"), u.fiveHour.costUSD),
                                      (L("This week", comment: "Spend submenu row: cost this week"), u.week.costUSD)] {
                    let mi = NSMenuItem(title: String(format: L("%1$@: %2$@", comment: "Spend submenu row. %1$@ is a period, %2$@ is a money amount"),
                                                      label, ClaudeUsageReader.fmtMoney(cost)),
                                        action: nil, keyEquivalent: "")
                    mi.isEnabled = false
                    self.spendMenu.addItem(mi)
                }
                let note = NSMenuItem(title: L("Estimated at API prices, not your subscription bill", comment: "Footnote under the spend breakdown"),
                                      action: nil, keyEquivalent: "")
                note.isEnabled = false
                self.spendMenu.addItem(note)
                self.spendMenu.addItem(.separator())
                let more = NSMenuItem(title: L("Full usage in Settings…", comment: "Spend submenu row linking to the settings window"),
                                      action: #selector(self.showSettings), keyEquivalent: "")
                more.target = self
                self.spendMenu.addItem(more)
                self.spendItem.title = String(format: L("Est. cost  ·  %@ today", comment: "Spend menu title. %@ is today's estimated cost"),
                                              ClaudeUsageReader.fmtMoney(u.today.costUSD))
            }
        }
    }

    /// Load the newest resumable session off-main and reflect it in the menu:
    /// the item names the project and is disabled when there is nothing to
    /// resume.
    private func refreshResumeLast() {
        let includeCodex = HookInstaller.isCodexInstalled
        Task.detached(priority: .utility) {
            let recent = SessionResumer.mostRecent(includeCodex: includeCodex)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.lastResumable = recent
                if let recent {
                    self.resumeLastItem.title = String(format: L("Resume Last Session: %@", comment: "Menu item naming the session that would be resumed. %@ is the project"),
                                                       recent.project)
                    self.resumeLastItem.isEnabled = true
                } else {
                    self.resumeLastItem.title = L("Resume Last Session", comment: "Menu item: reopen the most recent session")
                    self.resumeLastItem.isEnabled = false
                }
            }
        }
    }

    @objc private func revealCrashLogs() {
        CrashReporter.revealInFinder()
    }

    @objc private func sendFeedback() {
        SettingsView.openFeedback()
    }

    @objc private func resumeLast() {
        guard let s = lastResumable else { return }
        TerminalAutomator.resume(model: s.model, sessionId: s.id, in: s.cwd)
    }

    /// Also reachable from `claudenotch://standup`, hence not private.
    @objc func copyStandup() {
        let records = state.sessionHistory
        let dirs = state.recentProjects
        Task { [weak self] in
            let text = await Task.detached(priority: .userInitiated) {
                AppState.standupText(records: records, extraDirs: dirs, days: 1)
            }.value
            await MainActor.run {
                NSPasteboard.copyString(text)
                self?.state.enqueueCompleted(CompletedTask(
                    title: L("Standup copied", comment: "Card title after copying the standup"),
                    detail: L("Today's \"what I shipped\" is on your clipboard.", comment: "Card body after copying the standup"),
                    source: "ClaudeNotch",
                    cwd: ""
                ))
            }
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        Task { @MainActor [weak self] in self?.isMenuOpen = false }
    }

    private func refreshPermissions() {
        // Accessibility (for keystroke injection into terminal)
        if TerminalAutomator.isAccessibilityTrusted {
            accessibilityItem.state = .on
            accessibilityItem.title = L("Accessibility: Granted", comment: "Permission row once accessibility access is granted")
            accessibilityItem.isEnabled = false
        } else {
            accessibilityItem.state = .off
            accessibilityItem.title = L("Grant Accessibility…", comment: "Permission row prompting for accessibility access")
            accessibilityItem.isEnabled = true
        }

        // Input Monitoring (for Enter/Esc shortcuts in notch)
        let im = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if im == kIOHIDAccessTypeGranted {
            inputMonitoringItem.state = .on
            inputMonitoringItem.title = L("Input Monitoring: Granted", comment: "Permission row once input monitoring is granted")
            inputMonitoringItem.isEnabled = false
        } else {
            inputMonitoringItem.state = .off
            inputMonitoringItem.title = L("Grant Input Monitoring…", comment: "Permission row prompting for input monitoring")
            inputMonitoringItem.isEnabled = true
        }

        notifyMirrorItem?.state = state.mirrorToNotificationCenter ? .on : .off
        completionNotifItem?.state = state.completionNotificationsEnabled ? .on : .off
        digestNotifItem?.state = state.digestNotificationsEnabled ? .on : .off
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
        allowlistMenu.removeAllItems()
        if rules.isEmpty {
            allowlistItem.title = L("Always-Allow Rules: —", comment: "Submenu title when there are no allow rules")
            allowlistItem.isEnabled = false
            return
        }
        allowlistItem.isEnabled = true
        allowlistItem.title = String(format: L("Always-Allow Rules (%d)", comment: "Submenu title. %d is how many rules exist"), rules.count)
        let sorted = rules.sorted { $0.displayLabel < $1.displayLabel }
        for rule in sorted {
            let ruleItem = NSMenuItem(title: rule.displayLabel, action: #selector(removeOneAllowRule(_:)), keyEquivalent: "")
            ruleItem.target = self
            ruleItem.toolTip = L("Click to remove this rule, matching prompts will ask again.", comment: "Tooltip on an allow-rule row")
            ruleItem.representedObject = rule
            allowlistMenu.addItem(ruleItem)
        }
        allowlistMenu.addItem(.separator())
        let clearItem = NSMenuItem(title: L("Clear All", comment: "Menu item: delete every allow rule"), action: #selector(clearAllowlist), keyEquivalent: "")
        clearItem.target = self
        allowlistMenu.addItem(clearItem)
    }

    private func refreshLoginItem() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            loginItem.state = (status == .enabled) ? .on : .off
            loginItem.isEnabled = (Bundle.main.bundlePath.hasSuffix(".app"))
            if !loginItem.isEnabled {
                loginItem.title = L("Launch at Login (install to /Applications first)", comment: "Login toggle, disabled because the app is not installed")
            } else if status == .requiresApproval {
                loginItem.title = L("Launch at Login, Approve in System Settings…", comment: "Login toggle, waiting on macOS approval")
            } else {
                loginItem.title = L("Launch at Login", comment: "Toggle: start the app when the Mac logs in")
            }
        } else {
            loginItem.isEnabled = false
        }
    }

    @objc private func triggerDemoPermission() {
        state.enqueuePermission(DemoCards.permission(), bypassRules: true)
    }

    @objc private func triggerDemoDangerous() {
        state.enqueuePermission(DemoCards.dangerous(), bypassRules: true)
    }

    @objc private func triggerDemoDiff() {
        state.enqueuePermission(DemoCards.diff(), bypassRules: true)
    }

    @objc private func triggerDemoAutoApprove() {
        state.demoAutoApprove(DemoCards.autoApproved())
    }

    @objc private func triggerDemoNotification() {
        state.enqueuePermission(DemoCards.notification(), bypassRules: true)
    }

    @objc private func triggerDemoCompleted() {
        state.enqueueCompleted(DemoCards.completed())
    }

    /// The completion audit's verdicts, which were reachable from Settings and
    /// from nowhere in the menu bar. The tag says which one.
    @objc private func triggerDemoAudit(_ sender: NSMenuItem) {
        guard DemoCards.auditVerdicts.indices.contains(sender.tag) else { return }
        state.enqueueCompleted(DemoCards.audited(DemoCards.auditVerdicts[sender.tag].verdict))
    }

    @objc private func triggerDemoThinking() {
        state.pingThinking(label: "Editing AuthMiddleware.swift")
    }

    @objc private func triggerDemoBudget() {
        state.demoBudgetAlert()
    }

    @objc private func triggerDemoBudgetBlock() {
        state.demoBudgetBlock()
    }



    @objc private func clearAllowlist() {
        state.clearAllowlist()
    }

    @objc private func removeOneAllowRule(_ sender: NSMenuItem) {
        guard let rule = sender.representedObject as? AllowRule else { return }
        state.removeAllowRule(rule)
    }

    private func refreshStatusLine() {
        let project = state.currentProject
        let activity = state.lastActivity
        if project.isEmpty {
            statusItem.title = L("No active session", comment: "Menu item shown when no agent is running")
            statusItem.isEnabled = false
        } else if activity.isEmpty {
            statusItem.title = String(format: L("%@ ,  click to clear", comment: "Menu item naming the running project. %@ is the project"), project)
            statusItem.isEnabled = true
        } else {
            statusItem.title = String(format: L("%1$@, %2$@  (click to clear)", comment: "Menu item naming the project and what it is doing. %1$@ is the project, %2$@ is the activity"), project, activity)
            statusItem.isEnabled = true
        }
    }

    private func refreshBadge() {
        guard let button = item.button else { return }
        let count = state.workingSessionCount
        var parts: [String] = []
        if count > 0 { parts.append("\(count)") }
        if state.showSpendInMenuBar {
            let spend = state.todaySpendUSD
            if spend >= 0.005 { parts.append(String(format: "$%.2f", spend)) }
        }
        if state.showPlanInMenuBar, let plan = state.menuBarPlanLabel { parts.append(plan) }
        if parts.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            let str = NSAttributedString(string: " " + parts.joined(separator: " · "), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ])
            button.attributedTitle = str
        }
    }

    @objc private func clearSession() {
        state.clearSession()
    }

    private func refreshRecentProjects() {
        recentProjectsMenu.removeAllItems()
        if state.recentProjects.isEmpty {
            let empty = NSMenuItem(title: L("(no projects yet, start Claude in any folder)", comment: "Placeholder row in the recent-projects submenu"),
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentProjectsMenu.addItem(empty)
            return
        }
        for cwd in state.recentProjects {
            let basename = (cwd as NSString).lastPathComponent
            let item = NSMenuItem(title: String(format: L("↻  %1$@ ,  %2$@", comment: "Recent-project row. %1$@ is the folder name, %2$@ is its full path"), basename, cwd),
                                  action: #selector(launchRecentProject(_:)), keyEquivalent: "")
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
        panel.prompt = L("Start Claude here", comment: "Confirm button in the folder picker")
        panel.message = L("Pick a folder. Terminal.app will open with `cd <folder> && claude`.", comment: "Explanation in the folder picker")
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

    /// Show the server problem as a card, for anyone who reached the menu
    /// before the card that was raised at launch, or dismissed it.
    @objc private func showServerProblem() {
        state.noteServerFailed(state.serverStatus)
    }

    /// The menu row and the menu bar icon both follow the server's health. The
    /// icon matters more: most people never open the menu, and an app that
    /// cannot receive hooks should not look identical to one that can.
    private func refreshServerHealth(_ status: AppState.ServerStatus) {
        let label = AppState.serverFailureMenuLabel(status)
        serverItem.title = label ?? ""
        serverItem.isHidden = (label == nil)
        if let button = item.button {
            button.image = status.isHealthy
                ? MenuBarController.statusIcon()
                : NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                          accessibilityDescription: String(format: L("%@ is not receiving prompts",
                                                      comment: "Accessibility label for the menu bar icon when the hook server is down"),
                                                                       AppInfo.displayName))
            button.image?.isTemplate = true
            button.toolTip = label
        }
    }

    @objc private func showSettings() {
        settings.show()
    }

    // MARK: - Updates

    private func handleUpdateAvailable(_ version: String, userInitiated: Bool) {
        state.availableUpdateVersion = version
        updateItem.title = String(format: L("↑ Update available: v%@, Download", comment: "Menu item when a newer release exists. %@ is the version"), version)
        updateItem.isHidden = false
        checkUpdateItem.title = L("Check for Updates…", comment: "Menu item: look for a newer release now")
        checkUpdateItem.isEnabled = true
        guard userInitiated else {
            // Background poll: most users never open this menu, so also show a
            // one-time notch card (deduped per version inside showUpdateCard).
            state.showUpdateCard(version: version)
            return
        }
        // Bring the alert to the front — accessory apps need to activate first
        // or the alert ends up behind everything.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Update available", comment: "Dialog title when a newer release exists")
        alert.informativeText = String(format: L("ClaudeNotch v%1$@ is available. You're on v%2$@.", comment: "Update dialog body. %1$@ is the new version, %2$@ is the installed one"),
                                       version, UpdateChecker.shared.currentVersion)
        alert.alertStyle = .informational
        // Update Now is the default button when the bundled updater is on disk:
        // it downloads, checks the DMG against the checksum published with the
        // release, quits, replaces and relaunches. Opening the releases page is
        // the fallback, and the only option without the script.
        let canSelfUpdate = TerminalAutomator.canSelfUpdate
        if canSelfUpdate {
            alert.addButton(withTitle: L("Update Now", comment: "Dialog button: install the new version"))
        }
        alert.addButton(withTitle: L("Download", comment: "Dialog button: open the release page"))
        alert.addButton(withTitle: L("Later", comment: "Dialog button: dismiss the update prompt"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if canSelfUpdate { TerminalAutomator.runUpdater() } else { openUpdate() }
        case .alertSecondButtonReturn where canSelfUpdate:
            openUpdate()
        default:
            break
        }
    }

    @objc private func openUpdate() {
        if let url = URL(string: UpdateChecker.shared.releasesPage) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkForUpdatesNow() {
        checkUpdateItem.title = L("Checking for Updates…", comment: "Menu item while the update check is running")
        checkUpdateItem.isEnabled = false
        UpdateChecker.shared.check(userInitiated: true)
        // Safety net: if no callback fires in 10s (network hang), re-enable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.checkUpdateItem.title = L("Check for Updates…", comment: "Menu item: look for a newer release now")
            self?.checkUpdateItem.isEnabled = true
        }
    }

    private func presentUpToDate() {
        checkUpdateItem.title = L("Check for Updates…", comment: "Menu item: look for a newer release now")
        checkUpdateItem.isEnabled = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("You're up to date", comment: "Dialog title when no newer release exists")
        alert.informativeText = String(format: L("ClaudeNotch v%@ is the latest version.", comment: "Dialog body when no newer release exists. %@ is the installed version"),
                                       UpdateChecker.shared.currentVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("OK", comment: "Dialog button: acknowledge and close"))
        alert.runModal()
    }

    private func presentCheckFailed() {
        checkUpdateItem.title = L("Check for Updates…", comment: "Menu item: look for a newer release now")
        checkUpdateItem.isEnabled = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Couldn't check for updates", comment: "Dialog title when the update check failed")
        alert.informativeText = L("Something went wrong reaching GitHub. Check your internet connection and try again.", comment: "Dialog body when the update check failed")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("OK", comment: "Dialog button: acknowledge and close"))
        alert.runModal()
    }

    // MARK: - Auto-Approve / Snooze / Sound actions

    @objc func toggleAutoApprove() {
        state.setAutoApprove(!state.autoApprove)
        refreshPrefs()
    }

    @objc func autoApproveForAction(_ sender: NSMenuItem) {
        state.enableAutoApprove(forMinutes: sender.tag)
        refreshPrefs()
    }

    @objc func turnOffAutoApprove() {
        state.setAutoApprove(false)
        refreshPrefs()
    }

    @objc func snoozeForAction(_ sender: NSMenuItem) {
        state.snooze(forMinutes: sender.tag)
        refreshPrefs()
    }

    @objc func cancelSnoozeAction() {
        state.cancelSnooze()
        refreshPrefs()
    }

    // Cost budgets. tag carries the dollar amount (0 = off).
    @objc func setSessionCapAction(_ sender: NSMenuItem) {
        state.setSessionCostCap(Double(sender.tag))
        refreshCostBudgetMenu()
    }

    @objc func setDailyCapAction(_ sender: NSMenuItem) {
        state.setDailyCostCap(Double(sender.tag))
        refreshCostBudgetMenu()
    }

    // Status-bar item toggle. tag maps to StatusBarItem index in CaseIterable order.
    @objc func toggleStatusBarItemAction(_ sender: NSMenuItem) {
        let allItems = StatusBarItem.allCases
        guard sender.tag < allItems.count else { return }
        let tapped = allItems[sender.tag]
        var current = state.statusBarItems
        if let idx = current.firstIndex(of: tapped) {
            current.remove(at: idx)
        } else if current.count < 2 {
            current.append(tapped)
        }
        state.setStatusBarItems(current)
        refreshStatusBarMenu()
    }

    // Context-window override. tag: 0 = auto, 1 = 200K, 2 = 1M.
    @objc func setContextWindowModeAction(_ sender: NSMenuItem) {
        let mode: ContextWindowMode = sender.tag == 1 ? .w200k : (sender.tag == 2 ? .w1M : .auto)
        state.setContextWindowMode(mode)
        refreshStatusBarMenu()
    }

    @objc private func togglePersistentNotchDisplay() {
        state.setPersistentNotchDisplay(!state.persistentNotchDisplay)
        refreshPrefs()
    }

    @objc private func togglePetMode() {
        state.setPetEnabled(!state.petEnabled)
        refreshPrefs()
    }

    @objc private func toggleBreakReminders() {
        state.setBreakRemindersEnabled(!state.breakRemindersEnabled)
        refreshPrefs()
    }

    @objc private func toggleLongRun() {
        state.setLongRunAlertsEnabled(!state.longRunAlertsEnabled)
        refreshPrefs()
    }

    @objc private func toggleRateLimit() {
        state.setRateLimitWarningsEnabled(!state.rateLimitWarningsEnabled)
        refreshPrefs()
    }

    @objc private func toggleTouchID() {
        state.setRequireTouchID(!state.requireTouchID)
        touchIDItem?.state = state.requireTouchID ? .on : .off
    }

    @objc private func toggleNotificationMirror() {
        state.setMirrorToNotificationCenter(!state.mirrorToNotificationCenter)
        notifyMirrorItem?.state = state.mirrorToNotificationCenter ? .on : .off
    }

    @objc private func toggleCompletionNotifications() {
        state.setCompletionNotificationsEnabled(!state.completionNotificationsEnabled)
        completionNotifItem?.state = state.completionNotificationsEnabled ? .on : .off
    }

    @objc private func toggleDigestNotifications() {
        state.setDigestNotificationsEnabled(!state.digestNotificationsEnabled)
        digestNotifItem?.state = state.digestNotificationsEnabled ? .on : .off
    }

    @objc private func toggleScreenCapture() {
        state.setHideFromScreenCapture(!state.hideFromScreenCapture)
        screenCaptureItem?.state = state.hideFromScreenCapture ? .on : .off
    }

    @objc private func toggleMenuSpend() {
        state.setShowSpendInMenuBar(!state.showSpendInMenuBar)
        menuSpendItem?.state = state.showSpendInMenuBar ? .on : .off
        refreshBadge()
    }

    /// Rebuild the Files Touched submenu from the current session — newest
    /// first, basename shown, full path in the tooltip, click opens the file.
    private func refreshTouchedFiles() {
        let files = state.currentTouchedFiles
        touchedFilesItem.isHidden = files.isEmpty
        guard !files.isEmpty else { return }
        touchedFilesItem.title = String(format: L("Files Touched (%d)", comment: "Submenu title. %d is how many files were edited"), files.count)
        touchedFilesMenu.removeAllItems()
        for path in files.reversed() {
            let item = NSMenuItem(title: (path as NSString).lastPathComponent,
                                  action: #selector(openTouchedFile(_:)), keyEquivalent: "")
            item.target = self
            item.toolTip = path
            item.representedObject = path
            touchedFilesMenu.addItem(item)
        }
        touchedFilesMenu.addItem(.separator())
        let reveal = NSMenuItem(title: L("Reveal All in Finder", comment: "Menu item: show every edited file in Finder"),
                                action: #selector(revealTouchedFiles), keyEquivalent: "")
        reveal.target = self
        touchedFilesMenu.addItem(reveal)
    }

    @objc private func openTouchedFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        AppState.openEditedFile(path)
    }

    @objc private func revealTouchedFiles() {
        let urls = state.currentTouchedFiles.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func toggleEnforceBudget() {
        state.setEnforceBudget(!state.enforceBudget)
        refreshCostBudgetMenu()
    }

    @objc func dismissDigest() {
        state.markDigestShown()
        refreshInsights()
    }

    // MARK: - Refresh

    private func refreshPrefs() {
        persistentNotchItem.state = state.persistentNotchDisplay ? .on : .off
        petModeItem.state = state.petEnabled ? .on : .off
        breakRemindersItem.state = state.breakRemindersEnabled ? .on : .off
        longRunItem.state = state.longRunAlertsEnabled ? .on : .off
        rateLimitItem.state = state.rateLimitWarningsEnabled ? .on : .off
        // Say how long you have actually been at it, so the toggle is not an
        // abstraction: it is describing the stretch you are in right now.
        let stretch = Int(state.focusStretch / 60)
        breakRemindersItem.title = stretch >= 5
            ? String(format: L("Break Reminders  (%dm at it)", comment: "Toggle title with how long you have been working. %d is minutes"), stretch)
            : L("Break Reminders", comment: "Toggle: remind me to take a break")
        refreshNotchTitleMenu()
        refreshAutoApproveMenu()
        refreshSnoozeMenu()
        refreshSoundMenu()
        refreshCostBudgetMenu()
        refreshStatusBarMenu()
    }

    @objc func setNotchTitleClaude() {
        state.setNotchTitleMode(.claude)
        refreshNotchTitleMenu()
    }

    @objc func setNotchTitleProject() {
        state.setNotchTitleMode(.project)
        refreshNotchTitleMenu()
    }

    @objc func setNotchTitleCustom() {
        // Accessory apps must activate first or the modal lands behind everything.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Custom notch title", comment: "Dialog title for setting the notch title")
        alert.informativeText = L("Shown as the first part of the notch title (for example \"MyApp · ready\"). Leave blank to use \"Claude\".", comment: "Dialog body for setting the notch title")
        alert.addButton(withTitle: L("Save", comment: "Dialog button: keep the entered value"))
        alert.addButton(withTitle: L("Cancel", comment: "Dialog button: discard and close"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = state.customNotchTitle
        field.placeholderString = L("Claude", comment: "Placeholder showing the default notch title")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            state.setCustomNotchTitle(field.stringValue)
        }
        refreshNotchTitleMenu()
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
            NSLog("ClaudeNotch: login item toggle failed, \(error)")
            presentLoginError(error)
        }
        refreshLoginItem()

        // If macOS now needs the user to approve the login item, take them
        // straight to the Login Items pane. Signing and notarizing did not
        // remove this: .requiresApproval is about the user's Login Items list,
        // not about the signature, so it still happens on a signed build.
        if svc.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func presentLoginError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("Couldn't change Launch at Login", comment: "Dialog title when the login item could not be toggled")
        alert.informativeText = String(format: L("%@\n\nMake sure ClaudeNotch is in /Applications, then try again.", comment: "Dialog body when the login item could not be toggled. %@ is the system error"),
                                       error.localizedDescription)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("OK", comment: "Dialog button: acknowledge and close"))
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
