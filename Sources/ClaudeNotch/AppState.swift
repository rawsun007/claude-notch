import Foundation
import AppKit

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

// MARK: - Tool preview & danger flagging

/// A small unified-diff hunk: the lines being replaced and the lines that
/// replace them. Truncated to ~10 lines each at construction.
struct DiffHunk: Equatable {
    let oldLines: [String]
    let newLines: [String]
    let truncatedOld: Bool
    let truncatedNew: Bool
}

/// Optional structured preview attached to a PermissionRequest. Renders
/// inside the permission card so the user can see what's about to happen
/// instead of just the file path.
enum ToolPreview: Equatable {
    case diff(DiffHunk)
    case multiDiff(count: Int, first: DiffHunk)
    case write(head: String, totalLines: Int)
}

// MARK: - History

/// One row in the click-to-expand history drawer. Captured at resolve time
/// so the user can scroll back through what's been happening.
struct HistoryEntry: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    let timestamp: Date
    let kind: Kind
    let toolName: String
    let title: String
    let detail: String
    let project: String
    let outcome: Outcome

    enum Kind: String, Equatable, Codable {
        case permission, question, notification, completed
    }
    enum Outcome: Equatable, Codable {
        case allowed, denied, dismissed, answered(count: Int), info, dangerous
    }
}

/// Aggregate, all-time usage counters — accumulated locally and persisted to
/// state.json. No event-by-event log beyond `history`; just running totals so
/// the Insights menu can show "what ClaudeNotch has done for you".
struct UsageStats: Codable {
    var allowed: Int = 0
    var denied: Int = 0
    var autoApproved: Int = 0
    var dangerousFlagged: Int = 0
    var questionsAnswered: Int = 0
    var toolCounts: [String: Int] = [:]
    var activeDays: [String] = []   // yyyy-MM-dd, deduped, oldest→newest
    var firstUsed: Date? = nil
    /// Per-day counts (keyed yyyy-MM-dd) for the heatmap + daily digest.
    var dailyCounts: [String: DayCounts] = [:]
}

struct DayCounts: Codable {
    var allowed: Int = 0
    var denied: Int = 0
    var autoApproved: Int = 0
    var dangerousFlagged: Int = 0
    var tools: Int = 0   // total tool requests that day
    var total: Int { allowed + denied }
}

/// One auto-approval rule. The `commandRegex` is optional: nil means
/// "match any input for this tool" (the old tool-wide always-allow),
/// non-nil means "this tool AND the command matches this regex".
/// Persisted across launches.
struct AllowRule: Hashable, Codable, Identifiable {
    let tool: String
    let commandRegex: String?

    var id: String { "\(tool)\u{0001}\(commandRegex ?? "")" }

    func matches(_ req: PermissionRequest) -> Bool {
        guard tool == req.toolName else { return false }
        guard let pattern = commandRegex, !pattern.isEmpty else { return true }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(req.detail.startIndex..<req.detail.endIndex, in: req.detail)
        return re.firstMatch(in: req.detail, range: range) != nil
    }

    /// Human-readable label for menus / status lines.
    var displayLabel: String {
        guard let pattern = commandRegex, !pattern.isEmpty else { return tool }
        // Short, friendly form for the common "exact command" case (where
        // pattern is an anchored regex-escape of a literal).
        if pattern.hasPrefix("^") && pattern.hasSuffix("$") {
            let unescaped = pattern
                .replacingOccurrences(of: #"\Q"#, with: "")
                .replacingOccurrences(of: #"\E"#, with: "")
                .dropFirst().dropLast()
            let inner = String(unescaped)
            if inner.count <= 60 {
                return "\(tool): `\(inner)`"
            }
        }
        return "\(tool) matching /\(pattern)/"
    }
}

struct AskOption: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let description: String
}

struct AskQuestion: Identifiable, Equatable {
    let id = UUID()
    let header: String          // short tag, e.g. "Approach"
    let text: String            // full question
    let multiSelect: Bool
    let options: [AskOption]
}

final class QuestionRequest: Identifiable, Equatable {
    let id = UUID()
    let questions: [AskQuestion]
    let source: String
    let cwd: String
    let receivedAt = Date()
    let originatorBundleID: String?
    let resolver: ([[String]]?) -> Void   // nil = cancel; otherwise one [labels] per question

    init(questions: [AskQuestion], source: String, cwd: String, originatorBundleID: String? = nil, resolver: @escaping ([[String]]?) -> Void) {
        self.questions = questions
        self.source = source
        self.cwd = cwd
        self.originatorBundleID = originatorBundleID
        self.resolver = resolver
    }

    static func == (lhs: QuestionRequest, rhs: QuestionRequest) -> Bool {
        lhs.id == rhs.id
    }
}

enum PermissionDecision: String {
    case allow, deny, ask
}

/// What kind of "always allow" rule to install when the user picks Allow.
/// `.none` = one-shot; `.tool` = the old tool-wide rule; `.exactCommand`
/// = the same tool + literal command string.
enum AllowScope {
    case none, tool, exactCommand
}

final class PermissionRequest: Identifiable, Equatable {
    enum Kind: Equatable {
        case toolUse                // blocking — must resolve to allow/deny/ask
        case notification           // non-blocking — just a visibility ping
    }

    let id = UUID()
    let kind: Kind
    let title: String         // e.g. "Run shell command"
    let detail: String        // e.g. the command string
    let toolName: String      // e.g. "Bash"
    let source: String        // e.g. "Claude Code"
    let cwd: String
    let receivedAt = Date()
    let originatorBundleID: String?   // app that was frontmost when request came in
    let preview: ToolPreview?         // Edit diff / Write head / MultiEdit summary
    let dangerReasons: [String]       // empty unless command matched a danger pattern
    let resolver: (PermissionDecision) -> Void

    // For "group similar prompts": when the next request matches this one, we
    // replace the queue item with a new one whose resolver fires both callbacks.
    var groupCount: Int = 1
    var originalDetail: String? = nil   // captured the first time we group

    init(kind: Kind, title: String, detail: String, toolName: String, source: String, cwd: String, originatorBundleID: String? = nil, preview: ToolPreview? = nil, dangerReasons: [String] = [], resolver: @escaping (PermissionDecision) -> Void) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.toolName = toolName
        self.source = source
        self.cwd = cwd
        self.originatorBundleID = originatorBundleID
        self.preview = preview
        self.dangerReasons = dangerReasons
        self.resolver = resolver
    }

    var isDangerous: Bool { !dangerReasons.isEmpty }

    static func == (lhs: PermissionRequest, rhs: PermissionRequest) -> Bool {
        lhs.id == rhs.id
    }
}

final class CompletedTask: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let source: String
    let cwd: String
    let receivedAt = Date()
    let originatorBundleID: String?

    init(title: String, detail: String, source: String, cwd: String, originatorBundleID: String? = nil) {
        self.title = title
        self.detail = detail
        self.source = source
        self.cwd = cwd
        self.originatorBundleID = originatorBundleID
    }

    static func == (lhs: CompletedTask, rhs: CompletedTask) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var mode: NotchMode = .idle
    @Published private(set) var permissionQueue: [PermissionRequest] = []
    @Published private(set) var completedQueue: [CompletedTask] = []
    @Published private(set) var questionQueue: [QuestionRequest] = []
    @Published private(set) var allowRules: Set<AllowRule> = []
    @Published var isHovering: Bool = false

    // User preferences (persisted).
    @Published var autoApprove: Bool = false   // auto-allow every permission
    @Published var soundMuted: Bool = false     // silence all notch sounds

    // Usage stats — all-time (persisted) + this-session (in-memory).
    @Published private(set) var stats = UsageStats()
    private(set) var sessionTools = 0
    private(set) var sessionAllowed = 0
    private(set) var sessionDenied = 0

    // Timed auto-approve: when set, auto-approve turns itself off at this time.
    // Not persisted, so a restart always reverts to the permanent toggle.
    @Published private(set) var autoApproveUntil: Date? = nil
    private var autoApproveTimer: Timer?

    // Snooze: suppress non-blocking cards (notification + completed) until this
    // time. Blocking permission cards always show — Claude is waiting on them.
    @Published private(set) var snoozedUntil: Date? = nil
    private var snoozeTimer: Timer?
    var isSnoozed: Bool {
        if let until = snoozedUntil { return until > Date() }
        return false
    }

    // Sound preferences (persisted).
    @Published var alertSound: String = "Funk"
    @Published var perToolSounds: Bool = false

    // Daily digest tracking — only shown once per day.
    @Published private(set) var lastDigestDate: String? = nil

    /// Transient "live activity" card shown after an auto-approved action —
    /// shows WHAT changed, no buttons, auto-dismisses.
    @Published private(set) var autoInfo: PermissionRequest? = nil
    private var autoInfoTimer: Timer?
    private var lastAutoSoundAt: Date = .distantPast

    // Top inset of the screen the notch is rendering on. The window controller
    // updates this so the card's top padding matches the current display
    // (built-in notch ≈ 37pt; external display 0). Prevents a black gap at
    // the top of the card on external monitors.
    @Published var notchTopInset: CGFloat = NotchView.notchInset(on: NSScreen.main)

    // Live session info — populated from every hook payload.
    @Published private(set) var currentProject: String = ""        // basename of cwd
    @Published private(set) var currentCwd: String = ""
    @Published private(set) var lastActivity: String = ""          // "Bash: ls -la" etc.
    @Published private(set) var lastUserPrompt: String = ""
    @Published private(set) var recentProjects: [String] = []      // ordered, deduped cwds (newest first)
    @Published private(set) var lastOriginatorBundleID: String? = nil
    @Published private(set) var lastHookAt: Date? = nil
    @Published private(set) var lastClaudeResponse: String = ""        // truncated for hover
    @Published private(set) var fullClaudeResponse: String = ""        // up to 8000 chars
    @Published private(set) var lastClaudeResponseAt: Date? = nil
    @Published private(set) var lastActivityAt: Date? = nil
    @Published var composeText: String = ""
    @Published private(set) var isComposing: Bool = false
    @Published private(set) var composeTarget: String? = nil
    @Published private(set) var composeError: String? = nil
    // When set, "send" opens a NEW terminal in this project's folder running
    // `claude "<message>"`, instead of typing into the active terminal.
    @Published var composeProjectCwd: String? = nil
    @Published private(set) var isResponseDetailOpen: Bool = false
    @Published private(set) var isHistoryOpen: Bool = false

    // Click-to-expand history drawer (most recent first, ring-buffered).
    @Published private(set) var history: [HistoryEntry] = []
    private let historyMax = 50

    // After this many seconds without a hook, drop the activity line.
    private let activityStaleAfter: TimeInterval = 90
    // After this many seconds without a hook, also drop the project name
    // (the terminal is most likely closed).
    private let projectStaleAfter: TimeInterval = 300
    private var staleTimer: Timer?

    // Debounced write to ~/.claudenotch/state.json — coalesces bursts of
    // mutations (e.g. many history appends in a row) into one disk write.
    private var persistTimer: Timer?

    init() {
        if let snapshot = Persistence.load() {
            self.history = snapshot.history
            self.allowRules = snapshot.allowRules
            self.recentProjects = snapshot.recentProjects
            self.autoApprove = snapshot.autoApprove ?? false
            self.soundMuted = snapshot.soundMuted ?? false
            self.stats = snapshot.stats ?? UsageStats()
            self.alertSound = snapshot.alertSound ?? "Funk"
            self.perToolSounds = snapshot.perToolSounds ?? false
            self.lastDigestDate = snapshot.lastDigestDate
        }
    }

    // MARK: - Usage stats

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private func markActiveToday() {
        if stats.firstUsed == nil { stats.firstUsed = Date() }
        let today = Self.dayKey(Date())
        if stats.activeDays.last != today, !stats.activeDays.contains(today) {
            stats.activeDays.append(today)
            if stats.activeDays.count > 400 {
                stats.activeDays = Array(stats.activeDays.suffix(400))
            }
        }
    }

    /// A tool permission was requested (shown or auto-handled).
    private func recordToolRequested(_ toolName: String, dangerousShown: Bool) {
        markActiveToday()
        stats.toolCounts[toolName, default: 0] += 1
        sessionTools += 1
        let today = Self.dayKey(Date())
        var day = stats.dailyCounts[today] ?? DayCounts()
        day.tools += 1
        if dangerousShown {
            stats.dangerousFlagged += 1
            day.dangerousFlagged += 1
        }
        stats.dailyCounts[today] = day
        pruneOldDailyCounts()
        schedulePersist()
    }

    private func recordDecision(_ decision: PermissionDecision, auto: Bool) {
        let today = Self.dayKey(Date())
        var day = stats.dailyCounts[today] ?? DayCounts()
        switch decision {
        case .allow:
            stats.allowed += 1; sessionAllowed += 1
            day.allowed += 1
            if auto { stats.autoApproved += 1; day.autoApproved += 1 }
        case .deny:
            stats.denied += 1; sessionDenied += 1
            day.denied += 1
        case .ask:
            break
        }
        stats.dailyCounts[today] = day
        schedulePersist()
    }

    /// Keep the per-day map bounded so state.json doesn't grow forever.
    private func pruneOldDailyCounts() {
        guard stats.dailyCounts.count > 400 else { return }
        let sorted = stats.dailyCounts.keys.sorted()
        let drop = sorted.prefix(stats.dailyCounts.count - 400)
        for k in drop { stats.dailyCounts.removeValue(forKey: k) }
    }

    /// Counts for "yesterday" (or nil if you weren't active yesterday).
    var yesterdayCounts: DayCounts? {
        let cal = Calendar.current
        guard let y = cal.date(byAdding: .day, value: -1, to: Date()) else { return nil }
        return stats.dailyCounts[Self.dayKey(y)]
    }

    var shouldShowDigest: Bool {
        let today = Self.dayKey(Date())
        return yesterdayCounts != nil && lastDigestDate != today
    }

    func markDigestShown() {
        lastDigestDate = Self.dayKey(Date())
        schedulePersist()
    }

    /// Distinct days ClaudeNotch handled something.
    var activeDayCount: Int { Set(stats.activeDays).count }

    /// Consecutive-day streak ending today (or yesterday if nothing yet today).
    var currentStreak: Int {
        let set = Set(stats.activeDays)
        let cal = Calendar.current
        var day = Date()
        if !set.contains(Self.dayKey(day)) {
            guard let y = cal.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = y
            if !set.contains(Self.dayKey(day)) { return 0 }
        }
        var streak = 0
        while set.contains(Self.dayKey(day)) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    func setAutoApprove(_ on: Bool) {
        autoApprove = on
        // Manual toggle cancels any in-progress timed window.
        autoApproveTimer?.invalidate(); autoApproveTimer = nil
        autoApproveUntil = nil
        schedulePersist()
    }

    /// Turn auto-approve on for N minutes, then automatically turn it back off.
    func enableAutoApprove(forMinutes minutes: Int) {
        autoApprove = true
        autoApproveUntil = Date().addingTimeInterval(Double(minutes) * 60)
        autoApproveTimer?.invalidate()
        autoApproveTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.autoApprove = false
                self.autoApproveUntil = nil
                self.autoApproveTimer = nil
                self.schedulePersist()
            }
        }
        // Don't persist autoApprove=true here — persistNow guards it.
    }

    func setSoundMuted(_ on: Bool) { soundMuted = on; schedulePersist() }
    func setAlertSound(_ name: String) { alertSound = name; schedulePersist() }
    func setPerToolSounds(_ on: Bool) { perToolSounds = on; schedulePersist() }

    /// Suppress non-blocking cards (notifications + completions) for N minutes.
    /// Permission cards still show — Claude is blocking on them.
    func snooze(forMinutes minutes: Int) {
        snoozedUntil = Date().addingTimeInterval(Double(minutes) * 60)
        snoozeTimer?.invalidate()
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.snoozedUntil = nil
                self?.snoozeTimer = nil
            }
        }
    }

    func cancelSnooze() {
        snoozeTimer?.invalidate(); snoozeTimer = nil
        snoozedUntil = nil
    }

    /// Friendly welcome card shown once at the end of the onboarding flow, so
    /// first-time users immediately see what a ClaudeNotch card looks like.
    func triggerWelcomeDemo() {
        let req = PermissionRequest(
            kind: .notification,
            title: "Welcome to ClaudeNotch!",
            detail: "Permissions, questions, and notifications from Claude Code will appear right here. Click Dismiss when you're ready.",
            toolName: "Notification",
            source: "Demo",
            cwd: NSHomeDirectory(),
            resolver: { _ in }
        )
        enqueuePermission(req, bypassRules: true)
    }

    fileprivate func schedulePersist() {
        persistTimer?.invalidate()
        persistTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.persistNow() }
        }
    }

    private func persistNow() {
        Persistence.save(.init(
            history: history,
            allowRules: allowRules,
            recentProjects: recentProjects,
            // Don't persist a timed auto-approve as a permanent ON — would
            // get stuck on after a restart since the timer is gone.
            autoApprove: autoApprove && autoApproveUntil == nil,
            soundMuted: soundMuted,
            stats: stats,
            alertSound: alertSound,
            perToolSounds: perToolSounds,
            lastDigestDate: lastDigestDate
        ))
    }

    func setHovering(_ value: Bool) {
        if isHovering != value { isHovering = value }
    }

    func noteSession(cwd: String, originatorBundleID: String? = nil) {
        // Normalize: strip trailing slashes so "/a/b" and "/a/b/" dedupe.
        var c = cwd
        while c.count > 1, c.hasSuffix("/") { c.removeLast() }
        guard !c.isEmpty else { return }
        currentCwd = c
        currentProject = (c as NSString).lastPathComponent
        let beforeRecent = recentProjects
        recentProjects.removeAll { $0 == c }
        recentProjects.insert(c, at: 0)
        if recentProjects.count > 8 { recentProjects = Array(recentProjects.prefix(8)) }
        if recentProjects != beforeRecent { schedulePersist() }
        if let bid = originatorBundleID, bid != Bundle.main.bundleIdentifier {
            lastOriginatorBundleID = bid
        }
        lastHookAt = Date()
        ensureStaleTimer()
    }

    func noteActivity(_ label: String) {
        lastActivity = label
        lastActivityAt = Date()
        lastHookAt = Date()
        ensureStaleTimer()
    }

    func noteUserPrompt(_ prompt: String) {
        lastUserPrompt = String(prompt.prefix(140))
        lastHookAt = Date()
        ensureStaleTimer()
    }

    /// Manually wipe the live session info — useful when you closed the
    /// terminal and want the notch to forget what was running there.
    func clearSession() {
        currentProject = ""
        currentCwd = ""
        lastActivity = ""
        lastUserPrompt = ""
        lastClaudeResponse = ""
        lastHookAt = nil
    }

    func noteClaudeResponse(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        fullClaudeResponse = String(trimmed.prefix(8000))
        lastClaudeResponse = String(trimmed.prefix(240))
        lastClaudeResponseAt = Date()
        lastHookAt = Date()
    }

    // Override noteActivity to stamp its own time so the IdlePill can pick
    // the most-recent signal.
    func setLastActivityTimestamp() {
        lastActivityAt = Date()
    }

    // MARK: - Compose (send message to Claude)

    /// Hotkey entry point. Doesn't barge in on an active permission /
    /// question prompt — those are time-sensitive and dismissing them
    /// would be worse than the hotkey appearing to do nothing.
    func summonCompose() {
        switch mode {
        case .permission, .question:
            playSound("Funk")
            return
        default:
            beginCompose()
        }
    }

    /// Open the composer. `project` (a cwd) means "send by opening a new
    /// terminal in that folder running claude"; nil means "type into the
    /// currently active terminal".
    func beginCompose(project: String? = nil) {
        composeText = ""
        composeError = nil
        composeProjectCwd = project
        // Resolve the active-terminal target NOW, before we become key —
        // otherwise frontmost might briefly become ClaudeNotch.
        composeTarget = pickComposeTarget()
        isComposing = true
        recompute()
    }

    func setComposeProject(_ cwd: String?) {
        composeProjectCwd = cwd
        composeError = nil
    }

    func sendCompose() {
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { cancelCompose(); return }

        // Project mode: open a fresh terminal in that folder with the message
        // as Claude's first prompt. No Accessibility needed.
        if let cwd = composeProjectCwd, !cwd.isEmpty {
            TerminalAutomator.startClaude(in: cwd, message: text)
            playSound("Tink")
            cancelCompose()
            return
        }

        // Active-terminal mode: type into the running session via keystrokes.
        let target = composeTarget ?? pickComposeTarget()
        guard let bid = target else {
            composeError = "No terminal found. Pick a project below, or open a Claude session first."
            return
        }
        if !TerminalAutomator.isAccessibilityTrusted {
            composeError = "Grant Accessibility (menu bar → Permissions) so I can type into your terminal."
            return
        }
        TerminalAutomator.sendText(text, toBundleID: bid)
        playSound("Tink")
        cancelCompose()
    }

    func cancelCompose() {
        let target = composeTarget
        composeText = ""
        isComposing = false
        composeError = nil
        composeTarget = nil
        composeProjectCwd = nil
        recompute()
        returnKeyboardToTerminal(preferred: target)
    }

    private func pickComposeTarget() -> String? {
        // 1. App that was frontmost just before us (NSWorkspace tracker)
        if let bid = frontmost.lastNonSelf?.bundleIdentifier, !bid.isEmpty {
            return bid
        }
        // 2. Last bundle that fired a hook
        if let bid = lastOriginatorBundleID { return bid }
        // 3. Best-guess: any running terminal
        let candidates = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.microsoft.VSCode",
            "com.anthropic.claudefordesktop",
            "co.zeit.hyper",
            "io.alacritty"
        ]
        for b in candidates {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: b).isEmpty {
                return b
            }
        }
        return nil
    }

    // MARK: - Response detail

    func showResponseDetail() {
        guard !fullClaudeResponse.isEmpty else { return }
        isResponseDetailOpen = true
        recompute()
    }

    func closeResponseDetail() {
        isResponseDetailOpen = false
        recompute()
        returnKeyboardToTerminal()
    }

    // MARK: - History drawer

    func openHistory() {
        guard !history.isEmpty else { return }
        isHistoryOpen = true
        recompute()
    }

    func closeHistory() {
        isHistoryOpen = false
        recompute()
        returnKeyboardToTerminal()
    }

    func clearHistory() {
        history.removeAll()
        schedulePersist()
        if isHistoryOpen { closeHistory() }
    }

    fileprivate func appendHistory(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        if history.count > historyMax {
            history = Array(history.prefix(historyMax))
        }
        schedulePersist()
    }

    private func ensureStaleTimer() {
        guard staleTimer == nil else { return }
        staleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkStale() }
        }
    }

    private func checkStale() {
        guard let last = lastHookAt else { return }
        let age = Date().timeIntervalSince(last)
        if age > projectStaleAfter {
            // Full clear — terminal is almost certainly closed.
            currentProject = ""
            currentCwd = ""
            lastActivity = ""
            lastUserPrompt = ""
            lastHookAt = nil
            staleTimer?.invalidate()
            staleTimer = nil
        } else if age > activityStaleAfter {
            // Just drop the volatile fields.
            if !lastActivity.isEmpty { lastActivity = "" }
            if !lastUserPrompt.isEmpty { lastUserPrompt = "" }
        }
    }

    let frontmost = FrontmostTracker()

    private var thinkingLabel = "Working…"
    private var thinkingExpiresAt: Date?
    private var thinkingTask: Task<Void, Never>?

    /// `bypassRules: true` skips the always-allow and auto-approve
    /// short-circuits so the card is always shown — used by the menu-bar demos,
    /// which must demonstrate the UI even if the user has Bash always-allowed
    /// or Auto-Approve turned on.
    func enqueuePermission(_ req: PermissionRequest, bypassRules: Bool = false) {
        if !bypassRules, let matched = allowRules.first(where: { $0.matches(req) }) {
            // Auto-allowed by a rule the user installed earlier. Still
            // log it to history so they can see what we approved silently.
            appendHistory(HistoryEntry(
                timestamp: Date(),
                kind: req.kind == .notification ? .notification : .permission,
                toolName: req.toolName,
                title: req.title,
                detail: req.detail + "  (auto-allowed by rule: \(matched.displayLabel))",
                project: (req.cwd as NSString).lastPathComponent,
                outcome: req.kind == .notification ? .info : .allowed
            ))
            if req.kind == .toolUse {
                recordToolRequested(req.toolName, dangerousShown: false)
                recordDecision(.allow, auto: true)
            }
            req.resolver(.allow)
            return
        }

        // Auto-approve mode: allow immediately and show a brief, button-less
        // "live activity" card of what's changing. Dangerous commands are
        // exempt — they still require an explicit hold-to-confirm.
        if !bypassRules, autoApprove, req.kind == .toolUse, !req.isDangerous {
            req.resolver(.allow)
            appendHistory(HistoryEntry(
                timestamp: Date(),
                kind: .permission,
                toolName: req.toolName,
                title: req.title,
                detail: req.detail,
                project: (req.cwd as NSString).lastPathComponent,
                outcome: .allowed
            ))
            recordToolRequested(req.toolName, dangerousShown: false)
            recordDecision(.allow, auto: true)
            showAutoInfo(req)
            return
        }

        if req.kind == .toolUse, req.source != "Demo" {
            recordToolRequested(req.toolName, dangerousShown: req.isDangerous)
        }

        // Snooze: log notifications quietly, skip showing them.
        if req.kind == .notification, isSnoozed {
            appendHistory(HistoryEntry(
                timestamp: Date(),
                kind: .notification,
                toolName: req.toolName,
                title: req.title,
                detail: req.detail + "  (snoozed)",
                project: (req.cwd as NSString).lastPathComponent,
                outcome: .info
            ))
            return
        }

        // Group similar tool requests: if the last queued item is the same tool
        // with the same input and arrived in the last 5 seconds, fold this
        // request into it. The merged item's resolver fires every callback.
        if req.kind == .toolUse,
           let last = permissionQueue.last,
           last.kind == .toolUse,
           last.toolName == req.toolName,
           (last.originalDetail ?? last.detail) == req.detail,
           Date().timeIntervalSince(last.receivedAt) < 5 {
            let prev = last.resolver
            let newReq = PermissionRequest(
                kind: last.kind,
                title: last.title,
                detail: "(×\(last.groupCount + 1)) \(last.originalDetail ?? last.detail)",
                toolName: last.toolName,
                source: last.source,
                cwd: last.cwd,
                originatorBundleID: last.originatorBundleID,
                preview: last.preview,
                dangerReasons: last.dangerReasons,
                resolver: { decision in
                    prev(decision)
                    req.resolver(decision)
                }
            )
            newReq.groupCount = last.groupCount + 1
            newReq.originalDetail = last.originalDetail ?? last.detail
            permissionQueue[permissionQueue.count - 1] = newReq
            recompute()
            return
        }

        permissionQueue.append(req)
        // Record notifications immediately — they don't have an Allow/Deny.
        if req.kind == .notification {
            appendHistory(HistoryEntry(
                timestamp: Date(),
                kind: .notification,
                toolName: req.toolName,
                title: req.title,
                detail: req.detail,
                project: (req.cwd as NSString).lastPathComponent,
                outcome: .info
            ))
        }
        playAlert(toolName: req.toolName)
        recompute()
    }

    /// Show a transient, button-less card of an auto-approved action. A new
    /// one replaces the current (live-activity style); clears after a few
    /// seconds, or immediately when the user presses Esc.
    private func showAutoInfo(_ req: PermissionRequest) {
        // Soft, distinct "Pop" — and debounced, so a burst of auto-approved
        // edits doesn't machine-gun the sound (which read as an error).
        if Date().timeIntervalSince(lastAutoSoundAt) > 0.8 {
            playSound("Pop")
            lastAutoSoundAt = Date()
        }
        autoInfo = req
        recompute()
        autoInfoTimer?.invalidate()
        autoInfoTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.autoInfo = nil
                self.recompute()
            }
        }
    }

    /// Demo entry point: show the auto-approve "live activity" card exactly as
    /// it appears when Auto-Approve silently allows a tool call.
    func demoAutoApprove(_ req: PermissionRequest) {
        showAutoInfo(req)
    }

    func dismissAutoInfo() {
        guard autoInfo != nil else { return }
        autoInfoTimer?.invalidate()
        autoInfoTimer = nil
        autoInfo = nil
        recompute()
    }

    func enqueueCompleted(_ task: CompletedTask) {
        if isSnoozed {
            appendHistory(HistoryEntry(
                timestamp: Date(),
                kind: .completed,
                toolName: "Stop",
                title: task.title,
                detail: task.detail + "  (snoozed)",
                project: (task.cwd as NSString).lastPathComponent,
                outcome: .info
            ))
            return
        }
        completedQueue.append(task)
        appendHistory(HistoryEntry(
            timestamp: Date(),
            kind: .completed,
            toolName: "Stop",
            title: task.title,
            detail: task.detail,
            project: (task.cwd as NSString).lastPathComponent,
            outcome: .info
        ))
        playChime()
        recompute()
    }

    func enqueueQuestion(_ req: QuestionRequest) {
        questionQueue.append(req)
        playAlert()
        recompute()
    }

    func resolveCurrentQuestion(_ answers: [[String]]?) {
        guard !questionQueue.isEmpty else { return }
        let first = questionQueue.removeFirst()
        first.resolver(answers)
        let title: String
        let outcome: HistoryEntry.Outcome
        if let answers, !answers.isEmpty {
            outcome = .answered(count: answers.flatMap { $0 }.count)
            title = first.questions.first?.text ?? "Question"
            if first.source != "Demo" {
                stats.questionsAnswered += 1
                markActiveToday()
                schedulePersist()
            }
        } else {
            outcome = .dismissed
            title = first.questions.first?.text ?? "Question"
        }
        appendHistory(HistoryEntry(
            timestamp: Date(),
            kind: .question,
            toolName: "AskUserQuestion",
            title: title,
            detail: first.source,
            project: (first.cwd as NSString).lastPathComponent,
            outcome: outcome
        ))
        if answers != nil {
            playSound("Tink")
        } else {
            playSound("Pop")
        }
        recompute()
        returnKeyboardToTerminal(preferred: first.originatorBundleID)
    }

    func resolveCurrentPermission(_ decision: PermissionDecision, alwaysAllow: AllowScope = .none) {
        guard !permissionQueue.isEmpty else { return }
        let first = permissionQueue.removeFirst()
        if decision == .allow {
            switch alwaysAllow {
            case .none:
                break
            case .tool:
                allowRules.insert(AllowRule(tool: first.toolName, commandRegex: nil))
                schedulePersist()
            case .exactCommand:
                let escaped = NSRegularExpression.escapedPattern(for: first.detail)
                allowRules.insert(AllowRule(tool: first.toolName, commandRegex: "^\(escaped)$"))
                schedulePersist()
            }
        }
        if first.kind == .toolUse, first.source != "Demo" { recordDecision(decision, auto: false) }
        first.resolver(decision)
        // Notifications were already logged at enqueue time.
        if first.kind != .notification {
            let outcome: HistoryEntry.Outcome
            switch decision {
            case .allow: outcome = first.isDangerous ? .dangerous : .allowed
            case .deny:  outcome = .denied
            case .ask:   outcome = .dismissed
            }
            appendHistory(HistoryEntry(
                timestamp: Date(),
                kind: .permission,
                toolName: first.toolName,
                title: first.title,
                detail: first.detail,
                project: (first.cwd as NSString).lastPathComponent,
                outcome: outcome
            ))
        }
        playFeedback(for: decision)
        recompute()
        returnKeyboardToTerminal(preferred: first.originatorBundleID)
    }

    /// Resolve EVERY queued permission at once — for the "Claude fired 5 edits
    /// at the same time, I don't want to click 5 times" case. Skips dangerous
    /// ones (those stay queued for an explicit hold-to-confirm).
    func resolveAllPermissions(_ decision: PermissionDecision) {
        let originator = permissionQueue.first?.originatorBundleID
        var remaining: [PermissionRequest] = []
        for req in permissionQueue {
            if decision == .allow && req.isDangerous {
                remaining.append(req)   // never batch-allow a destructive command
                continue
            }
            if req.kind == .toolUse, req.source != "Demo" { recordDecision(decision, auto: false) }
            req.resolver(decision)
            if req.kind != .notification {
                appendHistory(HistoryEntry(
                    timestamp: Date(),
                    kind: .permission,
                    toolName: req.toolName,
                    title: req.title,
                    detail: req.detail,
                    project: (req.cwd as NSString).lastPathComponent,
                    outcome: decision == .allow ? .allowed : (decision == .deny ? .denied : .dismissed)
                ))
            }
        }
        permissionQueue = remaining
        playFeedback(for: decision)
        recompute()
        returnKeyboardToTerminal(preferred: originator)
    }

    private func playFeedback(for decision: PermissionDecision) {
        switch decision {
        case .allow: playSound("Tink")    // small success "tick"
        case .deny:  playSound("Pop")     // soft dismiss
        case .ask:   break
        }
    }

    func dismissCurrentCompleted() {
        guard !completedQueue.isEmpty else { return }
        let first = completedQueue.removeFirst()
        recompute()
        returnKeyboardToTerminal(preferred: first.originatorBundleID)
    }

    func clearAllowlist() {
        allowRules.removeAll()
        schedulePersist()
    }

    func removeAllowRule(_ rule: AllowRule) {
        allowRules.remove(rule)
        schedulePersist()
    }

    func pingThinking(label: String) {
        thinkingLabel = label
        thinkingExpiresAt = Date().addingTimeInterval(8)
        recompute()
        thinkingTask?.cancel()
        thinkingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_500_000_000)
            guard let self else { return }
            await MainActor.run {
                if let exp = self.thinkingExpiresAt, exp <= Date() {
                    self.thinkingExpiresAt = nil
                    self.recompute()
                }
            }
        }
    }

    func openLastApp() {
        frontmost.activateLastApp()
    }

    func openOriginator(_ bundleID: String?) {
        let me = Bundle.main.bundleIdentifier
        // Discard a captured originator that points back at *us* — happens
        // whenever the notch panel was key at hook-fire time. Also discard
        // an originator whose process is no longer running.
        if let bid = bundleID, bid != me,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
           !app.isTerminated {
            AppActivation.bringToFront(app)
            return
        }
        frontmost.activateLastApp()
    }

    /// After an interactive card resolves, hand keyboard focus back to the
    /// terminal so the user can keep typing without clicking. The notch panel
    /// grabbed key status to receive Enter/Esc; activating the terminal makes
    /// it key again and our panel resigns automatically. No-op while another
    /// interactive card is still queued.
    func returnKeyboardToTerminal(preferred: String? = nil) {
        switch mode {
        case .permission, .question, .compose, .completed, .responseDetail, .history:
            return   // still interactive — keep keyboard on the notch
        default:
            break
        }
        let bid = preferred ?? lastOriginatorBundleID
        openOriginator(bid)
    }

    func playSound(_ name: String) {
        guard !soundMuted else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    private func playAlert(toolName: String? = nil) {
        let name: String
        if perToolSounds, let t = toolName {
            name = Self.soundForTool(t)
        } else {
            name = alertSound
        }
        playSound(name)
    }

    /// Distinct chime per tool when "Per-tool sounds" is enabled.
    static func soundForTool(_ tool: String) -> String {
        switch tool {
        case "Bash":                  return "Funk"
        case "Edit", "MultiEdit":     return "Pop"
        case "Write", "NotebookEdit": return "Tink"
        case "Notification":          return "Submarine"
        default:                      return "Funk"
        }
    }

    /// The set of system sounds we offer in the picker. macOS ships these
    /// under /System/Library/Sounds.
    static let availableSounds = [
        "Funk", "Pop", "Tink", "Glass", "Submarine", "Hero", "Blow", "Bottle",
        "Frog", "Morse", "Ping", "Purr", "Sosumi"
    ]

    private func playChime() {
        playSound("Glass")
    }

    private func recompute() {
        let next: NotchMode
        if isHistoryOpen {
            next = .history
        } else if isResponseDetailOpen {
            next = .responseDetail
        } else if isComposing {
            next = .compose
        } else if let q = questionQueue.first {
            next = .question(q)
        } else if let p = permissionQueue.first {
            next = .permission(p)
        } else if let c = completedQueue.first {
            next = .completed(c)
        } else if let info = autoInfo {
            next = .autoInfo(info)
        } else if let exp = thinkingExpiresAt, exp > Date() {
            next = .thinking(label: thinkingLabel)
        } else {
            next = .idle
        }
        if next != mode {
            mode = next
        }
    }
}

@MainActor
final class FrontmostTracker {
    private(set) var lastNonSelf: NSRunningApplication?

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, let app else { return }
                let me = Bundle.main.bundleIdentifier
                let bid = app.bundleIdentifier
                guard bid != me else { return }
                // Skip system stuff that flashes through.
                let skip: Set<String> = ["com.apple.WindowManager", "com.apple.dock", "com.apple.notificationcenterui"]
                if let bid, skip.contains(bid) { return }
                self.lastNonSelf = app
            }
        }
        // Seed with the currently frontmost app
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastNonSelf = app
        }
    }

    func activateLastApp() {
        if let app = lastNonSelf, !app.isTerminated {
            AppActivation.bringToFront(app)
            return
        }
        let bundles = [
            "com.anthropic.claudefordesktop",
            "com.todesktop.230313mzl4w4u92",   // Cursor
            "com.microsoft.VSCode",
            "com.googlecode.iterm2",
            "com.apple.Terminal"
        ]
        for b in bundles {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first {
                AppActivation.bringToFront(app)
                return
            }
        }
    }
}

/// Centralised app-activation that works across macOS versions.
/// `.activateIgnoringOtherApps` is deprecated on macOS 14+ and no longer
/// reliable; the parameterless `.activate()` replaces it. We also unhide
/// first — a minimized app otherwise just bounces the Dock icon without
/// surfacing a window.
enum AppActivation {
    static func bringToFront(_ app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        // `.activateIgnoringOtherApps` is deprecated on macOS 14+, but the
        // parameterless replacement is unreliable when called from an
        // accessory app whose panel is currently key — it frequently no-ops,
        // which is why "Open IDE" only worked sometimes. The deprecated form
        // still works on every version, so we use it and also do a second
        // pass on the next runloop tick to win any activation race.
        app.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if !app.isActive { app.activate(options: [.activateIgnoringOtherApps]) }
        }
    }
}
