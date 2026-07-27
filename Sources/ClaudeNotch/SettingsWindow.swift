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

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case notch = "Notch"
    case pet = "Pet"
    case session = "Session"
    case alerts = "Alerts"
    case sounds = "Sounds"
    case budget = "Budget"
    case privacy = "Privacy"
    case usage = "Usage"
    case history = "History"
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
        case .history: return "clock.arrow.circlepath"
        case .developer: return "hammer"
        case .about: return "info.circle"
        }
    }

    /// Grouped sidebar layout for easy navigation.
    static let nav: [(title: String, items: [SettingsSection])] = [
        ("Workspace", [.general, .notch, .pet]),
        ("Session", [.session]),
        ("Alerts & Cost", [.alerts, .sounds, .budget]),
        ("Info", [.usage, .history, .privacy, .about]),
        ("Advanced", [.developer]),
    ]

    /// Extraction anchors for the sidebar.
    ///
    /// The sidebar looks these up through a variable, `L(s.rawValue)`, which
    /// tools/l10n-extract.py cannot see: it reads literal call sites. Without
    /// this the keys would be missing from the table and every sidebar entry
    /// would silently stay English in every language. Never called.
    static let localizedSidebarKeys: [String] = [
        L("General", comment: "Settings sidebar section"),
        L("Notch", comment: "Settings sidebar section"),
        L("Pet", comment: "Settings sidebar section"),
        L("Session", comment: "Settings sidebar section"),
        L("Alerts", comment: "Settings sidebar section"),
        L("Sounds", comment: "Settings sidebar section"),
        L("Budget", comment: "Settings sidebar section"),
        L("Privacy", comment: "Settings sidebar section"),
        L("Usage", comment: "Settings sidebar section"),
        L("History", comment: "Settings sidebar section"),
        L("Developer", comment: "Settings sidebar section"),
        L("About", comment: "Settings sidebar section"),
        L("Workspace", comment: "Settings sidebar group"),
        L("Alerts & Cost", comment: "Settings sidebar group"),
        L("Info", comment: "Settings sidebar group"),
        L("Advanced", comment: "Settings sidebar group"),
    ]
}

/// The rounded search box used on the list pages (sessions, history). One
/// component so the three-way icon + field + clear-button layout and its
/// chrome don't get re-typed (and drift) at every call site.
private struct SearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary).font(.callout)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
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
    }
}

/// The card look shared by every boxed section on the settings pages: a filled
/// rounded rectangle with a hairline border. One modifier so the fill + stroke
/// pair isn't re-typed (and re-tuned) at each call site.
private struct CardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
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

extension View {
    func cardChrome() -> some View { modifier(CardChrome()) }
}

/// A small tag marking a non-Claude session in the settings lists. Claude is
/// the default and stays untagged; other agents (Codex, Grok) get one
/// consistent capsule instead of each list styling its own.
private struct AgentChip: View {
    let model: String
    var body: some View {
        let kind = AgentKind.infer(fromModel: model)
        if kind != .claude {
            Text(kind.rawValue.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.teal)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Capsule().fill(Color.teal.opacity(0.15)))
        }
    }
}

/// One searchable setting: what it's called, extra keywords, and the page it
/// lives on. Powers the sidebar search box.
struct SettingsSearchItem: Identifiable {
    let title: String
    let keywords: String
    let section: SettingsSection
    var id: String { "\(section.rawValue)\u{0001}\(title)" }

    /// Tokenized AND search: every whitespace/hyphen-separated term in the query
    /// must appear somewhere in title + keywords + section. Order-independent and
    /// cross-field, so "feedback linkedin" or "auto approve" match even when the
    /// words live in different fields. Pure, so it is unit-tested.
    static func matching(_ query: String) -> [SettingsSearchItem] {
        let terms = query.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        return all.filter { item in
            let hay = "\(item.title) \(item.keywords) \(item.section.rawValue)".lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    static let all: [SettingsSearchItem] = [
        .init(title: "Launch at login", keywords: "startup boot open", section: .general),
        .init(title: "Keep the notch open", keywords: "persistent always show display", section: .general),
        .init(title: "Auto-approve permissions", keywords: "allow automatic bypass", section: .general),
        .init(title: "Show spend in the menu bar", keywords: "cost money dollars", section: .general),
        .init(title: "Start Claude in a folder", keywords: "open launch project", section: .general),
        .init(title: "Check for updates", keywords: "version upgrade", section: .general),
        .init(title: "Setup health", keywords: "hooks status line forwarder fix install", section: .general),
        .init(title: "Codex integration", keywords: "codex openai agent beta enable integration gpt", section: .general),
        .init(title: "Notch language", keywords: "language translate localization chinese spanish hindi japanese german french korean russian portuguese 语言 idioma भाषा 言語 sprache langue 언어 язык", section: .general),

        .init(title: "Notch title", keywords: "name label claude project custom", section: .notch),
        .init(title: "Status bar items", keywords: "5 hour weekly limit session cost", section: .notch),
        .init(title: "Context window size", keywords: "200k 1m auto tokens", section: .notch),

        .init(title: "Pet Mode", keywords: "mascot creature animation boop", section: .pet),

        .init(title: "Send a message to Claude", keywords: "compose prompt", section: .session),
        .init(title: "Clear the active session", keywords: "reset", section: .session),
        .init(title: "Check what Claude actually did", keywords: "audit verify completion claim tests banner verdict lied", section: .session),
        .init(title: "Auto-approve for a while", keywords: "timed window minutes", section: .session),
        .init(title: "Snooze passive cards", keywords: "mute pause quiet", section: .session),
        .init(title: "Recent projects", keywords: "folders open", section: .session),
        .init(title: "Resume a past session", keywords: "resume reopen claude codex last continue projects", section: .session),
        .init(title: "Lines changed this session", keywords: "diff added removed churn", section: .session),
        .init(title: "Files touched", keywords: "edited reveal finder", section: .session),

        .init(title: "Session history", keywords: "past sessions log what i did digest search recall project", section: .history),
        .init(title: "What I shipped standup", keywords: "standup summary daily report shipped copy git commits update", section: .history),
        .init(title: "Export session history", keywords: "csv json download sessions", section: .history),

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

        .init(title: "Sample cards", keywords: "demo test audit verdict contradicted verified", section: .developer),
        .init(title: "Pet animations", keywords: "demo peek stroll", section: .developer),

        .init(title: "Version and links", keywords: "about changelog github setup", section: .about),
        .init(title: "Send feedback", keywords: "feedback contact linkedin message author support help", section: .about),
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
    // Free-text filter over the archived session digest history.
    @State private var historySearch = ""
    // Generated "what I shipped" standup text + the day-window it covers.
    @State private var standupText = ""
    @State private var standupDays = 1
    @State private var standupBusy = false
    @State private var standupCopied = false
    @State private var copiedSessionId: String?
    // Lazily-loaded last-assistant-reply previews, keyed by session id.
    @State private var sessionPreviews: [String: String] = [:]
    // Session the user tapped delete on, awaiting confirmation.
    @State private var pendingDelete: ResumableSession?
    // Inline session-rename editor state.
    @State private var editingNoteId: String?
    @State private var editingNoteText = ""
    @State private var updateCmdCopied = false
    @State private var codexTotals: CodexReader.CodexTotals?
    @State private var devSampleCardsOpen = false
    @State private var devPetDemosOpen = false

    private var searchResults: [SettingsSearchItem] {
        SettingsSearchItem.matching(search)
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
                            Section(L(group.title, comment: "Settings sidebar group")) {
                                ForEach(group.items) { s in
                                    Label(L(s.rawValue, comment: "Settings sidebar section"), systemImage: s.symbol).tag(s)
                                }
                            }
                        }
                    }
                    // Both ForEach identities are English and never change, so on
                    // a language switch List recycles its rows and keeps showing
                    // the labels it already built. The content pane is a
                    // ScrollView and rebuilds by itself, which is why only the
                    // sidebar was left in the previous language. Tying the List
                    // to the language forces it to build again.
                    .id(state.appLanguage)
                } else if searchResults.isEmpty {
                    VStack { Spacer(); Text(L("No matches", comment: "Settings explanation")).foregroundStyle(.secondary).font(.callout); Spacer() }
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
                                    Text(L(item.section.rawValue, comment: "Settings sidebar section")).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    // Same row recycling as the nav list above.
                    .id(state.appLanguage)
                }
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            ScrollView {
                detail
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(28)
                    // Center the reading column so a maximized / full-screen
                    // window doesn't leave the content hugging the left edge with
                    // a sea of empty space on the right.
                    .frame(maxWidth: .infinity, alignment: .center)
            }
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
        case .history:   history
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
        return page(L("General", comment: "Settings page title")) {
            if let v = state.availableUpdateVersion {
                updateBanner(version: v)
            }
            sectionLabel(L("Setup", comment: "Settings section heading"))
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
                row(L("Launch at login", comment: "Settings toggle"),
                    L("Start ClaudeNotch automatically when you log in.", comment: "Settings toggle explanation"),
                    Binding(get: { launchAtLoginEnabled }, set: { setLaunchAtLogin($0) }))
                divider
                row(L("Keep the notch open", comment: "Settings toggle"),
                    L("Always show the notch card instead of hiding it behind the hardware notch until something happens.", comment: "Settings toggle explanation"),
                    bind(\.persistentNotchDisplay, state.setPersistentNotchDisplay))
                divider
                row(L("Auto-approve permissions", comment: "Settings toggle"),
                    L("Allow every tool request automatically. Turns the notch into a passive monitor. Use with care.", comment: "Settings toggle explanation"),
                    bind(\.autoApprove, state.setAutoApprove))
                divider
                row(L("Show spend in the menu bar", comment: "Settings toggle"),
                    L("Put the running session cost next to the menu-bar bell.", comment: "Settings toggle explanation"),
                    bind(\.showSpendInMenuBar, state.setShowSpendInMenuBar))
            }

            sectionLabel(L("Quick actions", comment: "Settings section heading"))
            group {
                actionRow(L("Start Claude in a folder…", comment: "Settings button"), "play.circle") { startClaudePicker() }
                divider
                actionRow(L("Check for updates…", comment: "Settings button"), "arrow.down.circle") { UpdateChecker.shared.check(userInitiated: true) }
            }

            sectionLabel(L("Language", comment: "Settings section heading"))
            group {
                pickerRow(L("Notch language", comment: "Settings picker label"),
                          selection: Binding(get: { state.appLanguage },
                                             set: { state.setAppLanguage($0) })) {
                    Text(L("Follow macOS", comment: "Settings explanation")).tag("")
                    ForEach(Localization.available, id: \.self) { code in
                        // Someone looking for Japanese is looking for 日本語.
                        Text(Localization.nativeName(code) ?? code).tag(code)
                    }
                }
            }
            Text(L("Applies straight away, no restart. The notch cards and most of this window are translated; some longer explanations and the menu bar are still English.", comment: "Settings explanation"))
                .font(.callout).foregroundStyle(.secondary)

            sectionLabel(L("Integrations (beta)", comment: "Settings section heading"))
            Text(L("Surface other coding agents in the notch. Codex support is experimental: session status, prompts, activity and notifications appear, but permission cards and cost are not wired yet.", comment: "Settings explanation"))
                .font(.callout).foregroundStyle(.secondary)
            group {
                let _ = healthTick   // re-read install state after a toggle
                if HookInstaller.isCodexInstalled {
                    healthRow("Codex (beta)", ok: true, "Codex hooks are installed. Approve the one-time trust prompt when Codex next starts.")
                    divider
                    actionRow(L("Start Codex in a folder…", comment: "Settings button"), "play.circle") { startCodexPicker() }
                    divider
                    actionRow(L("Disable Codex integration", comment: "Settings button"), "minus.circle") {
                        HookInstaller.uninstallCodexHooks(); healthTick += 1
                    }
                } else {
                    actionRow(L("Enable Codex integration (beta)", comment: "Settings button"), "sparkles") {
                        try? HookInstaller.installCodexHooks(); healthTick += 1
                    }
                }
            }
            if HookInstaller.isCodexInstalled {
                Text(L("With Codex on, dropping a folder on the notch asks whether to open it in Claude Code or Codex.", comment: "Settings explanation"))
                    .font(.caption).foregroundStyle(.secondary)
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
                Text(L("Homebrew:", comment: "Settings explanation")).font(.caption).foregroundStyle(.white.opacity(0.8))
                Text(L("brew upgrade --cask claudenotch", comment: "Settings explanation"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                Button {
                    NSPasteboard.copyString("brew upgrade --cask claudenotch")
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
            NSLog("ClaudeNotch: settings login toggle failed: \(error)")
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
        page(L("Notch", comment: "Settings page title")) {
            sectionLabel(L("Title", comment: "Settings section heading"))
            group {
                pickerRow(L("What the title shows", comment: "Settings picker label"),
                          selection: Binding(get: { state.notchTitleMode },
                                             set: { state.setNotchTitleMode($0) })) {
                    Text(L("Claude", comment: "Settings explanation")).tag(NotchTitleMode.claude)
                    Text(L("Project name", comment: "Settings explanation")).tag(NotchTitleMode.project)
                    Text(L("Custom", comment: "Settings explanation")).tag(NotchTitleMode.custom)
                }
                if state.notchTitleMode == .custom {
                    divider
                    HStack {
                        Text(L("Custom title", comment: "Settings explanation"))
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

            sectionLabel(L("Status bar", comment: "Settings section heading"))
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

            sectionLabel(L("Context window", comment: "Settings section heading"))
            group {
                pickerRow(L("Context window size", comment: "Settings picker label"),
                          selection: Binding(get: { state.contextWindowMode },
                                             set: { state.setContextWindowMode($0) })) {
                    Text(L("Auto", comment: "Settings explanation")).tag(ContextWindowMode.auto)
                    Text(L("200K", comment: "Settings explanation")).tag(ContextWindowMode.w200k)
                    Text("1M").tag(ContextWindowMode.w1M)
                }
            }

            group {
                row(L("Drop files to open Claude", comment: "Settings toggle"),
                    L("Always on: drag a file or folder onto the notch to open Claude there.", comment: "Settings toggle explanation"),
                    .constant(true))
                    .disabled(true)
            }
        }
    }

    private var pet: some View {
        page(L("Pet", comment: "Settings page title")) {
            group {
                row(L("Pet Mode", comment: "Settings toggle"),
                    L("Let the Claude mascot live on the notch: it peeks, strolls, hangs off the edge, naps, and celebrates finished tasks. Click it to boop it.", comment: "Settings toggle explanation"),
                    bind(\.petEnabled, state.setPetEnabled))
                row(L("Random antics", comment: "Settings toggle"),
                    L("Let the pet perform on its own when the notch is idle. Turn this off to keep the pet quiet until you boop it or a task finishes.", comment: "Settings toggle explanation"),
                    bind(\.petRandomEnabled, state.setPetRandomEnabled))
                    .disabled(!state.petEnabled)
            }
        }
    }

    private var alerts: some View {
        page(L("Alerts", comment: "Settings page title")) {
            group {
                row(L("Plan-limit warnings", comment: "Settings toggle"),
                    L("Warn as your 5-hour or weekly usage fills, once at 80% and once at 95%.", comment: "Settings toggle explanation"),
                    bind(\.rateLimitWarningsEnabled, state.setRateLimitWarningsEnabled))
                divider
                row(L("Long-run alerts", comment: "Settings toggle"),
                    L("Nudge you when a single run has been going for a long time.", comment: "Settings toggle explanation"),
                    bind(\.longRunAlertsEnabled, state.setLongRunAlertsEnabled))
                divider
                row(L("Break reminders", comment: "Settings toggle"),
                    L("Occasional reminder to step away after a long stretch at the keyboard.", comment: "Settings toggle explanation"),
                    bind(\.breakRemindersEnabled, state.setBreakRemindersEnabled))
            }
            group {
                row(L("Completion notifications", comment: "Settings toggle"),
                    L("Post a Notification Center banner when a task finishes.", comment: "Settings toggle explanation"),
                    bind(\.completionNotificationsEnabled, state.setCompletionNotificationsEnabled))
                divider
                row(L("Daily and weekly digest", comment: "Settings toggle"),
                    L("A once-a-day summary of what Claude did, plus a weekly roundup of sessions and estimated cost.", comment: "Settings toggle explanation"),
                    bind(\.digestNotificationsEnabled, state.setDigestNotificationsEnabled))
                divider
                row(L("Mirror to Notification Center", comment: "Settings toggle"),
                    L("Also send notch notifications to macOS Notification Center.", comment: "Settings toggle explanation"),
                    bind(\.mirrorToNotificationCenter, state.setMirrorToNotificationCenter))
            }
        }
    }

    private var sounds: some View {
        page(L("Sounds", comment: "Settings page title")) {
            group {
                row(L("Mute all sounds", comment: "Settings toggle"),
                    L("Silence every notch sound.", comment: "Settings toggle explanation"),
                    Binding(get: { state.soundMuted }, set: { state.setSoundMuted($0) }))
                divider
                row(L("Per-tool sounds", comment: "Settings toggle"),
                    L("Different sound for different kinds of tool request.", comment: "Settings toggle explanation"),
                    Binding(get: { state.perToolSounds }, set: { state.setPerToolSounds($0) }))
            }

            if state.perToolSounds {
                sectionLabel(L("Sound per pop-up type", comment: "Settings section heading"))
                Text(L("With per-tool sounds on, each kind of pop-up plays its own sound. Change any of them; the default is shown when you have not.", comment: "Settings explanation"))
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
                sectionLabel(L("Alert sound", comment: "Settings section heading"))
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
        page(L("Budget", comment: "Settings page title")) {
            if state.fiveHourLimitPercent >= 0 || state.weeklyLimitPercent >= 0 {
                sectionLabel(L("Plan usage limits", comment: "Settings section heading"))
                Text(L("Your Claude plan's rate limits, as Claude Code last reported them. These are usage limits, not dollar caps.", comment: "Settings explanation"))
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

            Text(L("Warn when estimated cost crosses a cap. Set a cap to 0 to disable it.", comment: "Settings explanation"))
                .font(.callout).foregroundStyle(.secondary)
            sectionLabel(L("Caps (USD)", comment: "Settings section heading"))
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
                row(L("Hard-stop at the cap", comment: "Settings toggle"),
                    L("Block new tool runs once a cap is crossed, instead of only warning.", comment: "Settings toggle explanation"),
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
        page(L("Privacy", comment: "Settings page title")) {
            group {
                row(L("Hide from screen capture", comment: "Settings toggle"),
                    L("Exclude the notch from screen shares, recordings, and other apps' screenshots. It renders commands, paths, and code, so this is on by default.", comment: "Settings toggle explanation"),
                    bind(\.hideFromScreenCapture, state.setHideFromScreenCapture))
                divider
                row(L("Require Touch ID for permissions", comment: "Settings toggle"),
                    L("Ask for Touch ID before allowing a tool request from the notch.", comment: "Settings toggle explanation"),
                    bind(\.requireTouchID, state.setRequireTouchID))
            }

            sectionLabel(L("System permissions", comment: "Settings section heading"))
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

            sectionLabel(L("Always-allow rules", comment: "Settings section heading"))
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
        page(L("Session", comment: "Settings page title")) {
            sectionLabel(L("Current session", comment: "Settings section heading"))
            group {
                actionRow(L("Send a message to Claude…", comment: "Settings button"), "paperplane") {
                    state.beginCompose()
                    window()?.close()
                }
                divider
                actionRow(L("Clear the active session", comment: "Settings button"), "xmark.circle") { state.clearSession() }
            }

            sectionLabel(L("Finished tasks", comment: "Settings section heading"))
            group {
                row(L("Check what Claude actually did", comment: "Settings toggle"),
                    L("When a task finishes, compare the closing message against what the turn really did, and say so on the card if it claims a change it never made or says the tests pass when none ran. Off by default: it is an opinion about the work, and it stays quiet on an ordinary turn.", comment: "Settings toggle explanation"),
                    Binding(get: { state.completionAuditEnabled },
                            set: { state.setCompletionAuditEnabled($0) }))
            }

            sectionLabel(L("Auto-approve for a while", comment: "Settings section heading"))
            Text(L("Turn on auto-approve for a set time and it switches itself back off, or keep it on until you turn it off.", comment: "Settings explanation"))
                .font(.callout).foregroundStyle(.secondary)
            group {
                actionRow(L("Keep on until I turn it off", comment: "Settings button"), "infinity") { state.setAutoApprove(true) }
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
                Text(L("Auto-approve is on until you turn it off.", comment: "Settings explanation"))
                    .font(.caption).foregroundStyle(.orange)
                Button("Turn off now") { state.setAutoApprove(false) }
            }

            sectionLabel(L("Snooze passive cards", comment: "Settings section heading"))
            group {
                let windows = [15, 30, 60]
                ForEach(Array(windows.enumerated()), id: \.element) { idx, m in
                    actionRow(String(format: L("Snooze for %@", comment: "Settings button. %@ is a duration such as 30 min"), windowLabel(m)), "moon.zzz") { state.snooze(forMinutes: m) }
                    if idx < windows.count - 1 { divider }
                }
            }
            if let until = state.snoozedUntil {
                Text("Snoozed until \(until.formatted(date: .omitted, time: .shortened)).")
                    .font(.caption).foregroundStyle(.orange)
                Button("Cancel snooze") { state.cancelSnooze() }
            }

            sectionLabel(L("Projects & recent sessions", comment: "Settings section heading"))
            Text(L("Closed a terminal by accident? Expand a project and resume right where you left off.", comment: "Settings explanation"))
                .font(.callout).foregroundStyle(.secondary)
            if projectSessions.isEmpty {
                group {
                    HStack {
                        Text(L("No past sessions found yet.", comment: "Settings explanation"))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 10).padding(.horizontal, 14)
                }
            } else {
                SearchField(placeholder: "Filter by project or prompt…", text: $sessionSearch)

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
                sectionLabel(L("Lines changed this session", comment: "Settings section heading"))
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
                sectionLabel(L("Files touched this session", comment: "Settings section heading"))
                group {
                    let files = Array(state.currentTouchedFiles.prefix(10))
                    ForEach(Array(files.enumerated()), id: \.element) { idx, path in
                        actionRow((path as NSString).lastPathComponent, "doc") {
                            AppState.openEditedFile(path)
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
            let codexOn = HookInstaller.isCodexInstalled
            let loaded = await Task.detached(priority: .utility) {
                SessionResumer.allAgentSessionsByProject(includeCodex: codexOn)
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
                        AgentChip(model: s.model)
                        Text(note?.isEmpty == false ? note! : s.title)
                            .lineLimit(1)
                            .fontWeight(note?.isEmpty == false ? .semibold : .regular)
                        if state.sessions[s.id] != nil {
                            HStack(spacing: 3) {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                                Text(L("running", comment: "Settings explanation")).font(.caption2)
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
                Button("Resume") {
                    TerminalAutomator.resume(model: s.model, sessionId: s.id, in: s.cwd)
                    window()?.close()
                }
                .controlSize(.small)
                Menu {
                    Button {
                        editingNoteId = s.id
                        editingNoteText = state.sessionNotes[s.id] ?? ""
                    } label: { Label("Rename session", systemImage: "pencil") }
                    Button {
                        let cmd = TerminalAutomator.resumeCommand(model: s.model, sessionId: s.id)
                        NSPasteboard.copyString(cmd)
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
            let isCodex = AgentKind.infer(fromModel: s.model) == .codex
            let reply = await Task.detached(priority: .utility) {
                // Codex rollouts store replies differently, so use the matching reader.
                isCodex ? CodexReader.lastReply(from: url) : SessionResumer.lastReply(from: url)
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
        page(L("Usage", comment: "Settings page title")) {
            let churn = state.churnToday
            if churn.added > 0 || churn.removed > 0 {
                sectionLabel(L("Code churn today", comment: "Settings section heading"))
                HStack(spacing: 12) {
                    churnStat("Lines added", "+\(churn.added)", .green)
                    churnStat("Lines removed", "-\(churn.removed)", .red)
                    churnStat("Net", "\(churn.added - churn.removed >= 0 ? "+" : "")\(churn.added - churn.removed)", .primary)
                }
            }

            if let u = claudeUsage {
                let trend = spendTrendData(u)
                if trend.contains(where: { $0.cost > 0 }) {
                    sectionLabel(L("Estimated cost, last 7 days", comment: "Settings section heading"))
                    Text(L("Estimated at public API (pay-as-you-go) prices. On a Pro, Max, Team, or Enterprise subscription you pay a flat fee, so this is not your actual bill, it is what the usage would cost per token.", comment: "Settings explanation"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    spendTrend(trend)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardChrome()
                }
                let weekly = ClaudeUsageReader.weeklyCostBuckets(daily: u.dailyCostUSD, weeks: 4, asOf: Date())
                if weekly.contains(where: { $0.cost > 0 }) {
                    sectionLabel(L("Estimated cost, last 4 weeks", comment: "Settings section heading"))
                    spendTrend(weekly)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardChrome()
                }
            }

            sectionLabel(L("Activity, last 7 weeks", comment: "Settings section heading"))
            activityHeatmap
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardChrome()

            Text(L("All-time counters, kept locally on this Mac.", comment: "Settings explanation"))
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
                sectionLabel(L("Top tools", comment: "Settings section heading"))
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
                sectionLabel(L("Top projects by estimated cost (7 days)", comment: "Settings section heading"))
                let maxSpend = spendLeaders.first?.value ?? 1
                group {
                    ForEach(Array(spendLeaders.enumerated()), id: \.element.key) { idx, kv in
                        spendLeaderRow(project: (kv.key as NSString).lastPathComponent,
                                       cost: kv.value, fraction: maxSpend > 0 ? kv.value / maxSpend : 0)
                        if idx < spendLeaders.count - 1 { divider }
                    }
                }
            }

            sectionLabel(L("Claude usage (from transcripts)", comment: "Settings section heading"))
            Text(L("Costs are estimates at public API prices, not your subscription bill.", comment: "Settings explanation"))
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
                    sectionLabel(L("Model mix (last 7 days)", comment: "Settings section heading"))
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
                Text(L("Reading transcripts…", comment: "Settings explanation")).font(.callout).foregroundStyle(.secondary)
            }

            if HookInstaller.isCodexInstalled, let c = codexTotals, !c.isEmpty {
                sectionLabel(L("Codex usage (tokens)", comment: "Settings section heading"))
                Text(L("Token counts from Codex rollouts. No dollar cost: gpt pricing isn't published, so a figure would be a guess.", comment: "Settings explanation"))
                    .font(.caption).foregroundStyle(.secondary)
                group {
                    statRow("Today", "\(formatTokens(c.todayTokens)) tok · \(c.sessionsToday) session\(c.sessionsToday == 1 ? "" : "s")")
                    divider
                    statRow("This week", "\(formatTokens(c.weekTokens)) tok · \(c.sessionsWeek) session\(c.sessionsWeek == 1 ? "" : "s")")
                }
            }
        }
        .task(id: section) {
            guard section == .usage else { return }
            let codexOn = HookInstaller.isCodexInstalled
            let (usage, ctotals) = await Task.detached(priority: .utility) {
                (ClaudeUsageReader.compute(), codexOn ? CodexReader.tokenTotals() : nil)
            }.value
            claudeUsage = usage
            codexTotals = ctotals
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
                Text(L("Less", comment: "Settings explanation")).font(.caption2).foregroundStyle(.secondary)
                ForEach(0..<5, id: \.self) { l in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(heatColor(l)).frame(width: 11, height: 11)
                }
                Text(L("More", comment: "Settings explanation")).font(.caption2).foregroundStyle(.secondary)
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
        .cardChrome()
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
        page(L("Developer", comment: "Settings page title")) {
            Text(L("Fire a sample card to see what the notch looks like.", comment: "Settings explanation"))
                .font(.callout).foregroundStyle(.secondary)
            DisclosureGroup(isExpanded: $devSampleCardsOpen) {
                group {
                    actionRow(L("Tool permission", comment: "Settings button"), "terminal") { demoPermission() }
                    divider
                    actionRow(L("Destructive command", comment: "Settings button"), "exclamationmark.triangle") { demoDangerous() }
                    divider
                    actionRow(L("Edit with diff preview", comment: "Settings button"), "doc.text.magnifyingglass") { demoDiff() }
                    divider
                    actionRow(L("Auto-approve (live activity)", comment: "Settings button"), "bolt.badge.a") { demoAutoApprove() }
                    divider
                    actionRow(L("Notification", comment: "Settings button"), "bell") { demoNotification() }
                    divider
                    actionRow(L("Task complete", comment: "Settings button"), "checkmark.seal") { demoCompleted() }
                    divider
                    actionRow(L("Task complete: claim contradicted", comment: "Settings button"), "exclamationmark.triangle") {
                        demoAudit(.contradicted("Claude says it changed the code, but this turn edited no file and ran no command."))
                    }
                    divider
                    actionRow(L("Task complete: not demonstrated", comment: "Settings button"), "questionmark.circle") {
                        demoAudit(.unverified("Claude says the tests pass, but no test command ran this turn."))
                    }
                    divider
                    actionRow(L("Task complete: verified", comment: "Settings button"), "checkmark.circle") {
                        demoAudit(.verified("2 files changed, tests passed."))
                    }
                    divider
                    actionRow(L("Thinking pulse", comment: "Settings button"), "brain") { state.pingThinking(label: "Editing AuthMiddleware.swift") }
                    divider
                    actionRow(L("Cost budget alert", comment: "Settings button"), "dollarsign.circle") { state.demoBudgetAlert() }
                    divider
                    actionRow(L("Budget hard-stop", comment: "Settings button"), "hand.raised") { state.demoBudgetBlock() }
                }
                .padding(.top, 6)
            } label: {
                Text(L("Sample cards", comment: "Settings explanation")).font(.callout.weight(.semibold))
            }

            DisclosureGroup(isExpanded: $devPetDemosOpen) {
                group {
                    let demoable = PetActivity.allCases.filter { $0 != .tucked }
                    actionRow(L("Play all", comment: "Settings button"), "play.circle") { state.demoPet(demoable) }
                    divider
                    ForEach(Array(demoable.enumerated()), id: \.element) { idx, activity in
                        actionRow(Self.petDemoTitle(activity), "pawprint") { state.demoPet([activity]) }
                        if idx < demoable.count - 1 { divider }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text(L("Pet animations", comment: "Settings explanation")).font(.callout.weight(.semibold))
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
            title: "Done, 14 files changed, tests green",
            detail: "Refactored auth middleware and re-ran the suite.",
            source: "Demo", cwd: NSHomeDirectory()))
    }

    /// The completion audit's three verdicts, on demand.
    ///
    /// The real thing needs a finished turn whose closing message disagrees
    /// with what the tools did, which you cannot stage to order. Without these
    /// the headline case is unreachable by hand.
    private func demoAudit(_ verdict: CompletionAudit.Verdict) {
        let task = CompletedTask(
            title: "Fixed the ordering in the phase machine",
            detail: "Claude said it was done.",
            source: "Demo", cwd: NSHomeDirectory())
        task.audit = verdict
        state.enqueueCompleted(task)
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
        page(L("About", comment: "Settings page title")) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("ClaudeNotch", comment: "Settings explanation")).font(.title2.weight(.semibold))
                    Text(L("Claude Code, living in your notch.", comment: "Settings explanation"))
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Version \(Self.appVersion)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            if !Self.whatsNew.isEmpty {
                sectionLabel(String(format: L("What's new in v%@", comment: "Settings section heading. %@ is the version number"), Self.appVersion))
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
                actionRow(L("Send feedback", comment: "Settings button"), "bubble.left.and.bubble.right") { Self.openFeedback() }
                divider
                actionRow(L("Check for updates…", comment: "Settings button"), "arrow.down.circle") { UpdateChecker.shared.check(userInitiated: true) }
                if onOpenSetup != nil {
                    divider
                    actionRow(L("Run setup again…", comment: "Settings button"), "wand.and.stars") { onOpenSetup?() }
                }
            }
        }
    }

    // MARK: building blocks

    // Archived session digests filtered by the search box: match project,
    // summary, model, branch, or agent so "what did I do in project X" works.
    private var filteredHistory: [SessionRecord] {
        let q = historySearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return state.sessionHistory }
        return state.sessionHistory.filter { r in
            let hay = "\(r.project) \(r.summary ?? "") \(r.model) \(r.gitBranch ?? "") \(r.agent ?? "")"
                .lowercased()
            return hay.contains(q)
        }
    }

    private var history: some View {
        page(L("History", comment: "Settings page title")) {
            Text(L("Every session you finish is archived here with a one-line summary, its cost, and what it changed. Search to recall what you did in a project last week.", comment: "Settings explanation"))
                .font(.callout).foregroundStyle(.secondary)

            if state.sessionHistory.isEmpty {
                group {
                    HStack {
                        Text(L("No finished sessions yet. They show up here after a session ends.", comment: "Settings explanation"))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 10).padding(.horizontal, 14)
                }
            } else {
                standupSection
                let total = state.sessionHistory.reduce(into: (cost: 0.0, add: 0, rem: 0)) { acc, r in
                    acc.cost += r.costUSD
                    acc.add += r.linesAdded ?? 0
                    acc.rem += r.linesRemoved ?? 0
                }
                HStack(spacing: 14) {
                    Text("\(state.sessionHistory.count) sessions")
                    Text(ClaudeUsageReader.fmtMoney(total.cost)).foregroundStyle(.secondary)
                    Text("+\(total.add)").foregroundStyle(.green)
                    Text("-\(total.rem)").foregroundStyle(.red)
                }
                .font(.callout.monospacedDigit())

                SearchField(placeholder: "Search by project, summary, branch…", text: $historySearch)

                let matches = filteredHistory
                if matches.isEmpty {
                    group {
                        HStack {
                            Text("No sessions match “\(historySearch)”.")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 10).padding(.horizontal, 14)
                    }
                } else {
                    group {
                        ForEach(Array(matches.prefix(100).enumerated()), id: \.element.id) { idx, r in
                            historyRow(r)
                            if idx < min(matches.count, 100) - 1 { divider }
                        }
                    }
                }

                HStack {
                    Button("Export…") { state.exportSessionHistory() }
                    Spacer()
                    Button("Clear history", role: .destructive) { state.clearSessionHistory() }
                        .foregroundStyle(.red)
                }
                .padding(.top, 2)
            }
        }
    }

    // "What I shipped": one-click standup built from the session digests + git
    // commits over the chosen window, ready to paste into a standup or update.
    private var standupSection: some View {
        group {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "text.badge.checkmark").foregroundStyle(.blue)
                    Text(L("What I shipped", comment: "Settings explanation")).font(.body.weight(.semibold))
                    Spacer()
                    Picker("", selection: $standupDays) {
                        Text(L("Today", comment: "Settings explanation")).tag(1)
                        Text(L("3 days", comment: "Settings explanation")).tag(3)
                        Text(L("Week", comment: "Settings explanation")).tag(7)
                    }
                    .labelsHidden().fixedSize().controlSize(.small)
                    Button {
                        generateStandup()
                    } label: {
                        if standupBusy { ProgressView().controlSize(.small) }
                        else { Text(L("Generate", comment: "Settings explanation")) }
                    }
                    .disabled(standupBusy)
                }
                if !standupText.isEmpty {
                    TextEditor(text: .constant(standupText))
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 120, maxHeight: 260)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    HStack {
                        Button {
                            NSPasteboard.copyString(standupText)
                            standupCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { standupCopied = false }
                        } label: {
                            Label(standupCopied ? "Copied" : "Copy", systemImage: standupCopied ? "checkmark" : "doc.on.doc")
                        }
                        Spacer()
                    }
                }
            }
            .padding(.vertical, 12).padding(.horizontal, 14)
        }
    }

    private func generateStandup() {
        standupBusy = true
        let records = state.sessionHistory
        let dirs = state.recentProjects
        let days = standupDays
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                AppState.standupText(records: records, extraDirs: dirs, days: days)
            }.value
            await MainActor.run {
                standupText = text
                standupBusy = false
                standupCopied = false
            }
        }
    }

    private func historyRow(_ r: SessionRecord) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.cwd)])
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(r.project).font(.body.weight(.semibold))
                    AgentChip(model: r.model)
                    if let b = r.gitBranch, !b.isEmpty {
                        Label(b, systemImage: "arrow.triangle.branch")
                            .font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                    }
                    Spacer()
                    Text(r.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let s = r.summary, !s.isEmpty {
                    Text(s).font(.callout).foregroundStyle(.primary).lineLimit(2)
                }
                HStack(spacing: 12) {
                    if r.costUSD > 0 {
                        Text(ClaudeUsageReader.fmtMoney(r.costUSD))
                    }
                    if let a = r.linesAdded, let d = r.linesRemoved, a + d > 0 {
                        Text("+\(a)").foregroundStyle(.green)
                        Text("-\(d)").foregroundStyle(.red)
                    }
                    if let f = r.filesTouched, f > 0 {
                        Text("\(f) file\(f == 1 ? "" : "s")")
                    }
                    if let dur = r.duration, dur >= 1 {
                        Text(AppState.runningDuration(seconds: dur))
                    }
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.vertical, 9).padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Reveal \(r.cwd) in Finder")
    }

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
            .cardChrome()
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

    /// Open the author's LinkedIn profile so the user can hit Message. The
    /// messaging compose URL needs LinkedIn's internal member id (the vanity
    /// slug fails to load), so the profile is the reliable target.
    static func openFeedback() {
        NSWorkspace.shared.open(URL(string: "https://www.linkedin.com/in/roshan-ramani-0510102b2")!)
    }

    /// Highlights for the current release, shown on the About page. Keep this in
    /// sync with the top changelog entry when cutting a release.
    static let whatsNew: [String] = [
        "Checking what Claude actually did is now off by default, in Settings > Session. It is an opinion about your work, so it should be something you ask for. It is also much quieter: it says nothing on an ordinary turn and speaks only when a claimed change was never made, when the tests are said to pass but none ran, or when a change was made and the tests back it up.",
        "The notch shows the model version again. It read a fixed two-part number out of the model id, which found nothing in a single-digit release, so Opus 5 showed as a bare Opus. Any shape works now, including a later 5.1 or 5.2, and the name and version read as one label instead of two separate stats.",
        "Two cases where the task check spoke when it should not have: quoting the app's own wording back at it, in a note about testing, was read as a claim, and a project's own test script did not count as a test run.",
    ]
}
