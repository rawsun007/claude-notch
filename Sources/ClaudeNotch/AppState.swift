import Foundation
import AppKit
import UniformTypeIdentifiers

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

// MARK: - Live sessions

/// One live Claude Code session, keyed by its `session_id` (or, when a hook
/// didn't carry one, by its normalized cwd). Lets the notch show several
/// concurrent sessions at once instead of collapsing them onto one global
/// "current" set of fields.
struct LiveSession: Identifiable, Equatable {
    let id: String                 // session_id, or normalized cwd when absent
    var cwd: String
    var project: String            // basename of cwd
    var status: String             // same vocabulary as claudeActionStatus
    var activity: String           // last "Bash: ls" style line
    var lastResponse: String       // snippet for the row
    var fullResponse: String       // full reply text for the detail view
    var originatorBundleID: String?
    var lastHookAt: Date
    // Task progress for the current task list. Tracked as sets (keyed by task
    // id) so duplicate Created/Completed events dedup themselves. In-memory
    // only — sessions aren't persisted, so no Codable concern.
    var createdTaskIds: Set<String> = []
    var completedTaskIds: Set<String> = []

    var taskTotal: Int { createdTaskIds.count }
    var taskDone: Int { completedTaskIds.count }

    // Live context + cost meter, parsed from this session's transcript usage.
    var contextPercent: Double = 0   // 0...1 of the context window in use now
    var sessionCostUSD: Double = 0   // cumulative estimated cost so far
    var model: String = ""           // most recent model id (e.g. claude-opus-4-8)
    var isCompacting: Bool = false   // true between PreCompact and the next event

    var hasMeter: Bool { contextPercent > 0 || sessionCostUSD > 0 }
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

// Resilient decoders: Swift's synthesized Decodable ignores a property's
// default and throws keyNotFound when a key is absent, so adding any new
// field in a release would make an older state.json fail to decode and wipe
// all stats on update. Decoding every key with decodeIfPresent ?? default
// keeps old snapshots loadable as the schema grows. (Defined in extensions so
// the synthesized memberwise + no-arg inits are preserved.)
extension UsageStats {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowed = try c.decodeIfPresent(Int.self, forKey: .allowed) ?? allowed
        denied = try c.decodeIfPresent(Int.self, forKey: .denied) ?? denied
        autoApproved = try c.decodeIfPresent(Int.self, forKey: .autoApproved) ?? autoApproved
        dangerousFlagged = try c.decodeIfPresent(Int.self, forKey: .dangerousFlagged) ?? dangerousFlagged
        questionsAnswered = try c.decodeIfPresent(Int.self, forKey: .questionsAnswered) ?? questionsAnswered
        toolCounts = try c.decodeIfPresent([String: Int].self, forKey: .toolCounts) ?? toolCounts
        activeDays = try c.decodeIfPresent([String].self, forKey: .activeDays) ?? activeDays
        firstUsed = try c.decodeIfPresent(Date.self, forKey: .firstUsed) ?? firstUsed
        dailyCounts = try c.decodeIfPresent([String: DayCounts].self, forKey: .dailyCounts) ?? dailyCounts
    }
}

extension DayCounts {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowed = try c.decodeIfPresent(Int.self, forKey: .allowed) ?? allowed
        denied = try c.decodeIfPresent(Int.self, forKey: .denied) ?? denied
        autoApproved = try c.decodeIfPresent(Int.self, forKey: .autoApproved) ?? autoApproved
        dangerousFlagged = try c.decodeIfPresent(Int.self, forKey: .dangerousFlagged) ?? dangerousFlagged
        tools = try c.decodeIfPresent(Int.self, forKey: .tools) ?? tools
    }
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

/// What the composer is for. `.message` types into a terminal / opens Claude;
/// `.denyReason` reuses the same editor to deny a held permission with a note
/// that's fed back to Claude (so it knows what to do instead).
enum ComposePurpose: Equatable {
    case message
    case denyReason(PermissionRequest)
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
    // `reason` is an optional note (used for "deny with a reason"): the hook
    // forwards it to Claude as the permissionDecisionReason so it knows what to
    // do instead. nil for plain allow/deny/ask.
    let resolver: (PermissionDecision, String?) -> Void

    // For "group similar prompts": when the next request matches this one, we
    // replace the queue item with a new one whose resolver fires both callbacks.
    var groupCount: Int = 1
    var originalDetail: String? = nil   // captured the first time we group

    init(kind: Kind, title: String, detail: String, toolName: String, source: String, cwd: String, originatorBundleID: String? = nil, preview: ToolPreview? = nil, dangerReasons: [String] = [], resolver: @escaping (PermissionDecision, String?) -> Void) {
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

/// Bridge for mirroring blocking permission cards to native notifications.
/// AppState only knows this interface; the concrete UserNotifications wiring
/// lives in NotificationBridge so AppState stays UI-framework-light.
@MainActor protocol PermissionMirroring: AnyObject {
    func mirror(_ req: PermissionRequest)
    func withdraw(_ id: UUID)
    func withdrawAll()
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
    static let statusEntityName = "Claude"

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
    @Published var persistentNotchDisplay: Bool = false
    // Require Touch ID / Face ID to confirm a dangerous command (instead of
    // press-and-hold). Defaults on when the Mac has biometrics. Persisted.
    @Published var requireTouchID: Bool = false

    // Mirror blocking permission cards to native macOS notifications so they're
    // actionable from the lock screen / another Space, and auto-respect Focus
    // (the OS suppresses banners during Do Not Disturb). Persisted; on by
    // default. The concrete bridge is wired in by AppDelegate at launch.
    @Published var mirrorToNotificationCenter: Bool = true
    weak var permissionMirror: PermissionMirroring?

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
    // Which session the global mirror (lastClaudeResponse, claudeActionStatus,
    // etc.) currently reflects. Only this session may write the mirror, so a
    // background session's transcript poll — or a closed session whose poll is
    // still winding down — can't thrash the collapsed header every tick.
    private var currentSessionId: String = ""
    @Published private(set) var lastActivity: String = ""          // "Bash: ls -la" etc.
    @Published private(set) var lastUserPrompt: String = ""
    @Published private(set) var recentProjects: [String] = []      // ordered, deduped cwds (newest first)
    @Published private(set) var lastOriginatorBundleID: String? = nil
    @Published private(set) var lastHookAt: Date? = nil
    @Published private(set) var lastClaudeResponse: String = ""        // truncated for hover
    @Published private(set) var fullClaudeResponse: String = ""        // up to 8000 chars
    @Published private(set) var lastClaudeResponseAt: Date? = nil
    @Published private(set) var lastActivityAt: Date? = nil
    @Published private(set) var claudeActionStatus: String = "ready"
    // Global mirror of the current session's context + cost meter (for the
    // collapsed header). Per-session values live on each LiveSession.
    @Published private(set) var currentContextPercent: Double = 0
    @Published private(set) var currentCostUSD: Double = 0
    @Published private(set) var currentModel: String = ""

    // Cost budgets (USD, estimated from public pricing). 0 = off. Persisted.
    // sessionCostCap warns on any single session; dailyCostCap on today's total.
    @Published private(set) var sessionCostCap: Double = 0
    @Published private(set) var dailyCostCap: Double = 0
    // Today's total estimated cost across all sessions, pushed from EventServer.
    @Published private(set) var todayCostUSD: Double = 0
    // Debounce warnings so a meter that keeps updating doesn't re-alert. Levels
    // are 0 / 80 / 100; in-memory only (re-arming on restart is fine).
    private var sessionWarnLevel: [String: Int] = [:]
    private var dailyWarnLevel: Int = 0
    private var dailyWarnDate: String = ""

    // Per-session live state. Keyed by session_id (or normalized cwd when a
    // hook didn't carry one). The global fields above stay as a mirror of the
    // most-recent session so existing UI keeps working unchanged.
    @Published private(set) var sessions: [String: LiveSession] = [:]
    private let sessionsMax = 12

    @Published var composeText: String = ""
    @Published private(set) var isComposing: Bool = false
    @Published private(set) var composePurpose: ComposePurpose = .message
    @Published private(set) var composeTarget: String? = nil
    // Human label for what we're sending to (e.g. the session's project), shown
    // in the composer header. Set for replies; nil for a plain hotkey compose.
    @Published private(set) var composeContextLabel: String? = nil
    @Published private(set) var composeError: String? = nil
    // When set, "send" opens a NEW terminal in this project's folder running
    // `claude "<message>"`, instead of typing into the active terminal.
    @Published var composeProjectCwd: String? = nil
    @Published private(set) var isResponseDetailOpen: Bool = false
    // The reply currently shown in the detail view — set from either the global
    // last reply or a tapped session row, so the card can render whichever.
    @Published private(set) var detailResponseText: String = ""
    @Published private(set) var detailProject: String = ""
    @Published private(set) var isHistoryOpen: Bool = false

    // Click-to-expand history drawer (most recent first, ring-buffered).
    // 500 entries ≈ 100 KB of state.json — cheap enough to keep a real
    // scroll-back log instead of evaporating after a handful of decisions.
    @Published private(set) var history: [HistoryEntry] = []
    private let historyMax = 500

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
            self.persistentNotchDisplay = snapshot.persistentNotchDisplay ?? false
            self.lastDigestDate = snapshot.lastDigestDate
            self.sessionCostCap = snapshot.sessionCostCap ?? 0
            self.dailyCostCap = snapshot.dailyCostCap ?? 0
            self.requireTouchID = snapshot.requireTouchID ?? BiometricAuth.isAvailable
            self.mirrorToNotificationCenter = snapshot.mirrorToNotificationCenter ?? true
        } else {
            self.requireTouchID = BiometricAuth.isAvailable
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
    func setPersistentNotchDisplay(_ on: Bool) { persistentNotchDisplay = on; schedulePersist() }
    func setRequireTouchID(_ on: Bool) { requireTouchID = on; schedulePersist() }
    func setMirrorToNotificationCenter(_ on: Bool) {
        mirrorToNotificationCenter = on
        if on {
            // Post any currently-queued blocking cards so the toggle takes
            // effect immediately rather than only on the next request.
            for req in permissionQueue where req.kind == .toolUse {
                permissionMirror?.mirror(req)
            }
        } else {
            permissionMirror?.withdrawAll()
        }
        schedulePersist()
    }

    // MARK: - Cost budgets

    func setSessionCostCap(_ usd: Double) {
        sessionCostCap = max(0, usd)
        sessionWarnLevel.removeAll()   // re-arm against the new cap
        schedulePersist()
        // Evaluate spend right now — don't wait for the next hook. Covers
        // "I set a cap and I'm already over it."
        guard sessionCostCap > 0 else { return }
        // Check every known session, plus the current mirror as a fallback.
        var checked = false
        for s in sessions.values where s.sessionCostUSD > 0 {
            checked = true
            let level = Self.budgetLevel(cost: s.sessionCostUSD, cap: sessionCostCap)
            if level > (sessionWarnLevel[s.id] ?? 0) {
                sessionWarnLevel[s.id] = level
                warnBudget(scope: "session", level: level, cost: s.sessionCostUSD, cap: sessionCostCap)
            }
        }
        if !checked, currentCostUSD > 0 {
            let level = Self.budgetLevel(cost: currentCostUSD, cap: sessionCostCap)
            if level > 0 { warnBudget(scope: "session", level: level, cost: currentCostUSD, cap: sessionCostCap) }
        }
    }

    func setDailyCostCap(_ usd: Double) {
        dailyCostCap = max(0, usd)
        dailyWarnLevel = 0
        dailyWarnDate = ""
        schedulePersist()
        // Recompute today's spend off the main thread and evaluate immediately,
        // so a cap set mid-day reflects what you've already spent.
        guard dailyCostCap > 0 else { return }
        Task { [weak self] in
            let cost = await Task.detached { ClaudeUsageReader.compute().today.costUSD }.value
            self?.noteTodayCost(cost)
        }
    }

    /// Which budget threshold `cost` has crossed against `cap`: 100, 80, or 0.
    private static func budgetLevel(cost: Double, cap: Double) -> Int {
        guard cap > 0 else { return 0 }
        if cost >= cap { return 100 }
        if cost >= cap * 0.8 { return 80 }
        return 0
    }

    /// Push today's total estimated spend (from EventServer) and alert if it
    /// crosses the daily cap. The level resets at the start of a new day.
    func noteTodayCost(_ cost: Double) {
        todayCostUSD = cost
        guard dailyCostCap > 0 else { return }
        let today = Self.dayKey(Date())
        if dailyWarnDate != today { dailyWarnDate = today; dailyWarnLevel = 0 }
        let level = Self.budgetLevel(cost: cost, cap: dailyCostCap)
        if level > dailyWarnLevel {
            dailyWarnLevel = level
            warnBudget(scope: "daily", level: level, cost: cost, cap: dailyCostCap)
        }
    }

    /// Demo entry point: show the budget alert card exactly as a real
    /// over-budget event renders it.
    func demoBudgetAlert() {
        warnBudget(scope: "session", level: 100, cost: 27.40, cap: 25)
    }

    private func warnBudget(scope: String, level: Int, cost: Double, cap: Double) {
        let pct = Int((cost / cap * 100).rounded())
        let title = level >= 100 ? "Over your \(scope) budget" : "Approaching your \(scope) budget"
        let detail = "\(ClaudeUsageReader.fmtMoney(cost)) of \(ClaudeUsageReader.fmtMoney(cap)) \(scope) cap (\(pct)%)"
        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: title,
            detail: detail,
            toolName: "Budget",
            source: "Cost budget",
            cwd: currentCwd,
            resolver: { _, _ in }
        ))
    }

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
            resolver: { _, _ in }
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
            persistentNotchDisplay: persistentNotchDisplay,
            lastDigestDate: lastDigestDate,
            sessionCostCap: sessionCostCap,
            dailyCostCap: dailyCostCap,
            requireTouchID: requireTouchID,
            mirrorToNotificationCenter: mirrorToNotificationCenter
        ))
    }

    func setHovering(_ value: Bool) {
        if isHovering != value { isHovering = value }
    }

    func noteSession(cwd: String, sessionId: String = "", originatorBundleID: String? = nil) {
        // Normalize: strip trailing slashes so "/a/b" and "/a/b/" dedupe.
        var c = cwd
        while c.count > 1, c.hasSuffix("/") { c.removeLast() }
        guard !c.isEmpty else { return }
        currentCwd = c
        currentProject = (c as NSString).lastPathComponent
        // A real hook just arrived for this session, so it becomes the one the
        // global mirror tracks. (Polls don't run through here, so they can't
        // steal "current" from the session the user is actually watching.)
        if !sessionId.isEmpty { currentSessionId = sessionId }
        let beforeRecent = recentProjects
        recentProjects.removeAll { $0 == c }
        recentProjects.insert(c, at: 0)
        if recentProjects.count > 8 { recentProjects = Array(recentProjects.prefix(8)) }
        if recentProjects != beforeRecent { schedulePersist() }
        let bid = (originatorBundleID != Bundle.main.bundleIdentifier) ? originatorBundleID : nil
        if let bid { lastOriginatorBundleID = bid }
        lastHookAt = Date()
        upsertSession(id: sessionId, cwd: c, authoritativeCwd: true, create: true) { s in
            if let bid { s.originatorBundleID = bid }
        }
        ensureStaleTimer()
    }

    func noteActivity(_ label: String, sessionId: String = "") {
        lastActivity = label
        let status = Self.statusLabel(fromActivity: label)
        claudeActionStatus = status
        lastActivityAt = Date()
        lastHookAt = Date()
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.activity = label
            s.status = status
        }
        ensureStaleTimer()
    }

    /// Called after a tool completes (PostToolUse) to show Claude is reasoning
    /// before the next tool call. Clears the command strip and sets status to
    /// "thinking" — persists until the next noteActivity call.
    func noteThinkingBetweenTools(sessionId: String = "") {
        claudeActionStatus = "thinking"
        lastActivity = ""
        lastHookAt = Date()
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.activity = ""
            s.status = "thinking"
        }
        ensureStaleTimer()
    }

    /// Push a freshly-parsed context + cost meter for a session. Updates that
    /// session's row always; mirrors to the global header only for the current
    /// session (same gate as noteClaudeResponse, so background sessions can't
    /// thrash the header).
    func noteSessionMeter(sessionId: String, contextPercent: Double, costUSD: Double, model: String) {
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.contextPercent = contextPercent
            s.sessionCostUSD = costUSD
            if !model.isEmpty { s.model = model }
            s.isCompacting = false
        }

        // Per-session budget: alert when this session crosses 80% / 100% of cap.
        if sessionCostCap > 0 {
            let key = !sessionId.isEmpty ? sessionId : currentCwd
            if !key.isEmpty {
                let level = Self.budgetLevel(cost: costUSD, cap: sessionCostCap)
                if level > (sessionWarnLevel[key] ?? 0) {
                    sessionWarnLevel[key] = level
                    warnBudget(scope: "session", level: level, cost: costUSD, cap: sessionCostCap)
                }
            }
        }

        let isCurrent = currentSessionId.isEmpty || sessionId == currentSessionId
        guard isCurrent else { return }
        currentContextPercent = contextPercent
        currentCostUSD = costUSD
        if !model.isEmpty { currentModel = model }
    }

    /// PreCompact: context is about to be compacted. Flag the session so the UI
    /// can show a "compacting" cue; cleared by the next meter/activity update.
    func noteCompacting(sessionId: String = "") {
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.isCompacting = true
        }
    }

    func noteUserPrompt(_ prompt: String, sessionId: String = "") {
        lastUserPrompt = String(prompt.prefix(140))
        lastClaudeResponse = ""
        fullClaudeResponse = ""
        lastClaudeResponseAt = nil
        claudeActionStatus = "thinking"
        lastHookAt = Date()
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.status = "thinking"
            s.lastResponse = ""
        }
        ensureStaleTimer()
    }

    // MARK: - Task progress meter

    /// A task was created (TaskCreated hook, or a TaskCreate tool call). Counts
    /// toward the session's "N/M" meter. If the previous batch was already
    /// fully complete, a fresh creation starts a new list (so the denominator
    /// doesn't grow without bound across a long session).
    func noteTaskCreated(id: String, subject: String = "", sessionId: String = "") {
        guard !id.isEmpty else { return }
        upsertSession(id: sessionId, cwd: currentCwd, create: true) { s in
            if !s.createdTaskIds.isEmpty,
               s.completedTaskIds.count >= s.createdTaskIds.count {
                s.createdTaskIds.removeAll()
                s.completedTaskIds.removeAll()
            }
            s.createdTaskIds.insert(id)
        }
        lastHookAt = Date()
        ensureStaleTimer()
    }

    /// A task was completed (TaskCompleted hook, or TaskUpdate status=completed).
    func noteTaskCompleted(id: String, sessionId: String = "") {
        guard !id.isEmpty else { return }
        upsertSession(id: sessionId, cwd: currentCwd, create: true) { s in
            // A completion can arrive for a task we never saw created (e.g. the
            // TaskCreated hook was missed) — count it on both sides so the meter
            // never shows more done than total.
            s.createdTaskIds.insert(id)
            s.completedTaskIds.insert(id)
        }
        lastHookAt = Date()
        ensureStaleTimer()
    }

    /// A task was abandoned (TaskUpdate status=deleted). Drop it from both sets
    /// so a cancelled task doesn't inflate the denominator.
    func noteTaskDeleted(id: String, sessionId: String = "") {
        guard !id.isEmpty else { return }
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.createdTaskIds.remove(id)
            s.completedTaskIds.remove(id)
        }
    }

    /// A turn finished for a session — settle it to a steady state (so its dot
    /// stops pulsing) without disturbing the other live sessions.
    func markSessionDone(cwd: String = "", sessionId: String = "") {
        guard !sessionId.isEmpty || !cwd.isEmpty || !currentCwd.isEmpty else { return }
        upsertSession(id: sessionId, cwd: cwd.isEmpty ? currentCwd : cwd) { s in
            s.status = s.lastResponse.isEmpty ? "done" : "last reply"
        }
    }

    // Statuses a session rests in once a turn ends — don't let late transcript
    // polling drag a finished session back into a pulsing "replying" state.
    private static let terminalSessionStatuses: Set<String> = ["done", "last reply", "ready"]

    /// Manually wipe the live session info — useful when you closed the
    /// terminal and want the notch to forget what was running there.
    func clearSession() {
        currentProject = ""
        currentCwd = ""
        lastActivity = ""
        lastUserPrompt = ""
        lastClaudeResponse = ""
        claudeActionStatus = "ready"
        lastHookAt = nil
        sessions.removeAll()
    }

    func noteClaudeResponse(_ text: String, sessionId: String = "") {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let snippet = Self.statusSnippet(from: trimmed)
        // Attribute to the session even if the global mirror already holds this
        // text (e.g. two sessions emitting the same reply).
        if !sessionId.isEmpty || !currentCwd.isEmpty {
            upsertSession(id: sessionId, cwd: currentCwd) { s in
                s.lastResponse = snippet
                s.fullResponse = String(trimmed.prefix(8000))
                if !Self.terminalSessionStatuses.contains(s.status) {
                    s.status = "replying"
                }
            }
        }

        // Only the current session writes the global mirror. Without this gate,
        // two sessions polling their transcripts (one possibly just-closed but
        // still winding down) overwrite lastClaudeResponse on alternating ticks,
        // and the collapsed header flickers between their replies every second.
        // Gate on session identity, not sessions.count: a closed session can be
        // gone from the dict (count == 1) while its poll loop is still pushing.
        // currentSessionId == "" means legacy/no per-session tracking → allow.
        let isCurrent = currentSessionId.isEmpty || sessionId == currentSessionId
        guard isCurrent else { return }

        guard trimmed != fullClaudeResponse else { return }
        fullClaudeResponse = String(trimmed.prefix(8000))
        lastClaudeResponse = snippet
        if completedQueue.isEmpty {
            claudeActionStatus = "replying"
        }
        lastClaudeResponseAt = Date()
        lastHookAt = Date()
    }

    var idleTitle: String {
        "\(Self.statusEntityName) · \(claudeActionStatus)"
    }

    /// True while Claude is mid-task — drives the pulsing status dot. Idle,
    /// finished, and "last reply" states are steady (not pulsing).
    var isClaudeWorking: Bool { Self.isWorking(status: claudeActionStatus) }

    /// Shared definition of "mid-task" so the global dot and per-session rows
    /// agree. Idle, finished, and "last reply" states are steady.
    static func isWorking(status: String) -> Bool {
        switch status {
        case "ready", "done", "last reply": return false
        default: return true
        }
    }

    // MARK: - Live sessions

    /// Sessions that have fired a hook recently enough to still be considered
    /// alive, newest first. Filters out anything past the project-stale window.
    var activeSessions: [LiveSession] {
        let cutoff = Date().addingTimeInterval(-projectStaleAfter)
        return sessions.values
            .filter { $0.lastHookAt > cutoff }
            .sorted { $0.lastHookAt > $1.lastHookAt }
    }

    var activeSessionCount: Int { activeSessions.count }

    var workingSessionCount: Int {
        activeSessions.filter { Self.isWorking(status: $0.status) }.count
    }

    /// Create-or-update the session entry for `id` (falling back to `cwd` when
    /// no session_id was supplied), then apply `mutate`. Stamps lastHookAt and
    /// bounds the dict so it can't grow without limit.
    ///
    /// `authoritativeCwd` must be true ONLY for the per-request metadata call,
    /// which carries this session's real cwd. The activity/prompt/response
    /// helpers fall back to the global `currentCwd`, which can belong to a
    /// *different* session — so they must NOT rewrite an existing entry's cwd,
    /// or two concurrent sessions cross-contaminate each other's project label.
    /// `create` must be true ONLY for the per-request metadata call. The
    /// activity/prompt/response helpers pass false so a stale transcript poll
    /// can't resurrect a session that already ended (SessionEnd removed it).
    private func upsertSession(id rawId: String, cwd: String, authoritativeCwd: Bool = false, create: Bool = false, _ mutate: (inout LiveSession) -> Void) {
        var normCwd = cwd
        while normCwd.count > 1, normCwd.hasSuffix("/") { normCwd.removeLast() }
        let key = !rawId.isEmpty ? rawId : normCwd
        guard !key.isEmpty else { return }
        if sessions[key] == nil, !create { return }

        var session = sessions[key] ?? LiveSession(
            id: key,
            cwd: normCwd,
            project: (normCwd as NSString).lastPathComponent,
            status: "ready",
            activity: "",
            lastResponse: "",
            fullResponse: "",
            originatorBundleID: nil,
            lastHookAt: Date()
        )
        if authoritativeCwd, !normCwd.isEmpty {
            session.cwd = normCwd
            session.project = (normCwd as NSString).lastPathComponent
        }
        mutate(&session)
        session.lastHookAt = Date()
        sessions[key] = session

        if sessions.count > sessionsMax {
            let drop = sessions.values
                .sorted { $0.lastHookAt < $1.lastHookAt }
                .prefix(sessions.count - sessionsMax)
                .map(\.id)
            for k in drop { sessions.removeValue(forKey: k) }
        }
    }

    private static func statusSnippet(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let currentLine = lines.reversed().first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? text
        let compact = currentLine
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(compact.prefix(240))
    }

    private static func statusLabel(fromActivity label: String) -> String {
        let tool = label.split(separator: ":", maxSplits: 1).first.map(String.init) ?? label
        switch tool {
        case "Bash":                  return "running Bash"
        case "Read":                  return "reading"
        case "Edit", "MultiEdit":     return "editing"
        case "Write", "NotebookEdit": return "writing"
        case "Grep", "Glob", "LS":    return "searching files"
        case "WebFetch":              return "fetching"
        case "WebSearch":             return "searching web"
        case "TodoWrite":             return "updating todos"
        case "Task", "TaskCreate":    return "delegating"
        case "TaskUpdate":            return "tracking task"
        case "TaskList", "TaskGet":   return "checking tasks"
        case "ExitPlanMode":          return "waiting approval"
        default:
            let clean = tool.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? "working" : "using \(clean)"
        }
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
        composePurpose = .message
        composeContextLabel = nil
        composeProjectCwd = project
        // Resolve the active-terminal target NOW, before we become key —
        // otherwise frontmost might briefly become ClaudeNotch.
        composeTarget = pickComposeTarget()
        isComposing = true
        recompute()
    }

    /// Open the composer pointed at a finished session, so the user can reply
    /// without alt-tabbing. Types into the terminal that ran the session when
    /// we know it; otherwise opens a fresh terminal in the project folder.
    func beginReply(to task: CompletedTask) {
        // Drop the completed card we're replying to so it doesn't pop back up
        // when the composer closes.
        completedQueue.removeAll { $0.id == task.id }
        composeText = ""
        composeError = nil
        composePurpose = .message
        let project = (task.cwd as NSString).lastPathComponent
        composeContextLabel = project.isEmpty ? nil : project
        if let bid = task.originatorBundleID, !bid.isEmpty,
           !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
            composeProjectCwd = nil
            composeTarget = bid
        } else if !task.cwd.isEmpty {
            composeProjectCwd = task.cwd
            composeTarget = pickComposeTarget()
        } else {
            composeProjectCwd = nil
            composeTarget = pickComposeTarget()
        }
        isComposing = true
        recompute()
    }

    /// Open the composer to deny a held permission with a note. Reuses the
    /// compose editor (key window + focus + ⌘↩/⎋ handling) instead of trying to
    /// host a text field inside the always-non-key permission card.
    func beginDenyReason(for req: PermissionRequest) {
        composeText = ""
        composeError = nil
        composeProjectCwd = nil
        composeTarget = nil
        composeContextLabel = nil
        composePurpose = .denyReason(req)
        isComposing = true
        recompute()
    }

    func setComposeProject(_ cwd: String?) {
        composeProjectCwd = cwd
        composeError = nil
    }

    func sendCompose() {
        // Deny-with-reason mode: resolve the held permission instead of typing
        // into a terminal. An empty note just denies (same as a plain deny).
        if case .denyReason(let req) = composePurpose {
            let note = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
            isComposing = false
            composePurpose = .message
            composeText = ""
            composeError = nil
            resolvePermission(req, decision: .deny, reason: note.isEmpty ? nil : note)
            return
        }

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
            // Typing into a terminal needs Accessibility. Don't fail silently —
            // pop the system prompt + open Settings, and keep the composer open
            // (with the text) so the user can grant it and hit Send again.
            promptAccessibility()
            composeError = "ClaudeNotch needs Accessibility to type into your terminal. I opened System Settings — enable ClaudeNotch there, then press Send again. (Or pick a project above to open a fresh terminal instead.)"
            return
        }
        TerminalAutomator.sendText(text, toBundleID: bid)
        playSound("Tink")
        cancelCompose()
    }

    /// Pop the macOS Accessibility prompt and jump to the right Settings pane.
    func promptAccessibility() {
        TerminalAutomator.requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func cancelCompose() {
        let target = composeTarget
        let wasDeny = composePurpose != .message
        composeText = ""
        isComposing = false
        composePurpose = .message
        composeError = nil
        composeTarget = nil
        composeProjectCwd = nil
        composeContextLabel = nil
        recompute()
        // Cancelling a deny-reason returns to the still-queued permission card,
        // which is interactive — don't hand the keyboard back to the terminal.
        if !wasDeny { returnKeyboardToTerminal(preferred: target) }
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
        detailResponseText = fullClaudeResponse
        detailProject = currentProject
        isResponseDetailOpen = true
        recompute()
    }

    /// Show a specific session's last reply (from tapping its row in the
    /// multi-session list). No-op if that session hasn't replied yet.
    func showSessionResponse(_ session: LiveSession) {
        guard !session.fullResponse.isEmpty else { return }
        detailResponseText = session.fullResponse
        detailProject = session.project
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

    /// Save the full activity log to a user-chosen file. Writes CSV when the
    /// chosen name ends in `.csv`, otherwise pretty JSON. The app is an
    /// LSUIElement (no Dock icon), so we activate first or the save panel
    /// never comes forward.
    func exportHistory() {
        guard !history.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export Activity History"
        panel.nameFieldStringValue = "claudenotch-history.json"
        panel.allowedContentTypes = [.json, .commaSeparatedText]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            returnKeyboardToTerminal()
            return
        }
        let csv = url.pathExtension.lowercased() == "csv"
        let data = csv ? Self.historyCSV(history) : Self.historyJSON(history)
        try? data.write(to: url, options: .atomic)
        returnKeyboardToTerminal()
    }

    private static func outcomeString(_ o: HistoryEntry.Outcome) -> String {
        switch o {
        case .allowed:          return "allowed"
        case .denied:           return "denied"
        case .dismissed:        return "dismissed"
        case .answered(let n):  return "answered(\(n))"
        case .info:             return "info"
        case .dangerous:        return "dangerous"
        }
    }

    private static func historyJSON(_ entries: [HistoryEntry]) -> Data {
        let iso = ISO8601DateFormatter()
        let rows: [[String: String]] = entries.map { e in
            ["timestamp": iso.string(from: e.timestamp),
             "kind": e.kind.rawValue,
             "tool": e.toolName,
             "title": e.title,
             "detail": e.detail,
             "project": e.project,
             "outcome": outcomeString(e.outcome)]
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(rows)) ?? Data()
    }

    private static func historyCSV(_ entries: [HistoryEntry]) -> Data {
        let iso = ISO8601DateFormatter()
        func esc(_ s: String) -> String {
            guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["timestamp,kind,tool,title,detail,project,outcome"]
        for e in entries {
            lines.append([iso.string(from: e.timestamp), e.kind.rawValue, e.toolName,
                          e.title, e.detail, e.project, outcomeString(e.outcome)]
                .map(esc).joined(separator: ","))
        }
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
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
        staleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkStale() }
        }
    }

    /// A session is dead if its terminal app has quit (so a Stop hook will
    /// never come — e.g. the user killed the terminal mid-run) or it has gone
    /// silent past the stale window.
    private func isSessionDead(_ s: LiveSession, cutoff: Date) -> Bool {
        if s.lastHookAt <= cutoff { return true }
        if let bid = s.originatorBundleID, !bid.isEmpty,
           NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
            return true
        }
        return false
    }

    /// After one or more sessions are removed, keep the global "current" mirror
    /// honest: if the session it pointed at is gone, re-point at the newest
    /// survivor, or collapse the notch to idle when nothing is left.
    private func resyncCurrentSession() {
        // Still pointing at a live session? Nothing to do. Prefer the session-id
        // identity (cwd can be shared by two terminals in the same project).
        let currentAlive = (!currentSessionId.isEmpty && sessions[currentSessionId] != nil)
            || (currentSessionId.isEmpty && sessions.values.contains { $0.cwd == currentCwd })
        guard !currentAlive else { return }
        if let newest = activeSessions.first {
            currentSessionId = newest.id
            currentCwd = newest.cwd
            currentProject = newest.project
            lastActivity = newest.activity
            claudeActionStatus = newest.status
            lastClaudeResponse = newest.lastResponse
            fullClaudeResponse = newest.fullResponse
            currentContextPercent = newest.contextPercent
            currentCostUSD = newest.sessionCostUSD
            currentModel = newest.model
        } else {
            currentSessionId = ""
            currentProject = ""
            currentCwd = ""
            lastActivity = ""
            lastUserPrompt = ""
            claudeActionStatus = lastClaudeResponse.isEmpty ? "ready" : "last reply"
            lastHookAt = nil
            currentContextPercent = 0
            currentCostUSD = 0
            currentModel = ""
        }
    }

    /// A Claude Code session ended (SessionEnd hook — Ctrl+C / Ctrl+D / exit).
    /// Drop it immediately instead of waiting for the stale window.
    func removeSession(sessionId: String, cwd: String = "") {
        var keys: [String] = []
        if !sessionId.isEmpty, sessions[sessionId] != nil { keys.append(sessionId) }
        var normCwd = cwd
        while normCwd.count > 1, normCwd.hasSuffix("/") { normCwd.removeLast() }
        if !normCwd.isEmpty, sessions[normCwd] != nil { keys.append(normCwd) }
        guard !keys.isEmpty else { return }
        for k in keys { sessions.removeValue(forKey: k) }
        resyncCurrentSession()
        if sessions.isEmpty {
            staleTimer?.invalidate()
            staleTimer = nil
        }
    }

    private func checkStale() {
        // Drop sessions whose terminal has been killed/closed, or that have
        // gone silent past the stale window, so the per-session list reflects
        // only what's actually running.
        let sessionCutoff = Date().addingTimeInterval(-projectStaleAfter)
        let dead = sessions.filter { isSessionDead($0.value, cutoff: sessionCutoff) }.map(\.key)
        if !dead.isEmpty {
            for k in dead { sessions.removeValue(forKey: k) }
            resyncCurrentSession()
            if sessions.isEmpty {
                staleTimer?.invalidate()
                staleTimer = nil
                return
            }
        }

        guard let last = lastHookAt else { return }
        let age = Date().timeIntervalSince(last)
        if age > projectStaleAfter {
            // Full clear — terminal is almost certainly closed.
            currentProject = ""
            currentCwd = ""
            lastActivity = ""
            lastUserPrompt = ""
            claudeActionStatus = lastClaudeResponse.isEmpty ? "ready" : "last reply"
            lastHookAt = nil
            staleTimer?.invalidate()
            staleTimer = nil
        } else if age > activityStaleAfter {
            // Just drop the volatile fields.
            if !lastActivity.isEmpty { lastActivity = "" }
            if !lastUserPrompt.isEmpty { lastUserPrompt = "" }
            if !lastClaudeResponse.isEmpty {
                claudeActionStatus = "last reply"
            }
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
            req.resolver(.allow, nil)
            return
        }

        // Auto-approve mode: allow immediately and show a brief, button-less
        // "live activity" card of what's changing. Dangerous commands are
        // exempt — they still require an explicit hold-to-confirm.
        if !bypassRules, autoApprove, req.kind == .toolUse, !req.isDangerous {
            req.resolver(.allow, nil)
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
                resolver: { decision, reason in
                    prev(decision, reason)
                    req.resolver(decision, reason)
                }
            )
            newReq.groupCount = last.groupCount + 1
            newReq.originalDetail = last.originalDetail ?? last.detail
            permissionQueue[permissionQueue.count - 1] = newReq
            // Re-point the native notification at the merged request so its
            // count stays accurate and its action resolves the live item.
            if mirrorToNotificationCenter {
                permissionMirror?.withdraw(last.id)
                permissionMirror?.mirror(newReq)
            }
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
        // Mirror blocking cards to native notifications (lock screen / other
        // Space; auto-suppressed during Focus). Notifications aren't blocking,
        // so they don't need a remote-actionable surface.
        if req.kind == .toolUse, mirrorToNotificationCenter {
            permissionMirror?.mirror(req)
        }
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
        claudeActionStatus = "done"
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

    func resolveCurrentPermission(_ decision: PermissionDecision, alwaysAllow: AllowScope = .none, reason: String? = nil) {
        guard let first = permissionQueue.first else { return }
        resolvePermission(first, decision: decision, alwaysAllow: alwaysAllow, reason: reason)
    }

    /// Resolve a specific queued request (not necessarily the head). Used by the
    /// deny-with-reason flow, which resolves the request the composer was opened
    /// for, and by resolveCurrentPermission for the common head case.
    func resolvePermission(_ req: PermissionRequest, decision: PermissionDecision, alwaysAllow: AllowScope = .none, reason: String? = nil) {
        guard let idx = permissionQueue.firstIndex(where: { $0.id == req.id }) else { return }
        permissionQueue.remove(at: idx)
        // Pull any mirrored notification — whether resolved here or from its own
        // action (idempotent: a no-op if nothing was posted).
        permissionMirror?.withdraw(req.id)
        if decision == .allow {
            switch alwaysAllow {
            case .none:
                break
            case .tool:
                allowRules.insert(AllowRule(tool: req.toolName, commandRegex: nil))
                schedulePersist()
            case .exactCommand:
                let escaped = NSRegularExpression.escapedPattern(for: req.detail)
                allowRules.insert(AllowRule(tool: req.toolName, commandRegex: "^\(escaped)$"))
                schedulePersist()
            }
        }
        // Grouped requests fold N tool calls into one card — count each one so
        // the decision tally matches the tool tally (recorded per request).
        if req.kind == .toolUse, req.source != "Demo" {
            for _ in 0..<max(1, req.groupCount) { recordDecision(decision, auto: false) }
        }
        req.resolver(decision, reason)
        // Notifications were already logged at enqueue time.
        if req.kind != .notification {
            let outcome: HistoryEntry.Outcome
            switch decision {
            case .allow: outcome = req.isDangerous ? .dangerous : .allowed
            case .deny:  outcome = .denied
            case .ask:   outcome = .dismissed
            }
            let detail = (reason?.isEmpty == false) ? "\(req.detail)  (reason: \(reason!))" : req.detail
            appendHistory(HistoryEntry(
                timestamp: Date(),
                kind: .permission,
                toolName: req.toolName,
                title: req.title,
                detail: detail,
                project: (req.cwd as NSString).lastPathComponent,
                outcome: outcome
            ))
        }
        playFeedback(for: decision)
        recompute()
        returnKeyboardToTerminal(preferred: req.originatorBundleID)
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
            if req.kind == .toolUse, req.source != "Demo" {
                for _ in 0..<max(1, req.groupCount) { recordDecision(decision, auto: false) }
            }
            permissionMirror?.withdraw(req.id)
            req.resolver(decision, nil)
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
        claudeActionStatus = "thinking"
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
