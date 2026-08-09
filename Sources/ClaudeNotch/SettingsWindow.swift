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
    var window: NSWindow?
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
        w.identifier = NSUserInterfaceItemIdentifier("ClaudeNotchSettings")
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
    case plan = "Plan"
    case rules = "Rules"
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
        case .plan: return "creditcard"
        case .rules: return "checkmark.shield"
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
        ("Alerts & Cost", [.alerts, .sounds, .budget, .plan]),
        ("Permissions", [.rules]),
        ("Info", [.usage, .history, .privacy, .about]),
        ("Advanced", [.developer]),
    ]

    /// The sidebar top to bottom, groups flattened. The order arrow keys move
    /// in, so it has to come from the same place the sidebar is built from.
    static var ordered: [SettingsSection] { nav.flatMap(\.items) }

    /// The section `offset` rows away, clamped at the ends.
    ///
    /// Clamped rather than wrapping: holding the down arrow should come to rest
    /// on the last row, not silently jump back to the top and start again.
    nonisolated static func section(from current: SettingsSection, offset: Int) -> SettingsSection {
        let all = ordered
        guard let i = all.firstIndex(of: current) else { return current }
        return all[min(all.count - 1, max(0, i + offset))]
    }

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
        L("Plan", comment: "Settings sidebar section"),
        L("Rules", comment: "Settings sidebar section"),
        L("Privacy", comment: "Settings sidebar section"),
        L("Usage", comment: "Settings sidebar section"),
        L("History", comment: "Settings sidebar section"),
        L("Developer", comment: "Settings sidebar section"),
        L("About", comment: "Settings sidebar section"),
        L("Workspace", comment: "Settings sidebar group"),
        L("Alerts & Cost", comment: "Settings sidebar group"),
        L("Info", comment: "Settings sidebar group"),
        L("Permissions", comment: "Settings sidebar group"),
        L("Advanced", comment: "Settings sidebar group"),
    ]
}

/// The rounded search box used on the list pages (sessions, history). One
/// component so the three-way icon + field + clear-button layout and its
/// chrome don't get re-typed (and drift) at every call site.
struct SearchField: View {
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
        .init(title: "Menu bar only", keywords: "no notch external display hide pill", section: .general),
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
        .init(title: "Guest appearances", keywords: "spider-pet spiderman costume special event cameo pet", section: .pet),

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

        .init(title: "Your plan", keywords: "pro max team enterprise subscription tier billing seat role", section: .plan),
        .init(title: "Plan limits", keywords: "5 hour weekly opus session rate limit resets percent", section: .plan),
        .init(title: "Usage credits", keywords: "extra usage credits overage balance auto reload spend limit monthly", section: .plan),

        .init(title: "Always-allow rules", keywords: "allowlist permissions approved automatically whitelist rule audit", section: .rules),
        .init(title: "Add an allow rule", keywords: "rule tool command bash exact new", section: .rules),
        .init(title: "Export rules to Claude Code", keywords: "settings json permissions allow merge copy export", section: .rules),

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
    @State var section: SettingsSection = .general
    @State var claudeUsage: ClaudeUsageReader.Usage?
    @State private var heatTip: String?
    @State private var search = ""
    @State private var healthTick = 0
    // Past Claude Code sessions grouped by project (read off disk), and which
    // project rows the user has expanded to reveal their resumable sessions.
    @State var projectSessions: [(cwd: String, project: String, sessions: [ResumableSession])] = []
    @State private var expandedProjects: Set<String> = []
    @State var sessionSearch = ""
    // Free-text filter over the archived session digest history.
    @State var historySearch = ""
    // Generated "what I shipped" standup text + the day-window it covers.
    @State private var standupText = ""
    @State private var standupDays = 1
    @State private var standupBusy = false
    @State private var standupCopied = false
    @State private var copiedSessionId: String?
    // Lazily-loaded last-assistant-reply previews, keyed by session id.
    @State private var sessionPreviews: [String: String] = [:]
    // Session the user tapped delete on, awaiting confirmation.
    @State var pendingDelete: ResumableSession?
    // Inline session-rename editor state.
    @State private var editingNoteId: String?
    @State private var editingNoteText = ""
    @State private var updateCmdCopied = false
    @State private var terminalCmdCopied = false
    // Always-allow rule editor: the row being typed, and what came of the
    // last action taken on the list.
    @State var newRuleTool = ""
    @State var newRuleCommand = ""
    @State var newRuleNote: String?
    @State var rulesCopied = false
    @State var mergeResult: String?
    @State var codexTotals: CodexReader.CodexTotals?
    @State var devSampleCardsOpen = false
    @State var devPetDemosOpen = false

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
        .onAppear { installArrowKeyNavigation(selection: $section) }
        .onDisappear { removeArrowKeyNavigation() }
    }

    // MARK: - Arrow-key navigation

    /// Up and down move between sidebar sections from anywhere in the window.
    ///
    /// SwiftUI's List does this once it has keyboard focus, which means
    /// clicking a row first. Nobody does that: they open Settings and press
    /// down. A local key monitor gets it from the first keystroke instead.
    ///
    /// Intercepting the arrows is safe here because every text field in this
    /// window is single line, where up and down only jump to the start or end
    /// of the text. It is skipped anyway while a field is being edited, so
    /// typing in the search box still behaves normally.
    private func installArrowKeyNavigation(selection: Binding<SettingsSection>) {
        // A Binding reads and writes live state, so the monitor stays correct
        // as the selection changes. Capturing the value would freeze it at
        // whatever was selected when the window opened.
        Self.moveSection = { offset in
            selection.wrappedValue = SettingsSection.section(from: selection.wrappedValue,
                                                             offset: offset)
        }
        guard Self.arrowMonitor == nil else { return }
        Self.arrowMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.identifier?.rawValue == "ClaudeNotchSettings" else { return event }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
            let offset: Int
            switch event.keyCode {
            case 126: offset = -1      // up
            case 125: offset = 1       // down
            default:  return event
            }
            // Let a field that is genuinely being edited keep its arrows.
            if let responder = event.window?.firstResponder as? NSTextView, responder.isEditable {
                return event
            }
            Self.moveSection?(offset)
            return nil                 // handled, do not also scroll the page
        }
    }

    private func removeArrowKeyNavigation() {
        if let m = Self.arrowMonitor { NSEvent.removeMonitor(m) }
        Self.arrowMonitor = nil
        Self.moveSection = nil
    }

    /// The monitor is a process-level hook, so it cannot capture `self`
    /// (a struct that is recreated on every redraw). It calls through this
    /// instead, which the view keeps pointed at its current state.
    nonisolated(unsafe) private static var arrowMonitor: Any?
    nonisolated(unsafe) private static var moveSection: ((Int) -> Void)?

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
        case .plan:      plan
        case .rules:     rules
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
                row(L("Menu bar only", comment: "Settings toggle"),
                    L("Hide the floating notch pill on every display and use the menu bar item instead. For Macs without a notch, or when working on an external display.", comment: "Settings toggle explanation"),
                    bind(\.menuBarOnlyMode, state.setMenuBarOnlyMode))
                divider
                row(L("Auto-approve permissions", comment: "Settings toggle"),
                    L("Allow every tool request automatically. Turns the notch into a passive monitor. Use with care.", comment: "Settings toggle explanation"),
                    bind(\.autoApprove, state.setAutoApprove))
                divider
                row(L("Show spend in the menu bar", comment: "Settings toggle"),
                    L("Put the running session cost next to the menu-bar bell.", comment: "Settings toggle explanation"),
                    bind(\.showSpendInMenuBar, state.setShowSpendInMenuBar))
                divider
                row(L("Show your plan in the menu bar", comment: "Settings toggle"),
                    L("Your plan and whichever limit is closest to full, next to the menu-bar bell, so how much you have left is answered without opening anything.", comment: "Settings toggle explanation"),
                    bind(\.showPlanInMenuBar, state.setShowPlanInMenuBar))
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
            Text(L("Applies straight away, no restart. The notch and this window are translated; the menu bar is still English.", comment: "Settings explanation"))
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

    private var downloadButton: some View {
        Button {
            if let url = URL(string: ProjectLinks.latestDMG) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Label(L("Download", comment: "Button: download the DMG"),
                  systemImage: "square.and.arrow.down")
        }
    }

    /// In-app update banner shown at the top of General when a newer release is
    /// found: the version, a one-click Update Now when the bundled updater is on
    /// disk, a plain Download, and the copyable commands for anyone who would
    /// rather drive it themselves.
    private func updateBanner(version: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.white)
                Text(String(format: L("Update available: v%@", comment: "About page. %@ is the new version number"), version))
                    .font(.headline).foregroundStyle(.white)
                Spacer()
                Text(String(format: L("You have v%@", comment: "About page. %@ is the installed version number"), UpdateChecker.shared.currentVersion))
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 8) {
                // One click, when the updater is on disk. It downloads, checks
                // the DMG against the checksum published with the release,
                // quits, replaces and relaunches. The copyable commands below
                // stay for anyone who would rather drive it themselves, and
                // are the only option when the script is missing.
                if TerminalAutomator.canSelfUpdate {
                    Button {
                        TerminalAutomator.runUpdater()
                    } label: {
                        Label(L("Update Now", comment: "Button: install the new version"),
                              systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                // Demoted to a plain button once Update Now is there to be the
                // obvious thing to press, and the prominent one when it is not.
                if TerminalAutomator.canSelfUpdate {
                    downloadButton.buttonStyle(.bordered).controlSize(.small)
                } else {
                    downloadButton.buttonStyle(.borderedProminent).controlSize(.small)
                }
                Button(L("Release notes", comment: "Button: open the changelog")) {
                    if let url = URL(string: ProjectLinks.changelog) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                Spacer()
            }
            HStack(spacing: 8) {
                Text(L("Homebrew:", comment: "Settings explanation")).font(.caption).foregroundStyle(.white.opacity(0.8))
                Text(verbatim: ProjectLinks.brewUpgrade)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                Button {
                    NSPasteboard.copyString(ProjectLinks.brewUpgrade)
                    updateCmdCopied = true
                } label: {
                    Image(systemName: updateCmdCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            // For everyone who installed from the DMG, which Homebrew cannot
            // update. The script is already on disk next to the hook scripts.
            HStack(spacing: 8) {
                Text(L("Terminal:", comment: "Settings explanation")).font(.caption).foregroundStyle(.white.opacity(0.8))
                Text(verbatim: Self.updateCommand)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    NSPasteboard.copyString(Self.updateCommand)
                    terminalCmdCopied = true
                } label: {
                    Image(systemName: terminalCmdCopied ? "checkmark" : "doc.on.doc")
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

            sectionLabel(L("Everyday", comment: "Settings section heading"))
            Text(L("What the pet does as itself. Click any of them to watch it now.", comment: "Settings explanation"))
                .font(.callout).foregroundStyle(.secondary)
            group {
                let everyday = PetActivity.everydayCases
                ForEach(Array(everyday.enumerated()), id: \.element) { idx, activity in
                    actionRow(activity.title, "pawprint") { state.demoPet([activity]) }
                    if idx < everyday.count - 1 { divider }
                }
            }
            .disabled(!state.petEnabled)
            .opacity(state.petEnabled ? 1 : 0.5)

            sectionLabel(L("Guest appearances", comment: "Settings section heading"))
            Text(L("The pet dressed as something else, each one a nod to whatever was in the air when it was built.", comment: "Settings explanation"))
                .font(.callout).foregroundStyle(.secondary)
            group {
                let specials = PetActivity.specialCases
                ForEach(Array(specials.enumerated()), id: \.element) { idx, activity in
                    if let guest = activity.special {
                        specialPetRow(activity, guest)
                        if idx < specials.count - 1 { divider }
                    }
                }
            }
            .disabled(!state.petEnabled)
            .opacity(state.petEnabled ? 1 : 0.5)
        }
    }

    /// A guest appearance says what it is dressed as, what it references and
    /// when it landed, since a costume nobody recognises is just a glitch.
    func specialPetRow(_ activity: PetActivity,
                               _ guest: PetActivity.SpecialAppearance) -> some View {
        Button { state.demoPet([activity]) } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(guest.name)
                        Text(Self.arrivedLabel(guest.addedOn))
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Text(guest.reference).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "play.circle").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 8).padding(.horizontal, 14)
        }
        .buttonStyle(.plain)
    }

    /// "Added Jul 2026" from an ISO date, falling back to the raw string rather
    /// than showing nothing if a costume ever lands with a malformed date.
    static func arrivedLabel(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.setLocalizedDateFormatFromTemplate("MMM y")
        return "Added " + out.string(from: date)
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

            sectionLabel(L("Sound per event", comment: "Settings section heading"))
            Text(L("Every noise the app makes, one row each. Pick a different sound, or pick None to silence just that one. The prompts follow the alert sound above until you give them one of their own.", comment: "Settings explanation"))
                .font(.callout).foregroundStyle(.secondary)
            group {
                let events = SoundEvent.allCases
                ForEach(Array(events.enumerated()), id: \.element) { idx, event in
                    soundPickerRow(event.label, event.detail,
                                   get: { state.sound(for: event) },
                                   set: { state.setSound(event, $0) })
                    if idx < events.count - 1 { divider }
                }
            }
            .disabled(state.soundMuted)
            .opacity(state.soundMuted ? 0.5 : 1)
        }
    }

    /// Audition a choice. Silence has nothing to audition, and asking AppKit
    /// for a sound named "None" would just fail quietly, so it stops here.
    private static func preview(_ name: String) {
        guard name != AppState.silentSound else { return }
        NSSound(named: NSSound.Name(name))?.play()
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
                set: { set($0); Self.preview($0) }
            )) {
                ForEach(AppState.selectableSounds, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize().controlSize(.small)
            Button { Self.preview(get()) } label: {
                Image(systemName: get() == AppState.silentSound ? "speaker.slash" : "play.circle")
            }
            .buttonStyle(.plain)
            .disabled(get() == AppState.silentSound)
        }
        .padding(.vertical, 8).padding(.horizontal, 14)
    }

    /// An amount in whatever currency the credit block reports, falling back to
    /// the locale's own formatting when it does not say.
    func money(_ amount: Double, _ currency: String?) -> String {
        amount.formatted(.currency(code: currency ?? "USD"))
    }

    /// A plan-usage limit as a labelled progress bar plus a reset countdown and
    /// a burn-rate forecast. `pct` is 0...1; the bar tints amber past 75% and
    /// red past 90%. `window` is the limit's period (5h or 7d) used to estimate
    /// how fast usage is climbing.
    func limitRow(_ title: String, pct: Double, resetAt: Date?, window: TimeInterval) -> some View {
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
                Text(String(format: L("Resets %@.", comment: "Plan limits. %@ is a relative time such as \"in 2 hours\""), resetAt.formatted(.relative(presentation: .named))))
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

    func capRow(_ title: String, get: @escaping () -> Double, set: @escaping (Double) -> Void) -> some View {
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
                divider
                row(L("Strict mode", comment: "Settings toggle"),
                    L("Only let commands that read and change nothing be approved for you. Auto-Approve and tool-wide rules stop applying to everything else, so a build, a script, or anything reaching the network waits for a click. Rules you made for one exact command still work. The destructive-command check recognises patterns, and a pattern list is never finished; this is the setting for when that is not good enough.", comment: "Settings toggle explanation"),
                    bind(\.strictMode, state.setStrictMode))
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
                Text(L("No always-allow rules. Approve a request with \u{201C}Always allow\u{201D} to add one.", comment: "Rules page, empty state"))
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

    /// Trash a session transcript and drop it from the in-memory list.
    func deleteSession(_ s: ResumableSession) {
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
    var filteredProjectSessions: [(cwd: String, project: String, sessions: [ResumableSession])] {
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
    func projectRow(_ proj: (cwd: String, project: String, sessions: [ResumableSession]), forceOpen: Bool = false) -> some View {
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

    func windowLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) hour\(minutes >= 120 ? "s" : "")"
    }

    func window() -> NSWindow? {
        NSApp.windows.first { $0.title == "ClaudeNotch Settings" }
    }

    /// Last 7 days of spend as (weekday label, cost), oldest to newest.
    func spendTrendData(_ u: ClaudeUsageReader.Usage) -> [(label: String, cost: Double)] {
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
    func spendTrend(_ data: [(label: String, cost: Double)]) -> some View {
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

    func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
    func usd(_ v: Double) -> String { String(format: "$%.2f", v) }

    private static let weekdayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var activityHeatmap: some View {
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
    func spendLeaderRow(project: String, cost: Double, fraction: Double) -> some View {
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
    func churnStat(_ label: String, _ value: String, _ color: Color) -> some View {
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

    func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 8).padding(.horizontal, 14)
    }


    func demoPermission() {
        state.enqueuePermission(DemoCards.permission(), bypassRules: true)
    }
    func demoDangerous() {
        state.enqueuePermission(DemoCards.dangerous(), bypassRules: true)
    }
    func demoNotification() {
        state.enqueuePermission(DemoCards.notification(), bypassRules: true)
    }
    func demoCompleted() {
        state.enqueueCompleted(DemoCards.completed())
    }
    func demoAudit(_ verdict: CompletionAudit.Verdict) {
        state.enqueueCompleted(DemoCards.audited(verdict))
    }
    func demoDiff() {
        state.enqueuePermission(DemoCards.diff(), bypassRules: true)
    }
    func demoAutoApprove() {
        state.demoAutoApprove(DemoCards.autoApproved())
    }

    // MARK: building blocks

    // Archived session digests filtered by the search box: match project,
    // summary, model, branch, or agent so "what did I do in project X" works.
    var filteredHistory: [SessionRecord] {
        let q = historySearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return state.sessionHistory }
        return state.sessionHistory.filter { r in
            let hay = "\(r.project) \(r.summary ?? "") \(r.model) \(r.gitBranch ?? "") \(r.agent ?? "")"
                .lowercased()
            return hay.contains(q)
        }
    }

    // "What I shipped": one-click standup built from the session digests + git
    // commits over the chosen window, ready to paste into a standup or update.
    var standupSection: some View {
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

    func historyRow(_ r: SessionRecord) -> some View {
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
                        Text(f == 1 ? L("1 file", comment: "Count of files changed, singular")
                             : String(format: L("%d files", comment: "Count of files changed. %d is 2 or more"), f))
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

    func page<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.largeTitle.weight(.bold))
                Spacer(minLength: 12)
                versionBadge
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Which version you are on, and whether there is a newer one, opposite the
    /// page title.
    ///
    /// It lives in `page` rather than on the About page so it is answered on
    /// whichever page the window happens to open on. The space beside the title
    /// was empty on every one of them, and "am I up to date" was previously a
    /// trip to About to find out.
    @ViewBuilder
    private var versionBadge: some View {
        if let newer = state.availableUpdateVersion {
            Button {
                if let url = URL(string: UpdateChecker.shared.releasesPage) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(String(format: L("Update to v%@", comment: "Settings badge: a newer version is available. %@ is the version number"), newer))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .help(L("Open the releases page to download the new version", comment: "Tooltip on the update badge"))
        } else {
            Text(verbatim: "v\(Self.shortAppVersion)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                .help(L("The version you are running", comment: "Tooltip on the version badge"))
        }
    }

    func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .cardChrome()
    }

    var divider: some View {
        Divider().padding(.leading, 14)
    }

    /// A heading INSIDE a grouped list, for splitting one card into runs.
    /// sectionLabel sits between cards and would break the card in two here.
    func listHeading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10).padding(.bottom, 4).padding(.horizontal, 14)
    }

    /// Heading above a changelog group: the kind's word in its own colour, so
    /// Added and Fixed are told apart before a word is read.
    func changeGroupHeading(_ kind: ChangeGroup.Kind) -> some View {
        HStack(spacing: 5) {
            Image(systemName: kind.symbol).font(.caption2.weight(.bold))
            Text(kind.label.uppercased()).font(.caption.weight(.semibold))
        }
        .foregroundStyle(kind.tint)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(kind.label)
    }

    func sectionLabel(_ text: String) -> some View {
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

    func actionRow(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
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

    func row(_ title: String, _ subtitle: String?, _ isOn: Binding<Bool>) -> some View {
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

    func aboutLink(_ title: String, _ url: String) -> some View {
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

    /// Just the marketing version, for the badge. `appVersion` carries the
    /// build number too, which is noise at pill size.
    /// What to paste into a terminal to update. Written with ~ rather than an
    /// expanded home directory: shorter on screen, and it survives being
    /// pasted somewhere else.
    static let updateCommand = ProjectLinks.updateCommand

    static var shortAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

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

    /// Highlights for the current release, shown on the About page grouped by
    /// kind, the same way the website changelog groups them. Keep this in sync
    /// with the top changelog entry when cutting a release.
    static let whatsNew: [ChangeGroup] = [
        ChangeGroup(kind: .added, items: [
        "Update Now. Updating used to mean reading a command off the About page, copying it, finding a terminal and pasting it, which is why almost nobody did: the last two releases were security fixes and the download counts for them were zero and one. The button is in three places, all of them where the prompt already appeared: the card in the notch, the menu-bar alert, and Settings > About. It downloads, checks the file against the checksum published with the release, quits, replaces and relaunches. The notch card matters most, because most people never open the menu bar menu, and it used to say \u{201C}download it from the menu bar icon\u{201D} beside a button that offered to focus your editor.",
        ]),
        ChangeGroup(kind: .changed, items: [
        "The build is ready to be notarized the day there is an Apple Developer account to do it with. Right now macOS blocks the first launch and you have to allow it by hand, which is a poor introduction to a tool whose job is deciding what an AI may run on your Mac. Everything around it is wired: hardened runtime, stapling, and a check that Gatekeeper genuinely accepts the result before a build can ship. Nothing changes until the account exists.",
        ]),
    ]
}

/// One group of release notes, matching the website changelog's shape so the
/// About page and the site say the same thing in the same order.
struct ChangeGroup {
    enum Kind {
        case added, changed, fixed, removed

        var label: String {
            switch self {
            case .added:   return L("Added", comment: "Changelog group heading")
            case .changed: return L("Changed", comment: "Changelog group heading")
            case .fixed:   return L("Fixed", comment: "Changelog group heading")
            case .removed: return L("Removed", comment: "Changelog group heading")
            }
        }

        var symbol: String {
            switch self {
            case .added:   return "plus"
            case .changed: return "arrow.triangle.2.circlepath"
            case .fixed:   return "wrench.adjustable"
            case .removed: return "minus"
            }
        }

        /// Distinct hue per kind so a glance separates a new feature from a
        /// bug fix without reading the heading.
        var tint: Color {
            switch self {
            case .added:   return .green
            case .changed: return .blue
            case .fixed:   return .orange
            case .removed: return .red
            }
        }
    }

    let kind: Kind
    let items: [String]
}
