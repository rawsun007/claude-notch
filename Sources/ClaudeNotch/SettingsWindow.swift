import AppKit
import SwiftUI
import ServiceManagement

/// The ClaudeNotch settings window: a sidebar of sections and a detail pane of
/// grouped toggle rows, in the shape of a standard macOS System Settings window
/// (and boring.notch's). Everything binds to AppState's `setXxx` setters, which
/// already persist, so a flip here survives a relaunch just like the menu did.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    weak var appState: AppState?

    func show() {
        guard let appState else { return }
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: SettingsView(state: appState))
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
    case alerts = "Alerts"
    case sounds = "Sounds"
    case privacy = "Privacy"
    case about = "About"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .notch: return "menubar.rectangle"
        case .pet: return "pawprint"
        case .alerts: return "bell.badge"
        case .sounds: return "speaker.wave.2"
        case .privacy: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var section: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: Binding(
                get: { section },
                set: { if let v = $0 { section = v } }
            )) { s in
                Label(s.rawValue, systemImage: s.symbol)
                    .tag(s)
            }
            .navigationSplitViewColumnWidth(180)
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
        case .general: general
        case .notch:   notch
        case .pet:     pet
        case .alerts:  alerts
        case .sounds:  sounds
        case .privacy: privacy
        case .about:   about
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
        }
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
        }
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
        }
    }

    // MARK: building blocks

    private func page<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.largeTitle.weight(.bold))
            content()
        }
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
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
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 8)
        }
        .toggleStyle(.switch)
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
