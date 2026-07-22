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
        // A normal opaque title bar (not full-size content) so scrolled page
        // content stays below the bar instead of sliding up under the title.
        w.styleMask = [.titled, .closable, .resizable]
        w.titlebarAppearsTransparent = false
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

/// One searchable setting: what it's called, extra keywords, and the page it
/// lives on. Powers the sidebar search box.
private struct SettingsSearchItem: Identifiable {
    let title: String
    let keywords: String
    let section: SettingsSection
    var id: String { "\(section.rawValue)\u{0001}\(title)" }

    static let all: [SettingsSearchItem] = [
        .init(title: "Launch at login", keywords: "startup boot open", section: .general),
        .init(title: "Keep the notch open", keywords: "persistent always show display", section: .general),
        .init(title: "Auto-approve permissions", keywords: "allow automatic bypass", section: .general),
        .init(title: "Show spend in the menu bar", keywords: "cost money dollars", section: .general),
        .init(title: "Start Claude in a folder", keywords: "open launch project", section: .general),
        .init(title: "Check for updates", keywords: "version upgrade", section: .general),

        .init(title: "Notch title", keywords: "name label claude project custom", section: .notch),
        .init(title: "Status bar items", keywords: "5 hour weekly limit session cost", section: .notch),
        .init(title: "Context window size", keywords: "200k 1m auto tokens", section: .notch),

        .init(title: "Pet Mode", keywords: "mascot creature animation boop", section: .pet),

        .init(title: "Send a message to Claude", keywords: "compose prompt", section: .session),
        .init(title: "Clear the active session", keywords: "reset", section: .session),
        .init(title: "Auto-approve for a while", keywords: "timed window minutes", section: .session),
        .init(title: "Snooze passive cards", keywords: "mute pause quiet", section: .session),
        .init(title: "Recent projects", keywords: "folders open", section: .session),
        .init(title: "Files touched", keywords: "edited reveal finder", section: .session),

        .init(title: "Plan-limit warnings", keywords: "rate limit 80 95 percent", section: .alerts),
        .init(title: "Long-run alerts", keywords: "stuck slow", section: .alerts),
        .init(title: "Break reminders", keywords: "rest stretch", section: .alerts),
        .init(title: "Completion notifications", keywords: "done finished banner", section: .alerts),
        .init(title: "Daily digest", keywords: "summary morning spend", section: .alerts),
        .init(title: "Mirror to Notification Center", keywords: "banner macos", section: .alerts),

        .init(title: "Mute all sounds", keywords: "silence quiet", section: .sounds),
        .init(title: "Per-tool sounds", keywords: "pop up chime bash edit", section: .sounds),
        .init(title: "Alert sound", keywords: "chime funk pop tink", section: .sounds),

        .init(title: "Cost caps", keywords: "budget session day week dollars limit", section: .budget),
        .init(title: "Hard-stop at the cap", keywords: "block enforce", section: .budget),

        .init(title: "Hide from screen capture", keywords: "recording screenshot privacy", section: .privacy),
        .init(title: "Require Touch ID", keywords: "biometric fingerprint", section: .privacy),
        .init(title: "Accessibility permission", keywords: "system", section: .privacy),
        .init(title: "Input Monitoring permission", keywords: "system keys", section: .privacy),
        .init(title: "Always-allow rules", keywords: "allowlist regex", section: .privacy),

        .init(title: "Activity heatmap", keywords: "usage graph history", section: .usage),
        .init(title: "Token usage and cost", keywords: "spend dollars", section: .usage),

        .init(title: "Sample cards", keywords: "demo test", section: .developer),
        .init(title: "Pet animations", keywords: "demo peek stroll", section: .developer),

        .init(title: "Version and links", keywords: "about changelog github setup", section: .about),
    ]
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    var onOpenSetup: (() -> Void)? = nil
    @State private var section: SettingsSection = .general
    @State private var claudeUsage: ClaudeUsageReader.Usage?
    @State private var heatTip: String?
    @State private var search = ""
    @State private var healthTick = 0
    // Past Claude Code sessions grouped by project (read off disk), and which
    // project rows the user has expanded to reveal their resumable sessions.
    @State private var projectSessions: [(cwd: String, project: String, sessions: [ResumableSession])] = []
    @State private var expandedProjects: Set<String> = []
    @State private var sessionSearch = ""
    @State private var copiedSessionId: String?
    // Lazily-loaded last-assistant-reply previews, keyed by session id.
    @State private var sessionPreviews: [String: String] = [:]
    // Session the user tapped delete on, awaiting confirmation.
    @State private var pendingDelete: ResumableSession?
    // Inline session-rename editor state.
    @State private var editingNoteId: String?
    @State private var editingNoteText = ""
    @State private var updateCmdCopied = false
    @State private var devSampleCardsOpen = false
    @State private var devPetDemosOpen = false

    private var searchResults: [SettingsSearchItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return SettingsSearchItem.all.filter {
            $0.title.lowercased().contains(q)
                || $0.keywords.lowercased().contains(q)
                || $0.section.rawValue.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                    TextField("Search settings", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)

                if search.isEmpty {
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
                } else if searchResults.isEmpty {
                    VStack { Spacer(); Text("No matches").foregroundStyle(.secondary).font(.callout); Spacer() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(searchResults) { item in
                        Button {
                            section = item.section
                            search = ""
                        } label: {
                            HStack {
                                Image(systemName: item.section.symbol)
                                    .foregroundStyle(.secondary).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                    Text(item.section.rawValue).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationSplitViewColumnWidth(200)
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
        // Reading healthTick makes this page re-render after a Fix.
        let _ = healthTick
        let hooksOK = HookInstaller.isInstalled
        let statusLineOK = HookInstaller.statusLineWired
        return page("General") {
            if let v = state.availableUpdateVersion {
                updateBanner(version: v)
            }
            sectionLabel("Setup")
            group {
                healthRow("Claude Code hooks", ok: hooksOK,
                          "Lets the notch receive Claude's permission prompts and events.")
                divider
                healthRow("Status-line forwarder", ok: statusLineOK,
                          "Feeds live cost, context, and plan-limit numbers to the notch.")
            }
            if !hooksOK || !statusLineOK {
                Button {
                    try? HookInstaller.install()
                    healthTick += 1
                } label: {
                    Label("Fix setup", systemImage: "wrench.and.screwdriver")
                }
                .padding(.top, 2)
            }

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

            sectionLabel("Integrations (beta)")
            Text("Surface other coding agents in the notch. Codex support is experimental: session status, prompts, activity and notifications appear, but permission cards and cost are not wired yet.")
                .font(.callout).foregroundStyle(.secondary)
            group {
                let _ = healthTick   // re-read install state after a toggle
                if HookInstaller.isCodexInstalled {
                    healthRow("Codex (beta)", ok: true, "Codex hooks are installed. Approve the one-time trust prompt when Codex next starts.")
                    divider
                    actionRow("Start Codex in a folder…", "play.circle") { startCodexPicker() }
                    divider
                    actionRow("Disable Codex integration", "minus.circle") {
                        HookInstaller.uninstallCodexHooks(); healthTick += 1
                    }
                } else {
                    actionRow("Enable Codex integration (beta)", "sparkles") {
                        try? HookInstaller.installCodexHooks(); healthTick += 1
                    }
                }
            }
            if HookInstaller.isCodexInstalled {
                group {
                    row("Dropping a folder starts Codex",
                        "When you drag a folder onto the notch, start Codex instead of Claude.",
                        Binding(get: { state.dropStartsCodex }, set: { state.setDropStartsCodex($0) }))
                }
            }
        }
    }

    /// In-app update banner shown at the top of General when a newer release
    /// is found: the version, a one-click Download, and a copyable Homebrew
    /// upgrade command for cask users.
    private func updateBanner(version: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.white)
                Text("Update available: v\(version)")
                    .font(.headline).foregroundStyle(.white)
                Spacer()
                Text("You have v\(UpdateChecker.shared.currentVersion)")
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 8) {
                Button {
                    if let url = URL(string: "https://github.com/rawsun007/claude-notch/releases/latest/download/ClaudeNotch.dmg") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Download", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Release notes") {
                    if let url = URL(string: "https://rawsun007.github.io/claude-notch/changelog/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                Spacer()
            }
            HStack(spacing: 8) {
                Text("Homebrew:").font(.caption).foregroundStyle(.white.opacity(0.8))
                Text("brew upgrade --cask claudenotch")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew upgrade --cask claudenotch", forType: .string)
                    updateCmdCopied = true
                } label: {
                    Image(systemName: updateCmdCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor)
        )
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

    private func startCodexPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start Codex"
        if panel.runModal() == .OK, let url = panel.url {
            TerminalAutomator.startCodex(in: url.path)
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
                            set: { state.setCustomTitleText($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 180)
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
                row("Daily and weekly digest",
                    "A once-a-day summary of what Claude did, plus a weekly roundup of sessions and estimated cost.",
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

            if state.perToolSounds {
                sectionLabel("Sound per pop-up type")
                Text("With per-tool sounds on, each kind of pop-up plays its own sound. Change any of them; the default is shown when you have not.")
                    .font(.callout).foregroundStyle(.secondary)
                group {
                    let cats = ToolSoundCategory.allCases
                    ForEach(Array(cats.enumerated()), id: \.element) { idx, cat in
                        soundPickerRow(cat.label, cat.detail,
                                       get: { state.toolSound(cat) },
                                       set: { state.setToolSound(cat, $0) })
                        if idx < cats.count - 1 { divider }
                    }
                }
                .disabled(state.soundMuted)
                .opacity(state.soundMuted ? 0.5 : 1)
            } else {
                sectionLabel("Alert sound")
                group {
                    soundPickerRow("Alert sound", nil,
                                   get: { state.alertSound },
                                   set: { state.setAlertSound($0) })
                }
                .disabled(state.soundMuted)
                .opacity(state.soundMuted ? 0.5 : 1)
            }
        }
    }

    private func soundPickerRow(_ title: String, _ subtitle: String?, get: @escaping () -> String, set: @escaping (String) -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Picker("", selection: Binding(
                get: get,
                set: { set($0); NSSound(named: NSSound.Name($0))?.play() }
            )) {
                ForEach(AppState.availableSounds, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize().controlSize(.small)
            Button { NSSound(named: NSSound.Name(get()))?.play() } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8).padding(.horizontal, 14)
    }

    private var budget: some View {
        page("Budget") {
            if state.fiveHourLimitPercent >= 0 || state.weeklyLimitPercent >= 0 {
                sectionLabel("Plan usage limits")
                Text("Your Claude plan's rate limits, as Claude Code last reported them. These are usage limits, not dollar caps.")
                    .font(.callout).foregroundStyle(.secondary)
                group {
                    if state.fiveHourLimitPercent >= 0 {
                        limitRow("5-hour limit", pct: state.fiveHourLimitPercent,
                                 resetAt: state.fiveHourResetAt, window: 5 * 3600)
                    }
                    if state.fiveHourLimitPercent >= 0, state.weeklyLimitPercent >= 0 { divider }
                    if state.weeklyLimitPercent >= 0 {
                        limitRow("Weekly limit", pct: state.weeklyLimitPercent,
                                 resetAt: state.weeklyResetAt, window: 7 * 24 * 3600)
                    }
                }
                if let updated = state.limitsUpdatedAt {
                    Text("Updated \(updated.formatted(.relative(presentation: .named))).")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

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

    /// A plan-usage limit as a labelled progress bar plus a reset countdown and
    /// a burn-rate forecast. `pct` is 0...1; the bar tints amber past 75% and
    /// red past 90%. `window` is the limit's period (5h or 7d) used to estimate
    /// how fast usage is climbing.
    private func limitRow(_ title: String, pct: Double, resetAt: Date?, window: TimeInterval) -> some View {
        let clamped = min(1, max(0, pct))
        let tint: Color = clamped >= 0.9 ? .red : (clamped >= 0.75 ? .orange : .accentColor)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((clamped * 100).rounded()))%")
                    .font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(tint).frame(width: max(3, geo.size.width * clamped))
                }
            }
            .frame(height: 6)
            if let forecast = limitForecast(pct: clamped, resetAt: resetAt, window: window) {
                Text(forecast)
                    .font(.caption)
                    .foregroundStyle(clamped >= 0.75 ? tint : .secondary)
            }
            if let resetAt {
                Text("Resets \(resetAt.formatted(.relative(presentation: .named))).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
    }

    /// Estimate, from the current percent and how far into the window we are,
    /// whether usage is on track to hit the limit before it resets. Assumes a
    /// steady rate since the window opened. Returns nil when there isn't enough
    /// to project (no reset time, window not started, or already at 0/100%).
    private func limitForecast(pct: Double, resetAt: Date?, window: TimeInterval) -> String? {
        guard let resetAt, pct > 0.01, pct < 1 else { return nil }
        let remainingWindow = resetAt.timeIntervalSinceNow
        guard remainingWindow > 0 else { return nil }
        let elapsed = window - remainingWindow
        guard elapsed > 60 else { return nil }           // too early to project
        let rate = pct / elapsed                          // fraction per second
        let secondsToLimit = (1 - pct) / rate
        if secondsToLimit >= remainingWindow {
            return "At this pace you stay under the limit this window."
        }
        return "At this pace you hit the limit in about \(shortDuration(secondsToLimit))."
    }

    /// Compact human duration: "45m", "2h", "1d 3h".
    private func shortDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 3600 { return "\(max(1, s / 60))m" }
        if s < 24 * 3600 {
            let h = s / 3600, m = (s % 3600) / 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        let d = s / (24 * 3600), h = (s % (24 * 3600)) / 3600
        return h > 0 ? "\(d)d \(h)h" : "\(d)d"
    }

    private func capRow(_ title: String, get: @escaping () -> Double, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("$").foregroundStyle(.secondary)
            TextField("0", value: Binding(get: get, set: set), format: .number)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 64)
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

    private func healthRow(_ title: String, ok: Bool, _ subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(ok ? "Connected" : "Not set up")
                .font(.caption).foregroundStyle(ok ? .green : .orange)
        }
        .padding(.vertical, 8).padding(.horizontal, 14)
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
            Text("Turn on auto-approve for a set time, then it switches itself back off — or keep it on until you turn it off.")
                .font(.callout).foregroundStyle(.secondary)
            group {
                actionRow("Keep on until I turn it off", "infinity") { state.setAutoApprove(true) }
                divider
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
            } else if state.autoApprove {
                Text("Auto-approve is on until you turn it off.")
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

            sectionLabel("Projects & recent sessions")
            Text("Closed a terminal by accident? Expand a project and resume right where you left off.")
                .font(.callout).foregroundStyle(.secondary)
            if projectSessions.isEmpty {
                group {
                    HStack {
                        Text("No past sessions found yet.")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 10).padding(.horizontal, 14)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary).font(.callout)
                    TextField("Filter by project or prompt…", text: $sessionSearch)
                        .textFieldStyle(.plain)
                    if !sessionSearch.isEmpty {
                        Button { sessionSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 7).padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

                let matches = filteredProjectSessions
                if matches.isEmpty {
                    group {
                        HStack {
                            Text("No sessions match “\(sessionSearch)”.")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 10).padding(.horizontal, 14)
                    }
                } else {
                    group {
                        ForEach(Array(matches.enumerated()), id: \.element.cwd) { idx, proj in
                            projectRow(proj, forceOpen: !sessionSearch.isEmpty)
                            if idx < matches.count - 1 { divider }
                        }
                    }
                }
            }

            let diff = state.currentDiffStat
            if diff.added > 0 || diff.removed > 0 {
                sectionLabel("Lines changed this session")
                group {
                    HStack(spacing: 12) {
                        Text("+\(diff.added)")
                            .font(.body.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.green)
                        Text("-\(diff.removed)")
                            .font(.body.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.red)
                        Spacer()
                        Text("net \(diff.added - diff.removed >= 0 ? "+" : "")\(diff.added - diff.removed)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10).padding(.horizontal, 14)
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
                Button("Reveal all in Finder") {
                    let urls = state.currentTouchedFiles.map { URL(fileURLWithPath: $0) }
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
                .padding(.top, 2)
            }
        }
        .task(id: section) {
            guard section == .session else { return }
            let loaded = await Task.detached(priority: .utility) {
                SessionResumer.allAgentSessionsByProject()
            }.value
            projectSessions = loaded
        }
        .confirmationDialog(
            "Move this session to the Trash?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { s in
            Button("Move to Trash", role: .destructive) { deleteSession(s) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { s in
            Text("“\(s.title)” goes to the Trash. You can restore it from there; Claude Code won't be able to resume it while it's trashed.")
        }
    }

    /// Trash a session transcript and drop it from the in-memory list.
    private func deleteSession(_ s: ResumableSession) {
        SessionResumer.trash(s.fileURL)
        for i in projectSessions.indices {
            projectSessions[i].sessions.removeAll { $0.id == s.id }
        }
        projectSessions.removeAll { $0.sessions.isEmpty }
        sessionPreviews[s.id] = nil
        pendingDelete = nil
    }

    /// Projects filtered by the search box. Empty search returns the first 10
    /// projects untouched; otherwise every project whose name matches, plus
    /// projects with a matching session (narrowed to just the matches).
    private var filteredProjectSessions: [(cwd: String, project: String, sessions: [ResumableSession])] {
        let q = sessionSearch.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [(cwd: String, project: String, sessions: [ResumableSession])]
        if q.isEmpty {
            out = projectSessions
        } else {
            out = []
            for proj in projectSessions {
                if proj.project.lowercased().contains(q) {
                    out.append(proj)
                } else {
                    let hits = proj.sessions.filter { $0.title.lowercased().contains(q) }
                    if !hits.isEmpty { out.append((proj.cwd, proj.project, hits)) }
                }
            }
        }
        // Pinned projects float to the top, keeping their relative order.
        let pinned = out.filter { state.pinnedProjects.contains($0.cwd) }
        let rest = out.filter { !state.pinnedProjects.contains($0.cwd) }
        return Array((pinned + rest).prefix(q.isEmpty ? 10 : out.count))
    }

    /// One project row in the Session page: a folder header that toggles open to
    /// reveal that project's resumable sessions, each with a Resume button.
    /// `forceOpen` keeps a row expanded during an active search regardless of
    /// the manual toggle state.
    @ViewBuilder
    private func projectRow(_ proj: (cwd: String, project: String, sessions: [ResumableSession]), forceOpen: Bool = false) -> some View {
        let isOpen = forceOpen || expandedProjects.contains(proj.cwd)
        Button {
            if isOpen { expandedProjects.remove(proj.cwd) }
            else { expandedProjects.insert(proj.cwd) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder").frame(width: 18)
                Text(proj.project)
                Text("\(proj.sessions.count)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer()
                let pinned = state.pinnedProjects.contains(proj.cwd)
                Button {
                    state.togglePinnedProject(proj.cwd)
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.caption)
                        .foregroundStyle(pinned ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(pinned ? "Unpin project" : "Pin project to top")
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isOpen {
            let shown = Array(proj.sessions.prefix(8))
            ForEach(Array(shown.enumerated()), id: \.element.id) { idx, s in
                // Insert a day-bucket header when the bucket changes, so a long
                // list reads as Today / Yesterday / Earlier this week / Older.
                let bucket = SessionResumer.dayBucket(s.lastActive)
                let prevBucket = idx > 0 ? SessionResumer.dayBucket(shown[idx - 1].lastActive) : nil
                if bucket != prevBucket {
                    Text(bucket)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6).padding(.bottom, 2)
                        .padding(.leading, 24)
                }
                sessionRow(s)
            }
        }
    }

    /// A single resumable session under a project: title + when + Resume.
    private func sessionRow(_ s: ResumableSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                let note = state.sessionNotes[s.id]
                if editingNoteId == s.id {
                    TextField("Name this session", text: $editingNoteText)
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                        .onSubmit { commitNote(for: s.id) }
                } else {
                    HStack(spacing: 6) {
                        if AgentKind.infer(fromModel: s.model) == .codex {
                            Text("CODEX")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.teal)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(Color.teal.opacity(0.15)))
                        }
                        Text(note?.isEmpty == false ? note! : s.title)
                            .lineLimit(1)
                            .fontWeight(note?.isEmpty == false ? .semibold : .regular)
                        if state.sessions[s.id] != nil {
                            HStack(spacing: 3) {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                                Text("running").font(.caption2)
                            }
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.12)))
                        }
                    }
                    // When a note is set, keep the original first prompt visible
                    // underneath so the session is still identifiable.
                    if note?.isEmpty == false {
                        Text(s.title).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                if let preview = sessionPreviews[s.id], !preview.isEmpty {
                    Text(preview)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(s.relativeLastActive)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Two controls only: the primary Resume, and a compact menu that
            // holds the secondary actions so the row doesn't sprout loose icons.
            if editingNoteId == s.id {
                Button("Done") { commitNote(for: s.id) }
                    .controlSize(.small)
            } else {
                let isCodex = AgentKind.infer(fromModel: s.model) == .codex
                Button("Resume") {
                    if isCodex { TerminalAutomator.resumeCodex(sessionId: s.id, in: s.cwd) }
                    else { TerminalAutomator.resumeClaude(sessionId: s.id, in: s.cwd) }
                    window()?.close()
                }
                .controlSize(.small)
                Menu {
                    Button {
                        editingNoteId = s.id
                        editingNoteText = state.sessionNotes[s.id] ?? ""
                    } label: { Label("Rename session", systemImage: "pencil") }
                    Button {
                        let cmd = isCodex ? "codex resume \(s.id)" : "claude --resume \(s.id)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cmd, forType: .string)
                        copiedSessionId = s.id
                    } label: { Label("Copy resume command", systemImage: "doc.on.doc") }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([s.fileURL])
                    } label: { Label("Reveal transcript in Finder", systemImage: "folder") }
                    Divider()
                    Button(role: .destructive) {
                        pendingDelete = s
                    } label: { Label("Move to Trash", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, 24).padding(.trailing, 14)
        .background(Color.primary.opacity(0.03))
        .task(id: s.id) {
            guard sessionPreviews[s.id] == nil else { return }
            let url = s.fileURL
            let reply = await Task.detached(priority: .utility) {
                SessionResumer.lastReply(from: url)
            }.value
            sessionPreviews[s.id] = reply ?? ""
        }
    }

    /// Save the inline-edited name for a session and close the editor.
    private func commitNote(for id: String) {
        state.setSessionNote(id: id, editingNoteText)
        editingNoteId = nil
        editingNoteText = ""
    }

    private func windowLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) hour\(minutes >= 120 ? "s" : "")"
    }

    private func window() -> NSWindow? {
        NSApp.windows.first { $0.title == "ClaudeNotch Settings" }
    }

    private var usage: some View {
        page("Usage") {
            let churn = state.churnToday
            if churn.added > 0 || churn.removed > 0 {
                sectionLabel("Code churn today")
                HStack(spacing: 12) {
                    churnStat("Lines added", "+\(churn.added)", .green)
                    churnStat("Lines removed", "-\(churn.removed)", .red)
                    churnStat("Net", "\(churn.added - churn.removed >= 0 ? "+" : "")\(churn.added - churn.removed)", .primary)
                }
            }

            if let u = claudeUsage {
                let trend = spendTrendData(u)
                if trend.contains(where: { $0.cost > 0 }) {
                    sectionLabel("Estimated cost, last 7 days")
                    Text("Estimated at public API (pay-as-you-go) prices. On a Pro, Max, Team, or Enterprise subscription you pay a flat fee, so this is not your actual bill, it is what the usage would cost per token.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    spendTrend(trend)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                }
                let weekly = ClaudeUsageReader.weeklyCostBuckets(daily: u.dailyCostUSD, weeks: 4, asOf: Date())
                if weekly.contains(where: { $0.cost > 0 }) {
                    sectionLabel("Estimated cost, last 4 weeks")
                    spendTrend(weekly)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                }
            }

            sectionLabel("Activity, last 7 weeks")
            activityHeatmap
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

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

            let spendLeaders = state.weekCostByProject
                .filter { $0.value > 0 && AppState.isRealProject($0.key) }
                .sorted { $0.value > $1.value }
                .prefix(6)
            if !spendLeaders.isEmpty {
                sectionLabel("Top projects by estimated cost (7 days)")
                let maxSpend = spendLeaders.first?.value ?? 1
                group {
                    ForEach(Array(spendLeaders.enumerated()), id: \.element.key) { idx, kv in
                        spendLeaderRow(project: (kv.key as NSString).lastPathComponent,
                                       cost: kv.value, fraction: maxSpend > 0 ? kv.value / maxSpend : 0)
                        if idx < spendLeaders.count - 1 { divider }
                    }
                }
            }

            sectionLabel("Claude usage (from transcripts)")
            Text("Costs are estimates at public API prices, not your subscription bill.")
                .font(.caption).foregroundStyle(.secondary)
            if let u = claudeUsage {
                group {
                    statRow("Today", "\(formatTokens(u.today.total)) tok · \(usd(u.today.costUSD))")
                    divider
                    statRow("Last 5 hours", "\(formatTokens(u.fiveHour.total)) tok · \(usd(u.fiveHour.costUSD))")
                    divider
                    statRow("This week", "\(formatTokens(u.week.total)) tok · \(usd(u.week.costUSD))")
                    divider
                    statRow("Sessions this week", "\(u.sessionsWeek)")
                    divider
                    statRow("Cache hit rate", "\(Int(u.cacheHitRate * 100))%")
                    divider
                    statRow("Cache savings", usd(u.cacheSavingsUSD))
                }

                let models = u.weekByModel
                    .filter { $0.value.costUSD > 0 }
                    .sorted { $0.value.costUSD > $1.value.costUSD }
                if !models.isEmpty {
                    sectionLabel("Model mix (last 7 days)")
                    let maxCost = models.first?.value.costUSD ?? 1
                    group {
                        ForEach(Array(models.enumerated()), id: \.element.key) { idx, kv in
                            spendLeaderRow(project: kv.key, cost: kv.value.costUSD,
                                           fraction: maxCost > 0 ? kv.value.costUSD / maxCost : 0)
                            if idx < models.count - 1 { divider }
                        }
                    }
                }

                Button {
                    state.exportSessionHistory()
                } label: {
                    Label("Export session history (CSV)", systemImage: "square.and.arrow.up")
                }
                .padding(.top, 2)
            } else {
                Text("Reading transcripts…").font(.callout).foregroundStyle(.secondary)
            }
        }
        .task(id: section) {
            guard section == .usage else { return }
            let usage = await Task.detached(priority: .utility) { ClaudeUsageReader.compute() }.value
            claudeUsage = usage
        }
    }

    /// Last 7 days of spend as (weekday label, cost), oldest to newest.
    private func spendTrendData(_ u: ClaudeUsageReader.Usage) -> [(label: String, cost: Double)] {
        let cal = Calendar.current
        let key = DateFormatter(); key.locale = Locale(identifier: "en_US_POSIX"); key.dateFormat = "yyyy-MM-dd"
        let lab = DateFormatter(); lab.locale = Locale(identifier: "en_US_POSIX"); lab.dateFormat = "EEE"
        let today = cal.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { i -> (String, Double)? in
            guard let d = cal.date(byAdding: .day, value: -i, to: today) else { return nil }
            return (lab.string(from: d), u.dailyCostUSD[key.string(from: d)] ?? 0)
        }
    }

    /// A row of vertical bars, one per day, scaled to the priciest day.
    private func spendTrend(_ data: [(label: String, cost: Double)]) -> some View {
        let maxCost = max(data.map(\.cost).max() ?? 0, 0.0001)
        return HStack(alignment: .bottom, spacing: 10) {
            ForEach(Array(data.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 4) {
                    Text(day.cost >= 0.005 ? usd(day.cost) : "")
                        .font(.system(size: 9, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(height: max(2, CGFloat(day.cost / maxCost) * 90))
                    Text(day.label).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
    private func usd(_ v: Double) -> String { String(format: "$%.2f", v) }

    private static let weekdayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private var activityHeatmap: some View {
        let cal = Calendar.current
        let weeks = 7
        let today = Date()
        // 0 = Sunday ... 6 = Saturday, matching the calendar grid rows.
        let todayWeekday = cal.component(.weekday, from: today) - 1

        // level(row, col): row = weekday (0..6), col = week (0..weeks-1, newest
        // on the right). -1 marks a future cell (after today), drawn empty.
        func cell(row: Int, col: Int) -> (level: Int, tip: String) {
            let daysBack = (todayWeekday - row) + (weeks - 1 - col) * 7
            guard daysBack >= 0, let day = cal.date(byAdding: .day, value: -daysBack, to: today) else {
                return (-1, "")
            }
            let n = state.stats.dailyCounts[AppState.dayKey(day)]?.tools ?? 0
            let level: Int
            switch n {
            case 0: level = 0
            case 1...5: level = 1
            case 6...15: level = 2
            case 16...30: level = 3
            default: level = 4
            }
            let date = day.formatted(.dateTime.month(.abbreviated).day().year())
            let tip = "\(date): \(n) tool call\(n == 1 ? "" : "s")"
            return (level, tip)
        }

        let cellSize: CGFloat = 16
        let gap: CGFloat = 4
        let labelWidth: CGFloat = 32
        return VStack(alignment: .leading, spacing: 10) {
            // Live readout: shows the hovered day, or a hint.
            Text(heatTip ?? "Hover a day to see its activity")
                .font(.caption)
                .foregroundStyle(heatTip == nil ? .secondary : .primary)
                .padding(.leading, labelWidth + gap)

            HStack(alignment: .top, spacing: gap) {
                // Weekday labels down the left, each occupying one cell pitch so
                // they line up with the rows.
                VStack(alignment: .trailing, spacing: gap) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(row % 2 == 1 ? Self.weekdayLabels[row] : "")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(height: cellSize, alignment: .center)
                    }
                }
                .frame(width: labelWidth, alignment: .trailing)

                ForEach(0..<weeks, id: \.self) { col in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { row in
                            let c = cell(row: row, col: col)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(c.level < 0 ? Color.clear : heatColor(c.level))
                                .frame(width: cellSize, height: cellSize)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    if inside, !c.tip.isEmpty { heatTip = c.tip }
                                    else if heatTip == c.tip { heatTip = nil }
                                }
                        }
                    }
                }
            }
            HStack(spacing: 5) {
                Text("Less").font(.caption2).foregroundStyle(.secondary)
                ForEach(0..<5, id: \.self) { l in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(heatColor(l)).frame(width: 11, height: 11)
                }
                Text("More").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.leading, labelWidth + gap)
        }
    }

    private func heatColor(_ level: Int) -> Color {
        switch level {
        case 0:  return Color.green.opacity(0.10)
        case 1:  return Color.green.opacity(0.30)
        case 2:  return Color.green.opacity(0.50)
        case 3:  return Color.green.opacity(0.72)
        default: return Color.green.opacity(0.95)
        }
    }

    /// A ranked project-spend row: name, a proportional bar, and the dollar
    /// amount. `fraction` is this project's spend over the top project's.
    private func spendLeaderRow(project: String, cost: Double, fraction: Double) -> some View {
        HStack(spacing: 10) {
            Text(project).lineLimit(1).frame(width: 130, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Color.accentColor.opacity(0.7))
                        .frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 6)
            Text(usd(cost)).font(.callout.weight(.semibold).monospacedDigit())
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 9).padding(.horizontal, 14)
    }

    /// A single big-number tile for the code-churn row.
    private func churnStat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
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
            DisclosureGroup(isExpanded: $devSampleCardsOpen) {
                group {
                    actionRow("Tool permission", "terminal") { demoPermission() }
                    divider
                    actionRow("Destructive command", "exclamationmark.triangle") { demoDangerous() }
                    divider
                    actionRow("Edit with diff preview", "doc.text.magnifyingglass") { demoDiff() }
                    divider
                    actionRow("Auto-approve (live activity)", "bolt.badge.a") { demoAutoApprove() }
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
                .padding(.top, 6)
            } label: {
                Text("Sample cards").font(.callout.weight(.semibold))
            }

            DisclosureGroup(isExpanded: $devPetDemosOpen) {
                group {
                    let demoable = PetActivity.allCases.filter { $0 != .tucked }
                    actionRow("Play all", "play.circle") { state.demoPet(demoable) }
                    divider
                    ForEach(Array(demoable.enumerated()), id: \.element) { idx, activity in
                        actionRow(Self.petDemoTitle(activity), "pawprint") { state.demoPet([activity]) }
                        if idx < demoable.count - 1 { divider }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Pet animations").font(.callout.weight(.semibold))
            }
        }
    }

    private static func petDemoTitle(_ activity: PetActivity) -> String {
        switch activity {
        case .tucked:     return "Tucked"
        case .peek:       return "Peek"
        case .lookAround: return "Look around"
        case .hangLeft:   return "Hang off left corner"
        case .hangRight:  return "Hang off right corner"
        case .stroll:     return "Stroll"
        case .sleep:      return "Sleep"
        case .celebrate:  return "Celebrate"
        case .boop:       return "Boop"
        case .spin:       return "Backflip"
        case .rope:       return "Dangle on a rope"
        case .watch:      return "Watch Claude work"
        case .flinch:     return "Flinch (something broke)"
        case .spiderHang: return "Spider-Pet (hang upside-down)"
        case .fret:       return "Fret (limit almost up)"
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
    private func demoDiff() {
        let preview = ToolPreviewParser.preview(for: "Edit", input: [
            "file_path": "/Users/example/main.swift",
            "old_string": "let x = 42\nprint(\"hello\")\nreturn x",
            "new_string": "let x = 100\nprint(\"hello, world\")\nreturn x * 2"])
        state.enqueuePermission(PermissionRequest(
            kind: .toolUse, title: "Edit file", detail: "/Users/example/main.swift",
            toolName: "Edit", source: "Demo", cwd: "/Users/example",
            preview: preview, resolver: { _, _ in }), bypassRules: true)
    }
    private func demoAutoApprove() {
        let preview = ToolPreviewParser.preview(for: "Edit", input: [
            "file_path": "/Users/example/config.swift",
            "old_string": "timeout = 30", "new_string": "timeout = 60"])
        state.demoAutoApprove(PermissionRequest(
            kind: .toolUse, title: "Edit file", detail: "/Users/example/config.swift",
            toolName: "Edit", source: "Demo", cwd: "/Users/example",
            preview: preview, resolver: { _, _ in }))
    }

    private var about: some View {
        page("About") {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
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
            if !Self.whatsNew.isEmpty {
                sectionLabel("What's new in v\(Self.appVersion)")
                group {
                    ForEach(Array(Self.whatsNew.enumerated()), id: \.offset) { idx, line in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "sparkle").font(.caption).foregroundStyle(Color.accentColor)
                                .padding(.top, 2)
                            Text(line).font(.callout)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8).padding(.horizontal, 14)
                        if idx < Self.whatsNew.count - 1 { divider }
                    }
                }
            }
            group {
                aboutLink("Full changelog", "https://rawsun007.github.io/claude-notch/changelog/")
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
                .controlSize(.small)
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
                .controlSize(.small)
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

    /// Highlights for the current release, shown on the About page. Keep this in
    /// sync with the top changelog entry when cutting a release.
    static let whatsNew: [String] = [
        "Each session row now shows which CLI it is (a CODEX / GROK tag), so a mixed list is clear.",
        "The notch header names the agent from the running sessions: Codex-only reads Codex, a mix reads the app name instead of a wrong single agent.",
        "Name the notch during setup, not just in Settings.",
    ]
}
