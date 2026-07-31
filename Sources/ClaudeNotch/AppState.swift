import Foundation
import AppKit
import UniformTypeIdentifiers

// The single source of truth the UI reads. This file holds the settings enums
// and the stored state itself; the behaviour that reads and mutates that state
// lives in the AppState+*.swift extensions (pet, usage, budget, git, task
// meter, sessions, compose, history, export, queues, alerts, sound). The value
// types moved to SessionModels / UsageModels / RequestModels.

/// An individual item that can appear in the always-visible bottom status bar.
/// The user picks up to two. Order is preserved (first item on the left).
/// Groups tools into a handful of categories, each with its own alert sound
/// when "Per-tool sounds" is on. Users can override the default per category.
enum ToolSoundCategory: String, CaseIterable, Identifiable {
    case bash, edit, write, notification, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bash:         return "Shell commands"
        case .edit:         return "Edits"
        case .write:        return "New files"
        case .notification: return "Notifications"
        case .other:        return "Everything else"
        }
    }

    var detail: String {
        switch self {
        case .bash:         return "Bash"
        case .edit:         return "Edit, MultiEdit"
        case .write:        return "Write, NotebookEdit"
        case .notification: return "Notification prompts"
        case .other:        return "All other tools"
        }
    }

    var defaultSound: String {
        switch self {
        case .bash:         return "Funk"
        case .edit:         return "Pop"
        case .write:        return "Tink"
        case .notification: return "Submarine"
        case .other:        return "Funk"
        }
    }

    static func category(for tool: String) -> ToolSoundCategory {
        switch tool {
        case "Bash":                  return .bash
        case "Edit", "MultiEdit":     return .edit
        case "Write", "NotebookEdit": return .write
        case "Notification":          return .notification
        default:                      return .other
        }
    }
}

enum StatusBarItem: String, Codable, CaseIterable {
    case fiveHourLimit  // real 5-hour plan-limit usage % (from Claude Code statusLine)
    case weeklyLimit    // real weekly plan-limit usage %
    case sessionCost    // estimated current-session $ cost

    var barLabel: String {
        switch self {
        case .fiveHourLimit: return "5H"
        case .weeklyLimit:   return "WK"
        case .sessionCost:   return "$"
        }
    }

    var menuLabel: String {
        switch self {
        case .fiveHourLimit: return "5h plan limit"
        case .weeklyLimit:   return "Weekly plan limit"
        case .sessionCost:   return "Session cost (estimated $)"
        }
    }
}

enum NotchMode: Equatable {
    case idle
    case thinking(label: String)
    case permission(PermissionRequest)
    case completed(CompletedTask)
    case question(QuestionRequest)
    case compose
    case responseDetail
    case history
    case autoInfo(PermissionRequest)   // auto-approved: show what changed, no buttons
}


enum NotchTitleMode: String, Codable, CaseIterable {
    case claude, project, custom
}

@MainActor
final class AppState: ObservableObject {
    static let statusEntityName = "Claude"

    // Notch title personalisation (issue #6). Persisted.
    @Published var notchTitleMode: NotchTitleMode = .claude
    @Published var customNotchTitle: String = ""

    /// The label shown as the first segment of the notch title, resolved from
    /// the user's preference. Falls back to "Claude" when the chosen source is
    /// empty (no active project, or a blank custom string).
    var entityName: String {
        switch notchTitleMode {
        case .claude:
            // Agent-aware, derived from the ACTIVE SESSIONS (not currentModel,
            // which only Claude's status line sets — a Codex-only session would
            // otherwise read "Claude"). All one agent -> its name; mixed agents
            // -> the neutral app name so we never claim a single wrong agent.
            let agents = Set(activeSessions.compactMap {
                $0.model.isEmpty ? nil : AgentKind.infer(fromModel: $0.model)
            })
            if agents.count > 1 { return "ClaudeNotch" }
            if let only = agents.first { return only.notchLabel }
            return currentModel.isEmpty ? Self.statusEntityName
                                        : AgentKind.infer(fromModel: currentModel).notchLabel
        case .project:
            return currentProject.isEmpty ? Self.statusEntityName : currentProject
        case .custom:
            let t = customNotchTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? Self.statusEntityName : t
        }
    }

    func setNotchTitleMode(_ mode: NotchTitleMode) {
        notchTitleMode = mode
        schedulePersist()
    }

    /// Set the custom label and switch to custom mode in one step (used by the
    /// "Custom…" menu input and onboarding). A blank string reverts to the
    /// default.
    func setCustomNotchTitle(_ s: String) {
        customNotchTitle = s.trimmingCharacters(in: .whitespacesAndNewlines)
        notchTitleMode = customNotchTitle.isEmpty ? .claude : .custom
        schedulePersist()
    }

    /// Set ONLY the custom title text, leaving the mode alone. Used by the
    /// Settings field, which has its own mode picker: switching the mode there
    /// must not be undone just because the field is momentarily empty (that made
    /// the field disappear mid-edit). Stored raw; callers trim at display time.
    func setCustomTitleText(_ s: String) {
        customNotchTitle = s
        schedulePersist()
    }

    @Published var mode: NotchMode = .idle
    // Hard ceiling on the pending queues. Each entry is a card awaiting a
    // decision; a real user never has more than a handful outstanding. The cap
    // exists so a misbehaving (or hostile) local process spraying blocking hooks
    // can't grow these without bound. Trimming keeps the newest, dropping the
    // stalest, so the cards you'd actually act on survive.
    private let queueMax = 64
    @Published var permissionQueue: [PermissionRequest] = [] {
        didSet { if permissionQueue.count > queueMax { permissionQueue = Self.capFront(permissionQueue, to: queueMax) } }
    }
    @Published var completedQueue: [CompletedTask] = [] {
        didSet { if completedQueue.count > queueMax { completedQueue = Self.capFront(completedQueue, to: queueMax) } }
    }
    @Published var questionQueue: [QuestionRequest] = [] {
        didSet { if questionQueue.count > queueMax { questionQueue = Self.capFront(questionQueue, to: queueMax) } }
    }

    /// The newest `max` entries of `arr`, dropping the stalest (front) when it
    /// overruns. The payload-fed queues share this so one misbehaving (or
    /// hostile) local process spraying blocking hooks can't grow them unbounded.
    /// The didSets guard the assignment with a count check so the trimmed value
    /// (now at `max`) doesn't re-enter the @Published setter and recurse.
    nonisolated static func capFront<T>(_ arr: [T], to max: Int) -> [T] {
        arr.count > max ? Array(arr.suffix(max)) : arr
    }
    @Published var allowRules: Set<AllowRule> = []
    @Published var isHovering: Bool = false
    /// True while a file or folder is being dragged over the notch, so the card
    /// can open into a black drop panel showing the drop zone.
    @Published var isDropTarget: Bool = false
    /// True while the drag is right over the drop-zone icon itself (the inner
    /// target), so it can glow green as a "let go here" cue. Blue otherwise.
    @Published var isDropHot: Bool = false

    /// A file or folder was dropped on the notch: open a Claude Code session
    /// where it lives. A folder opens Claude in that folder; a file opens Claude
    /// in its parent folder and hands the file straight to Claude as an @-mention,
    /// so a dropped file lands you in a session already looking at it.
    private var lastDropLaunch: Date = .distantPast
    /// Hover is ignored until this time — set just after a drop so the notch does
    /// not immediately re-open under the still-parked cursor.
    var suppressHoverUntil: Date = .distantPast
    func handleDrop(urls: [URL]) {
        isDropTarget = false
        isDropHot = false
        guard let url = urls.first,
              let launch = Self.dropLaunch(for: url, isDirectory: Self.isDirectory(url)) else {
            return
        }
        // A single drop can be delivered more than once (the async provider load
        // resolves multiple representations of one folder, or the delegate fires
        // twice), which was opening Claude in two terminals. Debounce: ignore a
        // second launch within a second of the last.
        let now = Date()
        guard now.timeIntervalSince(lastDropLaunch) > 1.0 else { return }
        lastDropLaunch = now
        // Right after a drop the cursor is still sitting over the notch, so the
        // hover check would instantly re-open it as the normal status card — the
        // notch flickered open/closed twice. Suppress hover briefly so the drop
        // panel just closes cleanly.
        suppressHoverUntil = now.addingTimeInterval(0.7)
        isHovering = false
        // Only ask which agent when Codex is actually enabled. Otherwise this is
        // plain Claude ClaudeNotch: a drop just opens Claude Code, no prompt.
        guard HookInstaller.isCodexInstalled else {
            TerminalAutomator.startClaude(in: launch.dir, message: launch.message)
            return
        }
        let dir = launch.dir, message = launch.message
        let folder = (dir as NSString).lastPathComponent
        let q = AskQuestion(
            header: "Open folder",
            text: "Open “\(folder)” in which agent?",
            multiSelect: false,
            options: [AskOption(label: "Claude Code", description: ""),
                      AskOption(label: "Codex", description: "")])
        enqueueQuestion(QuestionRequest(questions: [q], source: "ClaudeNotch", cwd: dir, resolver: { [weak self] answers in
            let pick = answers?.first?.first ?? ""
            Task { @MainActor in
                guard let self else { return }
                // Don't let the notch reactivate the previous (maybe full-screen)
                // app; we're opening a terminal on the current Space instead.
                self.suppressReturnToApp = true
                if pick == "Codex" { TerminalAutomator.startCodex(in: dir) }
                else if pick == "Claude Code" { TerminalAutomator.startClaude(in: dir, message: message) }
                else { self.suppressReturnToApp = false }   // cancelled: normal focus return
            }
        }))
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Where to open Claude for a dropped path, and what to say. A folder opens a
    /// session there; a file opens one in its parent and hands the file to Claude
    /// as an @-mention, so you land already looking at it. Pure and testable.
    nonisolated static func dropLaunch(for url: URL, isDirectory: Bool) -> (dir: String, message: String?)? {
        guard !url.path.isEmpty else { return nil }
        if isDirectory { return (url.path, nil) }
        return (url.deletingLastPathComponent().path, "@\(url.lastPathComponent)")
    }

    // User preferences (persisted).
    @Published var autoApprove: Bool = false   // auto-allow every permission
    @Published var soundMuted: Bool = false     // silence all notch sounds

    // Usage stats — all-time (persisted) + this-session (in-memory).
    @Published var stats = UsageStats()
    var sessionTools = 0
    var sessionAllowed = 0
    var sessionDenied = 0

    // Timed auto-approve: when set, auto-approve turns itself off at this time.
    // Not persisted, so a restart always reverts to the permanent toggle.
    @Published var autoApproveUntil: Date? = nil
    var autoApproveTimer: Timer?

    // Snooze: suppress non-blocking cards (notification + completed) until this
    // time. Blocking permission cards always show — Claude is waiting on them.
    @Published var snoozedUntil: Date? = nil
    var snoozeTimer: Timer?
    var isSnoozed: Bool {
        if let until = snoozedUntil { return until > Date() }
        return false
    }

    // Sound preferences (persisted).
    @Published var alertSound: String = "Funk"
    @Published var perToolSounds: Bool = false
    /// Per-category sound overrides (category key -> sound name). Empty entries
    /// fall back to ToolSoundCategory.defaultSound. Persisted.
    @Published var perToolSoundMap: [String: String] = [:]
    @Published var persistentNotchDisplay: Bool = false
    // Pet mode: the idle icon is the animated Claude Code mascot, and it lives
    // its own little life in and around the notch while the notch is at rest.
    // Behaviour and pose come from PetEngine; this class only owns the clock,
    // the interaction inputs, and the gate that keeps the pet out of the way.
    @Published var petEnabled: Bool = true
    /// Whether the pet performs on its OWN, unprompted (the random idle antics).
    /// Off keeps the pet — it still answers a boop and still reacts to a turn
    /// finishing or failing — but it never starts a performance by itself.
    @Published var petRandomEnabled: Bool = true
    @Published var petActivity: PetActivity = .tucked
    /// Cursor offset from the notch's centre in points, clamped by MouseTracker.
    /// Drives the pet's lean and which way it faces.
    @Published var petCursorX: Double = 0
    /// The cursor is resting on the pet: hold it out and give it a heart.
    @Published var petPetting: Bool = false {
        didSet { if petPetting, !oldValue { petPettingSince = Date() } }
    }
    /// A finished task makes the pet celebrate — but only briefly, so a task
    /// that finished ten minutes ago doesn't leave it hopping forever.
    var petCelebrateUntil: Date = .distantPast
    /// The pet is startled until this instant (a turn died, or you said no).
    var petStartleUntil: Date = .distantPast
    var petActivityStart: Date = .distantPast
    var petActivityDuration: Double = 0
    /// Seconds the current activity spent frozen under the user's cursor.
    /// Subtracted from elapsed time so petting genuinely pauses the timeline.
    var petHeldSeconds: Double = 0
    var petPettingSince: Date?
    /// When the pet is next allowed to do something unprompted.
    var petNextActionAt: Date = .distantPast
    /// A boop interrupts whatever was happening; this is what to go back to.
    var petInterrupted: (activity: PetActivity, elapsed: Double)?
    /// Boops landed in quick succession. Enough of them and the pet backflips.
    var petBoopStreak = 0
    var petLastBoopAt: Date = .distantPast
    var petTimer: Timer?
    /// Demo mode: an activity was requested from the Demos menu, so it plays
    /// even while Claude is busy (the whole point is to watch it on demand).
    var petDemoing = false
    var petDemoQueue: [PetActivity] = []
    var petRNG = SeededRNG(seed: UInt64(Date().timeIntervalSince1970.bitPattern))
    // Require Touch ID / Face ID to confirm a dangerous command (instead of
    // press-and-hold). Defaults on when the Mac has biometrics. Persisted.
    @Published var requireTouchID: Bool = false

    // Mirror blocking permission cards to native macOS notifications so they're
    // actionable from the lock screen / another Space, and auto-respect Focus
    // (the OS suppresses banners during Do Not Disturb). Persisted; on by
    // default. The concrete bridge is wired in by AppDelegate at launch.
    @Published var mirrorToNotificationCenter: Bool = true
    @Published var completionNotificationsEnabled: Bool = false
    @Published var digestNotificationsEnabled: Bool = false
    // Exclude the notch window from screen captures (shares, recordings,
    // other apps' screenshots). The notch shows commands, file paths, and
    // code snippets — none of which belong in a Zoom call. Default on.
    @Published var hideFromScreenCapture: Bool = true
    // Append today's estimated spend to the menu bar icon. Off by default.
    @Published var showSpendInMenuBar: Bool = false
    weak var permissionMirror: PermissionMirroring?

    // Daily digest tracking — only shown once per day.
    @Published var lastDigestDate: String? = nil
    // Weekly digest tracking — ISO week key, shown once per week.
    @Published var lastWeeklyDigestDate: String? = nil

    // Which agent a folder dropped on the notch launches. Default Claude.
    @Published private(set) var dropStartsCodex: Bool = false
    func setDropStartsCodex(_ on: Bool) { dropStartsCodex = on; schedulePersist() }

    // Update-available notch card: shown once per discovered version, so the
    // daily poll doesn't re-card users who chose to ignore an update.
    var lastUpdateCardVersion: String? = nil

    // Version the user last ran — drives the one-time What's New card after
    // an update. Maintained per release alongside the changelog.
    var lastSeenVersion: String? = nil
    static let whatsNewHighlights =
        "Settings is fully translated in all ten languages now, explanations included"

    /// Transient "live activity" card shown after an auto-approved action —
    /// shows WHAT changed, no buttons, auto-dismisses.
    @Published var autoInfo: PermissionRequest? = nil
    var autoInfoTimer: Timer?
    var lastAutoSoundAt: Date = .distantPast

    // Top inset of the screen the notch is rendering on. The window controller
    // updates this so the card's top padding matches the current display
    // (built-in notch ≈ 37pt; external display 0). Prevents a black gap at
    // the top of the card on external monitors.
    @Published var notchTopInset: CGFloat = NotchView.notchInset(on: NSScreen.main)

    // Live session info — populated from every hook payload.
    @Published var currentProject: String = ""        // basename of cwd
    @Published var currentCwd: String = ""
    // Which session the global mirror (lastClaudeResponse, claudeActionStatus,
    // etc.) currently reflects. Only this session may write the mirror, so a
    // background session's transcript poll — or a closed session whose poll is
    // still winding down — can't thrash the collapsed header every tick.
    /// The session the notch header is describing. Readable so the session LIST
    /// can avoid repeating what the header already says about it.
    var currentSessionId: String = ""
    @Published var lastActivity: String = ""          // "Bash: ls -la" etc.
    @Published var lastUserPrompt: String = ""
    @Published var recentProjects: [String] = []      // ordered, deduped cwds (newest first)
    // Project directories the user pinned to the top of the sessions list.
    @Published var pinnedProjects: Set<String> = []
    // User-given names/notes for sessions, keyed by session id.
    @Published var sessionNotes: [String: String] = [:]
    @Published var lastOriginatorBundleID: String? = nil
    @Published var lastHookAt: Date? = nil
    @Published var lastClaudeResponse: String = ""        // truncated for hover
    @Published var fullClaudeResponse: String = ""        // up to 8000 chars
    @Published var lastClaudeResponseAt: Date? = nil
    @Published var lastActivityAt: Date? = nil
    @Published var claudeActionStatus: String = "ready"
    // Global mirror of the current session's context + cost meter (for the
    // collapsed header). Per-session values live on each LiveSession.
    @Published var currentContextPercent: Double = 0
    @Published var currentContextTokens: Int = 0
    @Published var currentCostUSD: Double = 0
    @Published var currentModel: String = ""
    @Published var currentPermissionMode: String = ""
    // Newer release version when the update checker has found one, else nil.
    // Drives the in-app update banner in Settings. Transient (not persisted).
    @Published var availableUpdateVersion: String?

    /// Task-list progress for what the notch should show: the current session's
    /// counts, or, when there is no clear current session, whichever live
    /// session has the most tasks. (done, total); total 0 means "no task list".
    var currentTaskProgress: (done: Int, total: Int) {
        if !currentSessionId.isEmpty, let s = sessions[currentSessionId], s.taskTotal > 0 {
            return (s.taskDone, s.taskTotal)
        }
        if let s = sessions.values.filter({ $0.taskTotal > 0 }).max(by: { $0.taskTotal < $1.taskTotal }) {
            return (s.taskDone, s.taskTotal)
        }
        return (0, 0)
    }

    /// Strictly the current (top) session's task list, with no busiest fallback.
    /// The top task bar uses this so it never borrows a secondary session's
    /// list (which already shows its own bar in the list below).
    var currentSessionTaskProgress: (done: Int, total: Int) {
        guard !currentSessionId.isEmpty, let s = sessions[currentSessionId] else { return (0, 0) }
        return (s.taskDone, s.taskTotal)
    }

    /// The session shown at the top of the notch: the most-recently-active one
    /// (max lastHookAt), i.e. whatever is running right now. Rendering the top
    /// card from THIS single object keeps its model, context, cost, branch and
    /// effort coherent, instead of mixing the drifting global mirrors that get
    /// overwritten by whichever agent fired last (Codex model + Claude cost).
    var primarySession: LiveSession? {
        sessions.values.max { $0.lastHookAt < $1.lastHookAt }
    }

    /// The top (primary) session's task list.
    var primaryTaskProgress: (done: Int, total: Int) {
        guard let s = primarySession else { return (0, 0) }
        return (s.taskDone, s.taskTotal)
    }

    /// Lines this session has added/removed, from the current session (or the
    /// busiest live session when there is no clear current one). (0,0) means
    /// nothing changed yet or the status line hasn't reported it.
    var currentDiffStat: (added: Int, removed: Int) {
        if !currentSessionId.isEmpty, let s = sessions[currentSessionId], (s.linesAdded + s.linesRemoved) > 0 {
            return (s.linesAdded, s.linesRemoved)
        }
        if let s = sessions.values.max(by: { ($0.linesAdded + $0.linesRemoved) < ($1.linesAdded + $1.linesRemoved) }),
           (s.linesAdded + s.linesRemoved) > 0 {
            return (s.linesAdded, s.linesRemoved)
        }
        return (0, 0)
    }

    /// Lines added/removed across everything worked on today: archived sessions
    /// that started today plus every live session (which is, by definition,
    /// today's work). Drives the Usage "code churn today" tile.
    var churnToday: (added: Int, removed: Int) {
        let cal = Calendar.current
        var added = 0, removed = 0
        for r in sessionHistory where cal.isDateInToday(r.startedAt) && sessions[r.sessionKey] == nil {
            added += r.linesAdded ?? 0
            removed += r.linesRemoved ?? 0
        }
        for s in sessions.values {
            added += s.linesAdded
            removed += s.linesRemoved
        }
        return (added, removed)
    }

    /// Whether the current session's displayed cost is Claude Code's own
    /// reported figure (true) or the app's transcript estimate (false).
    var currentCostIsReported: Bool {
        guard !currentSessionId.isEmpty, let s = sessions[currentSessionId] else { return false }
        return s.reportedCostUSD > 0
    }

    // Cost budgets (USD, estimated from public pricing). 0 = off. Persisted.
    // sessionCostCap warns on any single session; dailyCostCap on today's total.
    @Published var sessionCostCap: Double = 0
    @Published var dailyCostCap: Double = 0
    // Status-bar caps for the rolling 5-hour and weekly usage bars, used in
    // `.estimatedCost` mode. Non-zero enables the bar.
    @Published var fiveHourCostCap: Double = 5.0
    @Published var weeklyCostCap: Double = 50.0
    // Which items appear in the bottom status bar (ordered, max 2). Persisted.
    @Published var statusBarItems: [StatusBarItem] = [.fiveHourLimit, .weeklyLimit]
    // Context-window denominator selection (Auto / 200K / 1M). Persisted.
    @Published var contextWindowMode: ContextWindowMode = .auto
    // Real plan-limit usage (0...1), fed by Claude Code's statusLine input via
    // the /statusline route. -1 = no data yet (so the UI can show "—").
    @Published var fiveHourLimitPercent: Double = -1
    @Published var weeklyLimitPercent: Double = -1
    /// When each limit window resets. Reported by Claude Code's status line; nil
    /// until one arrives (and for anyone not on a subscription plan).
    @Published var fiveHourResetAt: Date?
    @Published var weeklyResetAt: Date?
    /// Warn as a plan limit fills, so hitting it is not a surprise mid-task. On
    /// by default: this is protective and rare (it fires at most twice per window,
    /// at 80% and 95%), the kind of thing you want without opting in.
    /// Whether a finished task is judged against what the turn actually did.
    /// Off by default: it is an opinion about someone's work, and an opinion
    /// nobody asked for is noise. Opt in from Settings > Session.
    @Published var completionAuditEnabled: Bool = false

    func setCompletionAuditEnabled(_ on: Bool) {
        completionAuditEnabled = on
        schedulePersist()
    }

    @Published var rateLimitWarningsEnabled: Bool = true

    /// Language override for the notch's own text. Empty follows macOS. Lives
    /// in UserDefaults rather than the state snapshot because Localization
    /// reads it from outside the main actor, and publishing it here is what
    /// makes the open cards redraw the moment it changes.
    @Published var appLanguage: String = Localization.languageCode

    func setAppLanguage(_ code: String) {
        Localization.languageCode = code
        appLanguage = code
    }

    // Oldest reading of each limit window still worth extrapolating from,
    // together with the reset instant identifying the window it belongs to.
    // A projection must never be drawn across two different windows.
    var fiveHourAnchor: (sample: BurnRate.Sample, window: Date?)?
    var weeklyAnchor: (sample: BurnRate.Sample, window: Date?)?
    /// How long until each limit runs out at the current rate. Nil when there
    /// is nothing trustworthy to say, which is most of the time.
    @Published var fiveHourForecast: BurnRate.Forecast?
    @Published var weeklyForecast: BurnRate.Forecast?
    nonisolated static let rateLimitThresholds: [Double] = [0.80, 0.95]
    /// The highest threshold already warned for in the current window, keyed by
    /// that window's reset instant so a fresh window re-arms.
    var fiveHourWarned: (reset: Date?, level: Double) = (nil, 0)
    var weeklyWarned: (reset: Date?, level: Double) = (nil, 0)

    func setRateLimitWarningsEnabled(_ on: Bool) {
        rateLimitWarningsEnabled = on
        schedulePersist()
    }

    /// The threshold to warn at, or nil, for a given usage and what has already
    /// been warned this window. Pure so the arming rule is testable.
    nonisolated static func rateLimitWarning(pct: Double, alreadyWarned: Double) -> Double? {
        rateLimitThresholds.last { pct >= $0 && $0 > alreadyWarned }
    }

    func checkRateLimit(name: String, pct: Double, resetAt: Date?,
                                armed: inout (reset: Date?, level: Double)) {
        guard rateLimitWarningsEnabled else { return }
        // A new window (different reset instant) re-arms every threshold.
        if armed.reset != resetAt { armed = (resetAt, 0) }
        guard let level = Self.rateLimitWarning(pct: pct, alreadyWarned: armed.level) else { return }
        armed.level = level
        let left = resetAt.map { " · resets in \(ClaudeUsageReader.resetCountdown(until: $0))" } ?? ""
        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: "\(Int(level * 100))% of your \(name) limit used",
            detail: "You are at \(Int(pct * 100))% of the \(name) plan limit\(left).",
            toolName: "RateLimit", source: "ClaudeNotch", cwd: currentCwd,
            originatorBundleID: nil, resolver: { _, _ in }))
    }

    /// When the limits above were last reported.
    ///
    /// They only arrive while a Claude session is actively redrawing its status
    /// line, so between sessions (and after the app restarts) the newest reading
    /// we have can be hours old. Showing an hours-old percentage as though it
    /// were current is how the notch ended up disagreeing with `/usage`, so the
    /// age is kept and shown.
    @Published var limitsUpdatedAt: Date?
    // Hard-stop: when on, a tool request whose session/daily cap is already
    // exceeded is held for a decision (Deny / Allow once / Raise cap) instead
    // of being auto-allowed — even under an allow-rule or auto-approve. Off by
    // default (it actively blocks Claude). Persisted.
    @Published var enforceBudget: Bool = false
    // Today's total estimated cost across all sessions, pushed from EventServer.
    @Published var todayCostUSD: Double = 0
    // Rolling 5-hour and weekly cost totals, recomputed alongside todayCostUSD.
    @Published var fiveHourCostUSD: Double = 0
    @Published var weeklyCostUSD: Double = 0
    // Effort level read from ~/.claude/settings.json ("Auto", "Normal", "High", "Low").
    @Published var currentEffort: String = "Auto"
    // Debounce warnings so a meter that keeps updating doesn't re-alert. Levels
    // are 0 / 80 / 100; in-memory only (re-arming on restart is fine).
    var sessionWarnLevel: [String: Int] = [:]
    var dailyWarnLevel: Int = 0
    var dailyWarnDate: String = ""

    // Per-session live state. Keyed by session_id (or normalized cwd when a
    // hook didn't carry one). The global fields above stay as a mirror of the
    // most-recent session so existing UI keeps working unchanged.
    @Published var sessions: [String: LiveSession] = [:]
    let sessionsMax = 12

    @Published var composeText: String = ""
    @Published var isComposing: Bool = false
    @Published var composePurpose: ComposePurpose = .message
    @Published var composeTarget: String? = nil
    // Human label for what we're sending to (e.g. the session's project), shown
    // in the composer header. Set for replies; nil for a plain hotkey compose.
    @Published var composeContextLabel: String? = nil
    @Published var composeError: String? = nil
    // When set, "send" opens a NEW terminal in this project's folder running
    // `claude "<message>"`, instead of typing into the active terminal.
    @Published var composeProjectCwd: String? = nil
    @Published var isResponseDetailOpen: Bool = false
    // The reply currently shown in the detail view — set from either the global
    // last reply or a tapped session row, so the card can render whichever.
    @Published var detailResponseText: String = ""
    @Published var detailProject: String = ""
    @Published var isHistoryOpen: Bool = false

    // Click-to-expand history drawer (most recent first, ring-buffered).
    // 500 entries ≈ 100 KB of state.json — cheap enough to keep a real
    // scroll-back log instead of evaporating after a handful of decisions.
    @Published var history: [HistoryEntry] = []
    let historyMax = 500

    // Completed-session summaries (newest first, ring-buffered).
    @Published var sessionHistory: [SessionRecord] = []
    let sessionHistoryMax = 200
    var archivedSessionKeys: Set<String> = []

    // After this many seconds without a hook, drop the activity line.
    let activityStaleAfter: TimeInterval = 90
    // After this many seconds without a hook, also drop the project name
    // (the terminal is most likely closed).
    let projectStaleAfter: TimeInterval = 300
    var staleTimer: Timer?

    // Debounced write to ~/.claudenotch/state.json — coalesces bursts of
    // mutations (e.g. many history appends in a row) into one disk write.
    var persistTimer: Timer?

    init() {
        if let snapshot = Persistence.load() {
            self.history = snapshot.history
            // Sweep out the sessions the old archive rule let in: rows where
            // Claude never spent a token, never cost anything and never touched a
            // file. They are hook noise, not history, and they drag the project
            // stats around with them.
            self.sessionHistory = (snapshot.sessionHistory ?? []).filter(Self.isWorthKeeping)
            self.archivedSessionKeys = Set(self.sessionHistory.map(\.sessionKey))
            self.allowRules = snapshot.allowRules
            self.recentProjects = snapshot.recentProjects
            self.pinnedProjects = Set(snapshot.pinnedProjects ?? [])
            self.sessionNotes = snapshot.sessionNotes ?? [:]
            self.autoApprove = snapshot.autoApprove ?? false
            self.soundMuted = snapshot.soundMuted ?? false
            self.stats = snapshot.stats ?? UsageStats()
            self.alertSound = snapshot.alertSound ?? "Funk"
            self.perToolSounds = snapshot.perToolSounds ?? false
            self.completionAuditEnabled = snapshot.completionAuditEnabled ?? false
            self.perToolSoundMap = snapshot.perToolSoundMap ?? [:]
            self.persistentNotchDisplay = snapshot.persistentNotchDisplay ?? false
            self.petEnabled = snapshot.petEnabled ?? true
            self.petRandomEnabled = snapshot.petRandomEnabled ?? true
            self.lastDigestDate = snapshot.lastDigestDate
            self.lastWeeklyDigestDate = snapshot.lastWeeklyDigestDate
            self.dropStartsCodex = snapshot.dropStartsCodex ?? false
            self.lastUpdateCardVersion = snapshot.lastUpdateCardVersion
            self.lastSeenVersion = snapshot.lastSeenVersion
            self.sessionCostCap = snapshot.sessionCostCap ?? 0
            self.dailyCostCap = snapshot.dailyCostCap ?? 0
            self.fiveHourCostCap = snapshot.fiveHourCostCap ?? 5.0
            self.weeklyCostCap = snapshot.weeklyCostCap ?? 50.0
            self.enforceBudget = snapshot.enforceBudget ?? false
            self.requireTouchID = snapshot.requireTouchID ?? BiometricAuth.isAvailable
            self.mirrorToNotificationCenter = snapshot.mirrorToNotificationCenter ?? true
            self.completionNotificationsEnabled = snapshot.completionNotificationsEnabled ?? false
            self.digestNotificationsEnabled = snapshot.digestNotificationsEnabled ?? false
            self.hideFromScreenCapture = snapshot.hideFromScreenCapture ?? true
            self.showSpendInMenuBar = snapshot.showSpendInMenuBar ?? false
            self.statusBarItems = snapshot.statusBarItems?
                .compactMap(StatusBarItem.init) ?? [.fiveHourLimit, .weeklyLimit]
            self.contextWindowMode = snapshot.contextWindowMode.flatMap(ContextWindowMode.init) ?? .auto
            self.notchTitleMode = snapshot.notchTitleMode.flatMap(NotchTitleMode.init) ?? .claude
            self.customNotchTitle = snapshot.customNotchTitle ?? ""
            self.learnedContextWindows = snapshot.learnedContextWindows ?? [:]
            self.fiveHourLimitPercent = snapshot.fiveHourLimitPercent ?? -1
            self.weeklyLimitPercent = snapshot.weeklyLimitPercent ?? -1
            self.fiveHourResetAt = snapshot.fiveHourResetAt
            self.weeklyResetAt = snapshot.weeklyResetAt
            self.limitsUpdatedAt = snapshot.limitsUpdatedAt
            self.breakRemindersEnabled = snapshot.breakRemindersEnabled ?? false
            self.longRunAlertsEnabled = snapshot.longRunAlertsEnabled ?? false
            self.rateLimitWarningsEnabled = snapshot.rateLimitWarningsEnabled ?? true
        } else {
            self.requireTouchID = BiometricAuth.isAvailable
        }
        // Seed model and effort immediately from settings so Row 2 is visible
        // before the first hook fires, in both persistent and normal modes.
        let seededModel = ClaudeUsageReader.modelFromSettings()
        if !seededModel.isEmpty { self.currentModel = seededModel }
        self.currentEffort = ClaudeUsageReader.effortFromSettings()

        // What's New: first launch on a new version shows the highlights once.
        // A nil lastSeenVersion means fresh install — onboarding covers that.
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        let previous = lastSeenVersion
        if !current.isEmpty, current != previous {
            lastSeenVersion = current
            schedulePersist()
            if let prev = previous, prev != current {
                // Delay so the notch window exists and the card animates in
                // instead of appearing mid-launch.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    self?.showWhatsNewCard(version: current)
                }
            }
        }
        startPetDriver()
    }

    // MARK: - Pet mode state (logic lives in AppState+Pet.swift)

    /// What PetEngine is allowed to know about the app right now.
    var petContext: PetEngine.Context {
        var ctx = PetEngine.Context()
        if case .idle = mode { ctx.isIdleMode = true } else { ctx.isIdleMode = false }
        ctx.isHovering = isHovering
        ctx.persistentDisplay = persistentNotchDisplay
        ctx.isWorking = isClaudeWorking && claudeActionStatus != "thinking"
        ctx.isThinking = claudeActionStatus == "thinking"
        ctx.justFinished = Date() < petCelebrateUntil
        ctx.justFailed = Date() < petStartleUntil
        ctx.secondsSinceActivity = lastHookAt.map { Date().timeIntervalSince($0) } ?? PetEngine.sleepAfter
        return ctx
    }

    /// The Spider-Pet's entrance music. Held as a property because a local NSSound
    /// is deallocated the instant the call returns, which cuts it off before a
    /// note plays. Respects the same mute as every other sound.
    var spiderSound: NSSound?

    /// True once Claude Code has reported the live effort for this session.
    var effortIsLive = false

    /// The context window Claude Code says it is measuring the current session
    /// against. 0 until a status line has been seen.
    @Published var currentContextWindow: Int = 0

    /// Windows reported by Claude Code, keyed by model id. Persisted, so a fresh
    /// session starts with the true window rather than an inference.
    // Cap on distinct models we'll remember a window for. Real installs see a
    // handful; the ceiling stops an untrusted model string from growing the
    // persisted map without bound.
    let learnedWindowsMax = 64
    @Published var learnedContextWindows: [String: Int] = [:]

    // MARK: - Git branch state (logic lives in AppState+Git.swift)

    // Branch per cwd, re-read at most every 15 s — the file is tiny but hooks
    // arrive every second for an active session.
    var branchCache: [String: (branch: String, readAt: Date)] = [:]

    /// Open a file the agent edited, but never *launch* it. The path comes from
    /// a hook payload, so opening it with the default handler would run a crafted
    /// executable/script/app on a click. If the target is a bundle, has the
    /// execute bit, or carries a runnable extension, reveal it in Finder instead
    /// of opening it; ordinary source files open as before.
    /// Extensions whose default handler takes an action on a plain double-click
    /// rather than just displaying the file — so opening one the agent named is
    /// a launch, not a view. Bundles (.app/.workflow/.scptd) are caught
    /// separately by the is-directory check; this list is the non-bundle set.
    nonisolated static let riskyOpenExtensions: Set<String> = [
        "command", "sh", "bash", "zsh", "app", "pkg", "dmg",
        "scpt", "applescript", "workflow", "term", "terminal",
        "shortcut", "js", "jar", "run", "bin", "out", "action", "prefpane",
        // Data files whose default handler takes a dangerous action on open
        // (not caught by the execute-bit check): a config profile install, or a
        // link file that opens an arbitrary URL / custom-scheme handler.
        "mobileconfig", "webloc", "url", "desktop",
    ]

    /// When the tool named in `lastActivity` started running. Nil when nothing
    /// is running. This is what lets the notch answer the question every long
    /// agent run raises: is it still doing something, and for how long?
    @Published var activityStartedAt: Date?

    // Statuses a session rests in once a turn ends — don't let late transcript
    // polling drag a finished session back into a pulsing "replying" state.
    static let terminalSessionStatuses: Set<String> = ["done", "last reply", "ready"]

    /// Drops hooks that arrive after their turn already ended — see TurnGate.
    var turnGate = TurnGate()

    /// Break reminders. Off by default: an unasked-for interruption is the thing
    /// people switch off first, and once it is off you lose every later one too.
    @Published var breakRemindersEnabled: Bool = false
    var focus = FocusTracker()

    /// Warn when a single tool call has been running a long time. Off by default,
    /// like every other unprompted nudge. This is the answer to the one thing the
    /// whole notch-app ecosystem keeps asking for — "is this long agent run stuck"
    /// — without your having to watch the notch: it fires once, past the
    /// threshold, and does not fire again until a NEW tool call goes long.
    @Published var longRunAlertsEnabled: Bool = false
    static let longRunThreshold: TimeInterval = 5 * 60
    /// The activityStartedAt we have already alerted for, so one stuck tool alerts
    /// once rather than every heartbeat.
    var longRunAlertedFor: Date?

    /// Background agents the Claude Code daemon is currently running.
    ///
    /// They already reach the app as sessions (their hooks fire like any other),
    /// but nothing distinguished them from a session you are sitting in front of,
    /// and a background agent is precisely the thing you are NOT looking at.
    @Published var backgroundAgents: [BackgroundAgent] = []

    /// Real 7-day spend per project working directory, read straight from the
    /// transcripts.
    ///
    /// The Projects tab used to add up the cost stored on its own archived
    /// session records, which is a different and much worse source: a record
    /// only carries a cost if the app happened to have a transcript path for
    /// that session, so most of them are zero, and the ones that aren't are
    /// whole-transcript lifetime totals rather than anything week-shaped. That
    /// is how the same project could read $227 on its card and $4 in the
    /// seven-day header above it. Both figures now come from the transcripts.
    @Published var weekCostByProject: [String: Double] = [:]

    /// Spend per calendar day (yyyy-MM-dd), same source. The daily bars used to
    /// be built from the session records, which only exist for sessions the app
    /// happened to be running for and archived — so a week of real work showed up
    /// as one tall bar today and six flat ones.
    @Published var weekCostByDay: [String: Double] = [:]

    /// One reused default ISO-8601 formatter. Building a DateFormatter isn't
    /// free and these export/log paths were each spinning up their own. Foundation
    /// documents its formatting methods as thread-safe, so a shared instance is
    /// fine; `nonisolated(unsafe)` because the type itself isn't Sendable.
    nonisolated(unsafe) static let iso8601 = ISO8601DateFormatter()

    let frontmost = FrontmostTracker()

    var thinkingLabel = "Working…"
    var thinkingExpiresAt: Date?
    var thinkingTask: Task<Void, Never>?

    /// After an interactive card resolves, hand keyboard focus back to the
    /// terminal so the user can keep typing without clicking. The notch panel
    /// grabbed key status to receive Enter/Esc; activating the terminal makes
    /// it key again and our panel resigns automatically. No-op while another
    /// interactive card is still queued.
    /// Set for one card-resolve when the resolver itself opens something (e.g.
    /// the drop chooser launches a terminal). Stops the notch from reactivating
    /// the previously-frontmost app, which could be a full-screen app on another
    /// Space and would yank the display there.
    var suppressReturnToApp = false

    /// The set of system sounds we offer in the picker. macOS ships these
    /// under /System/Library/Sounds.
    static let availableSounds = [
        "Funk", "Pop", "Tink", "Glass", "Submarine", "Hero", "Blow", "Bottle",
        "Frog", "Morse", "Ping", "Purr", "Sosumi"
    ]

    // MARK: - Waiting-on-you re-alert state (logic lives in AppState+Alerts.swift)

    // One missed chime shouldn't cost 20 minutes: while a blocking card sits
    // unanswered, keep nudging every `reAlertAfter` — replay the sound, re-post
    // the native notification (same identifier, so it replaces rather than
    // stacks), and request user attention. Capped at `maxReAlerts` nudges per
    // request so it escalates without turning into an endless nag.
    static let reAlertAfter: TimeInterval = 180
    static let maxReAlerts = 3
    var reAlertTimer: Timer?
    // Per-request nudge bookkeeping: how many times nudged, and when last.
    var reAlertState: [UUID: (count: Int, lastAt: Date)] = [:]
}
