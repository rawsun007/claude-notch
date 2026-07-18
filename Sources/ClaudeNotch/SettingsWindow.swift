import AppKit
import SwiftUI
import ServiceManagement
import IOKit.hid

/// The ClaudeNotch settings window: a sidebar of sections and a detail pane of
/// grouped toggle rows, in the shape of a standard macOS System Settings window
/// (and boring.notch's). Everything binds to AppState's `setXxx` setters, which
/// already persist, so a flip here survives a relaunch just like the menu did.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    weak var appState: AppState?
    /// Invoked by the About page's "Run setup again" button.
    var onOpenSetup: (() -> Void)?

    func show() {
        guard let appState else { return }
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: SettingsView(state: appState, onOpenSetup: onOpenSetup))
        let w = NSWindow(contentViewController: host)
        w.title = "ClaudeNotch Settings"
        w.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 720, height: 560))
        w.minSize = NSSize(width: 640, height: 460)
        w.center()
        w.delegate = SettingsWindowCloser.shared

        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class SettingsWindowCloser: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowCloser()
}

// MARK: - View

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case notch = "Notch"
    case pet = "Pet"
    case session = "Session"
    case alerts = "Alerts"
    case sounds = "Sounds"
    case budget = "Budget"
    case privacy = "Privacy"
    case usage = "Usage"
    case developer = "Developer"
    case about = "About"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .notch: return "menubar.rectangle"
        case .pet: return "pawprint"
        case .session: return "bubble.left.and.text.bubble.right"
        case .alerts: return "bell.badge"
        case .sounds: return "speaker.wave.2"
        case .budget: return "dollarsign.circle"
        case .privacy: return "lock.shield"
        case .usage: return "chart.bar"
        case .developer: return "hammer"
        case .about: return "info.circle"
        }
    }

    /// Grouped sidebar layout for easy navigation.
    static let nav: [(title: String, items: [SettingsSection])] = [
        ("Workspace", [.general, .notch, .pet]),
        ("Session", [.session]),
        ("Alerts & Cost", [.alerts, .sounds, .budget]),
        ("Info", [.usage, .privacy, .about]),
        ("Advanced", [.developer]),
    ]
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    var onOpenSetup: (() -> Void)? = nil
    @State private var section: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { section },
                set: { if let v = $0 { section = v } }
            )) {
                ForEach(SettingsSection.nav, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items) { s in
                            Label(s.rawValue, systemImage: s.symbol).tag(s)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            ScrollView {
                detail
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .general:   general
        case .notch:     notch
        case .pet:       pet
        case .session:   session
        case .alerts:    alerts
        case .sounds:    sounds
        case .budget:    budget
        case .privacy:   privacy
        case .usage:     usage
        case .developer: developer
        case .about:     about
        }
    }

    // MARK: pages

    private var general: some View {
        page("General") {
            group {
                row("Launch at login",
                    "Start ClaudeNotch automatically when you log in.",
                    Binding(get: { launchAtLoginEnabled }, set: { setLaunchAtLogin($0) }))
                divider
                row("Keep the notch open",
                    "Always show the notch card instead of hiding it behind the hardware notch until something happens.",
                    bind(\.persistentNotchDisplay, state.setPersistentNotchDisplay))
                divider
                row("Auto-approve permissions",
                    "Allow every tool request automatically. Turns the notch into a passive monitor. Use with care.",
                    bind(\.autoApprove, state.setAutoApprove))
                divider
                row("Show spend in the menu bar",
                    "Put the running session cost next to the menu-bar bell.",
                    bind(\.showSpendInMenuBar, state.setShowSpendInMenuBar))
            }

            sectionLabel("Quick actions")
            group {
                actionRow("Start Claude in a folder…", "play.circle") { startClaudePicker() }
                divider
                actionRow("Check for updates…", "arrow.down.circle") { UpdateChecker.shared.check(userInitiated: true) }
            }
        }
    }

    // Launch-at-login state and toggle, via ServiceManagement.
    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
    private func setLaunchAtLogin(_ on: Bool) {
        let svc = SMAppService.mainApp
        do {
            if on { try svc.register() } else { try svc.unregister() }
        } catch {
            NSLog("ClaudeNotch: settings login toggle failed — \(error)")
        }
        if svc.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func startClaudePicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start Claude"
        if panel.runModal() == .OK, let url = panel.url {
            TerminalAutomator.startClaude(in: url.path, message: nil)
        }
    }

    private var notch: some View {
        page("Notch") {
            sectionLabel("Title")
            group {
                pickerRow("What the title shows",
                          selection: Binding(get: { state.notchTitleMode },
                                             set: { state.setNotchTitleMode($0) })) {
                    Text("Claude").tag(NotchTitleMode.claude)
                    Text("Project name").tag(NotchTitleMode.project)
                    Text("Custom").tag(NotchTitleMode.custom)
                }
                if state.notchTitleMode == .custom {
                    divider
                    HStack {
                        Text("Custom title")
                        Spacer()
                        TextField("ClaudeNotch", text: Binding(
                            get: { state.customNotchTitle },
                            set: { state.setCustomNotchTitle($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 14)
                }
            }

            sectionLabel("Status bar")
            group {
                let items = StatusBarItem.allCases
                ForEach(Array(items.enumerated()), id: \.element) { idx, item in
                    row(item.menuLabel, nil, Binding(
                        get: { state.statusBarItems.contains(item) },
                        set: { on in
                            var next = StatusBarItem.allCases.filter { state.statusBarItems.contains($0) }
                            if on { if !next.contains(item) { next.append(item) } }
                            else { next.removeAll { $0 == item } }
                            state.setStatusBarItems(StatusBarItem.allCases.filter { next.contains($0) })
                        }))
                    if idx < items.count - 1 { divider }
                }
            }

            sectionLabel("Context window")
            group {
                pickerRow("Context window size",
                          selection: Binding(get: { state.contextWindowMode },
                                             set: { state.setContextWindowMode($0) })) {
                    Text("Auto").tag(ContextWindowMode.auto)
                    Text("200K").tag(ContextWindowMode.w200k)
                    Text("1M").tag(ContextWindowMode.w1M)
                }
            }

            group {
                row("Drop files to open Claude",
                    "Always on: drag a file or folder onto the notch to open Claude there.",
                    .constant(true))
                    .disabled(true)
            }
        }
    }

    private var pet: some View {
        page("Pet") {
            group {
                row("Pet Mode",
                    "Let the Claude mascot live on the notch: it peeks, strolls, hangs off the edge, naps, and celebrates finished tasks. Click it to boop it.",
                    bind(\.petEnabled, state.setPetEnabled))
            }
        }
    }

    private var alerts: some View {
        page("Alerts") {
            group {
                row("Plan-limit warnings",
                    "Warn as your 5-hour or weekly usage fills, once at 80% and once at 95%.",
                    bind(\.rateLimitWarningsEnabled, state.setRateLimitWarningsEnabled))
                divider
                row("Long-run alerts",
                    "Nudge you when a single run has been going for a long time.",
                    bind(\.longRunAlertsEnabled, state.setLongRunAlertsEnabled))
                divider
                row("Break reminders",
                    "Occasional reminder to step away after a long stretch at the keyboard.",
                    bind(\.breakRemindersEnabled, state.setBreakRemindersEnabled))
            }
            group {
                row("Completion notifications",
                    "Post a Notification Center banner when a task finishes.",
                    bind(\.completionNotificationsEnabled, state.setCompletionNotificationsEnabled))
                divider
                row("Daily digest",
                    "A once-a-day summary of what Claude did.",
                    bind(\.digestNotificationsEnabled, state.setDigestNotificationsEnabled))
                divider
                row("Mirror to Notification Center",
                    "Also send notch notifications to macOS Notification Center.",
                    bind(\.mirrorToNotificationCenter, state.setMirrorToNotificationCenter))
            }
        }
    }

    private var sounds: some View {
        page("Sounds") {
            group {
                row("Mute all sounds",
                    "Silence every notch sound.",
                    Binding(get: { state.soundMuted }, set: { state.setSoundMuted($0) }))
                divider
                row("Per-tool sounds",
                    "Different sound for different kinds of tool request.",
                    Binding(get: { state.perToolSounds }, set: { state.setPerToolSounds($0) }))
            }

            sectionLabel("Alert sound")
            group {
                HStack {
                    Text("Alert sound")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { state.alertSound },
                        set: { state.setAlertSound($0); NSSound(named: NSSound.Name($0))?.play() }
                    )) {
                        ForEach(AppState.availableSounds, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Button {
                        NSSound(named: NSSound.Name(state.alertSound))?.play()
                    } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 8).padding(.horizontal, 14)
            }
            .disabled(state.soundMuted)
            .opacity(state.soundMuted ? 0.5 : 1)
        }
    }

    private var budget: some View {
        page("Budget") {
            Text("Warn when estimated cost crosses a cap. Set a cap to 0 to disable it.")
                .font(.callout).foregroundStyle(.secondary)
            sectionLabel("Caps (USD)")
            group {
                capRow("Per session", get: { state.sessionCostCap }, set: { state.setSessionCostCap($0) })
                divider
                capRow("Per day", get: { state.dailyCostCap }, set: { state.setDailyCostCap($0) })
                divider
                capRow("Per 5-hour window", get: { state.fiveHourCostCap }, set: { state.setFiveHourCostCap($0) })
                divider
                capRow("Per week", get: { state.weeklyCostCap }, set: { state.setWeeklyCostCap($0) })
            }
            group {
                row("Hard-stop at the cap",
                    "Block new tool runs once a cap is crossed, instead of only warning.",
                    Binding(get: { state.enforceBudget }, set: { state.setEnforceBudget($0) }))
            }
        }
    }

    private func capRow(_ title: String, get: @escaping () -> Double, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("$")
            TextField("0", value: Binding(get: get, set: set), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 8).padding(.horizontal, 14)
    }

    private var privacy: some View {
        page("Privacy") {
            group {
                row("Hide from screen capture",
                    "Exclude the notch from screen shares, recordings, and other apps' screenshots. It renders commands, paths, and code, so this is on by default.",
                    bind(\.hideFromScreenCapture, state.setHideFromScreenCapture))
                divider
                row("Require Touch ID for permissions",
                    "Ask for Touch ID before allowing a tool request from the notch.",
                    bind(\.requireTouchID, state.setRequireTouchID))
            }

            sectionLabel("System permissions")
            group {
                permissionRow("Accessibility",
                              granted: AXIsProcessTrusted()) { state.promptAccessibility() }
                divider
                permissionRow("Input Monitoring",
                              granted: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted) {
                    _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            sectionLabel("Always-allow rules")
            if state.allowRules.isEmpty {
                Text("No always-allow rules. Approve a request with \u{201C}Always allow\u{201D} to add one.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                group {
                    let rules = state.allowRules.sorted { $0.displayLabel < $1.displayLabel }
                    ForEach(Array(rules.enumerated()), id: \.element.id) { idx, rule in
                        HStack {
                            Text(rule.displayLabel).lineLimit(1)
                            Spacer()
                            Button {
                                state.removeAllowRule(rule)
                            } label: { Image(systemName: "trash").foregroundStyle(.red) }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 8).padding(.horizontal, 14)
                        if idx < rules.count - 1 { divider }
                    }
                }
                Button("Remove all rules") { state.clearAllowlist() }
                    .padding(.top, 2)
            }
        }
    }

    private func permissionRow(_ title: String, granted: Bool, _ action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(granted ? "Granted" : "Not granted")
                .font(.caption)
                .foregroundStyle(granted ? .green : .secondary)
            if !granted {
                Button("Grant…", action: action)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 14)
    }

    private var session: some View {
        page("Session") {
            sectionLabel("Current session")
            group {
                actionRow("Send a message to Claude…", "paperplane") {
                    state.beginCompose()
                    window()?.close()
                }
                divider
                actionRow("Clear the active session", "xmark.circle") { state.clearSession() }
            }

            sectionLabel("Auto-approve for a while")
            Text("Turn on auto-approve for a set time, then it switches itself back off.")
                .font(.callout).foregroundStyle(.secondary)
            group {
                let windows = [15, 30, 60, 120]
                ForEach(Array(windows.enumerated()), id: \.element) { idx, m in
                    actionRow(windowLabel(m), "clock") { state.enableAutoApprove(forMinutes: m) }
                    if idx < windows.count - 1 { divider }
                }
            }
            if let until = state.autoApproveUntil {
                Text("Auto-approve on until \(until.formatted(date: .omitted, time: .shortened)).")
                    .font(.caption).foregroundStyle(.orange)
                Button("Turn off now") { state.setAutoApprove(false) }
            }

            sectionLabel("Snooze passive cards")
            group {
                let windows = [15, 30, 60]
                ForEach(Array(windows.enumerated()), id: \.element) { idx, m in
                    actionRow("Snooze for \(windowLabel(m))", "moon.zzz") { state.snooze(forMinutes: m) }
                    if idx < windows.count - 1 { divider }
                }
            }
            if let until = state.snoozedUntil {
                Text("Snoozed until \(until.formatted(date: .omitted, time: .shortened)).")
                    .font(.caption).foregroundStyle(.orange)
                Button("Cancel snooze") { state.cancelSnooze() }
            }

            if !state.recentProjects.isEmpty {
                sectionLabel("Recent projects")
                group {
                    let projects = Array(state.recentProjects.prefix(8))
                    ForEach(Array(projects.enumerated()), id: \.element) { idx, path in
                        actionRow((path as NSString).lastPathComponent, "folder") {
                            TerminalAutomator.startClaude(in: path, message: nil)
                        }
                        if idx < projects.count - 1 { divider }
                    }
                }
            }

            if !state.currentTouchedFiles.isEmpty {
                sectionLabel("Files touched this session")
                group {
                    let files = Array(state.currentTouchedFiles.prefix(10))
                    ForEach(Array(files.enumerated()), id: \.element) { idx, path in
                        actionRow((path as NSString).lastPathComponent, "doc") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                        if idx < files.count - 1 { divider }
                    }
                }
            }
        }
    }

    private func windowLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) hour\(minutes >= 120 ? "s" : "")"
    }

    private func window() -> NSWindow? {
        NSApp.windows.first { $0.title == "ClaudeNotch Settings" }
    }

    private var usage: some View {
        page("Usage") {
            Text("All-time counters, kept locally on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            group {
                statRow("Permissions allowed", "\(state.stats.allowed)")
                divider
                statRow("Permissions denied", "\(state.stats.denied)")
                divider
                statRow("Auto-approved", "\(state.stats.autoApproved)")
                divider
                statRow("Dangerous commands flagged", "\(state.stats.dangerousFlagged)")
                divider
                statRow("Questions answered", "\(state.stats.questionsAnswered)")
                divider
                statRow("Active days", "\(state.stats.activeDays.count)")
                divider
                statRow("Sessions recorded", "\(state.sessionHistory.count)")
            }
            if !state.stats.toolCounts.isEmpty {
                sectionLabel("Top tools")
                group {
                    let top = state.stats.toolCounts.sorted { $0.value > $1.value }.prefix(6)
                    ForEach(Array(top.enumerated()), id: \.element.key) { idx, kv in
                        statRow(kv.key, "\(kv.value)")
                        if idx < top.count - 1 { divider }
                    }
                }
            }
        }
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 8).padding(.horizontal, 14)
    }

    private var developer: some View {
        page("Developer") {
            Text("Fire a sample card to see what the notch looks like.")
                .font(.callout).foregroundStyle(.secondary)
            group {
                actionRow("Tool permission", "terminal") { demoPermission() }
                divider
                actionRow("Destructive command", "exclamationmark.triangle") { demoDangerous() }
                divider
                actionRow("Notification", "bell") { demoNotification() }
                divider
                actionRow("Task complete", "checkmark.seal") { demoCompleted() }
                divider
                actionRow("Thinking pulse", "brain") { state.pingThinking(label: "Editing AuthMiddleware.swift") }
                divider
                actionRow("Cost budget alert", "dollarsign.circle") { state.demoBudgetAlert() }
                divider
                actionRow("Budget hard-stop", "hand.raised") { state.demoBudgetBlock() }
            }
            group {
                actionRow("Play a pet animation", "pawprint") {
                    state.demoPet(PetActivity.allCases.filter { $0 != .tucked })
                }
            }
        }
    }

    private func demoPermission() {
        state.enqueuePermission(PermissionRequest(
            kind: .toolUse, title: "Run shell command", detail: "npm install",
            toolName: "Bash", source: "Demo", cwd: NSHomeDirectory(),
            dangerReasons: [], resolver: { _, _ in }), bypassRules: true)
    }
    private func demoDangerous() {
        let cmd = "rm -rf /tmp/cache && sudo chmod -R 777 /Library/LaunchAgents"
        let reasons = ToolPreviewParser.dangerReasons(for: "Bash", input: ["command": cmd])
        state.enqueuePermission(PermissionRequest(
            kind: .toolUse, title: "Run shell command", detail: cmd,
            toolName: "Bash", source: "Demo", cwd: NSHomeDirectory(),
            dangerReasons: reasons, resolver: { _, _ in }), bypassRules: true)
    }
    private func demoNotification() {
        state.enqueuePermission(PermissionRequest(
            kind: .notification, title: "Claude is waiting for your input",
            detail: "Open IDE to continue", toolName: "Notification",
            source: "Demo", cwd: "", resolver: { _, _ in }), bypassRules: true)
    }
    private func demoCompleted() {
        state.enqueueCompleted(CompletedTask(
            title: "Done — 14 files changed, tests green",
            detail: "Refactored auth middleware and re-ran the suite.",
            source: "Demo", cwd: NSHomeDirectory()))
    }

    private var about: some View {
        page("About") {
            HStack(spacing: 14) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ClaudeNotch").font(.title2.weight(.semibold))
                    Text("Claude Code, living in your notch.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Version \(Self.appVersion)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            group {
                aboutLink("Changelog", "https://rawsun007.github.io/claude-notch/changelog/")
                divider
                aboutLink("Source on GitHub", "https://github.com/rawsun007/claude-notch")
            }
            group {
                actionRow("Check for updates…", "arrow.down.circle") { UpdateChecker.shared.check(userInitiated: true) }
                if onOpenSetup != nil {
                    divider
                    actionRow("Run setup again…", "wand.and.stars") { onOpenSetup?() }
                }
            }
        }
    }

    // MARK: building blocks

    private func page<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.largeTitle.weight(.bold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    private var divider: some View {
        Divider().padding(.leading, 14)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }

    private func pickerRow<T: Hashable, Content: View>(_ title: String, selection: Binding<T>, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker("", selection: selection) { content() }
                .labelsHidden()
                .fixedSize()
        }
        .padding(.vertical, 8).padding(.horizontal, 14)
    }

    private func actionRow(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ title: String, _ subtitle: String?, _ isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }

    private func aboutLink(_ title: String, _ url: String) -> some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A Toggle binding that reads a published Bool and writes it through the
    /// matching persisting setter.
    private func bind(_ keyPath: KeyValuePath, _ setter: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { state[keyPath: keyPath] }, set: { setter($0) })
    }

    private typealias KeyValuePath = KeyPath<AppState, Bool>

    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
