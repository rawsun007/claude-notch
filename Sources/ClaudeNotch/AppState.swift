import Foundation
import AppKit
import UniformTypeIdentifiers

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
    // When this session first appeared. Stable for the session's lifetime, so
    // the notch can order rows by it without them reshuffling every time a hook
    // bumps `lastHookAt` (which happens every second for an active session).
    var createdAt: Date
    // Task progress for the current task list. Tracked as sets (keyed by task
    // id) so duplicate Created/Completed events dedup themselves. In-memory
    // only — sessions aren't persisted, so no Codable concern.
    var createdTaskIds: Set<String> = []
    var completedTaskIds: Set<String> = []
    // TodoWrite checklist counts (the to-do list shown in the terminal). Sent
    // whole on every TodoWrite call, so these are just the latest snapshot.
    // Preferred over the TaskCreate/Update sets when present, because that is
    // the list most sessions actually use.
    var todoTotal: Int = 0
    var todoDone: Int = 0
    // Live subagent count: incremented on SubagentStart, decremented on SubagentStop.
    // Stays > 0 while any agent is still running, so the badge survives tool-activity
    // updates that would otherwise overwrite a plain activity-label approach.
    var runningAgentCount: Int = 0
    var toolCallCount: Int = 0

    var taskTotal: Int { todoTotal > 0 ? todoTotal : createdTaskIds.count }
    var taskDone: Int { todoTotal > 0 ? todoDone : completedTaskIds.count }

    // Claude Code's own cost for this session, and the code it has changed.
    //
    // `sessionCostUSD` below is an ESTIMATE the app computes from the transcript
    // at public per-token prices. This is the figure Claude Code itself reports.
    // Where it exists it wins: an estimate is what you use when you cannot have
    // the real number, and here we can.
    var reportedCostUSD: Double = 0
    var linesAdded: Int = 0
    var linesRemoved: Int = 0

    /// What to show. The reported cost if Claude Code gave us one, else our own.
    var displayCostUSD: Double { reportedCostUSD > 0 ? reportedCostUSD : sessionCostUSD }

    // Live context + cost meter, parsed from this session's transcript usage.
    var contextPercent: Double = 0   // 0...1 of the context window in use now
    var contextTokens: Int = 0       // raw input-side tokens (for re-deriving % on override)
    // The window Claude Code reported for this session (0 = never reported, so
    // the app has to infer it). Only the status line carries this.
    var contextWindow: Int = 0
    var sessionCostUSD: Double = 0   // cumulative estimated cost so far
    var model: String = ""           // most recent model id (e.g. claude-opus-4-8)
    var isCompacting: Bool = false   // true between PreCompact and the next event
    // Claude Code permission mode from hook payloads (default / plan /
    // acceptEdits / auto / dontAsk / bypassPermissions). Non-default modes get
    // a badge in the notch so a bypass session is never invisible.
    var permissionMode: String = ""
    // Session title: what `/rename` set. Comes from the SessionStart hook, and
    // from the status line thereafter (a session can be renamed at any point).
    var title: String = ""
    // Git worktree this session is in, when it is in a linked one. Two sessions
    // in the same repo are otherwise identical in the list.
    var worktree: String = ""
    // The background agent this session IS, if it is one (`claude --bg`). A
    // background agent has no terminal, so the row has to say so and offer to
    // attach — otherwise it looks exactly like a session you are sitting in.
    var backgroundAgentId: String = ""
    var backgroundIntent: String = ""
    // True while a background agent is BLOCKED waiting for you. This is the worst
    // case the app knows about: it is stuck, and it has no terminal to be stuck
    // in front of, so nothing else on the machine will tell you.
    var agentNeedsInput: Bool = false
    // The open PR for this session's branch, resolved by Claude Code (the app
    // would otherwise have to shell out to `gh` to know it exists).
    var prNumber: Int = 0
    var prURL: String = ""
    var prState: String = ""     // approved / pending / changes_requested / draft
    // Files Claude edited or wrote this session (ordered, unique, newest
    // last, capped). Drives the "N files" chip + Files Touched menu.
    var touchedFiles: [String] = []
    // Checked-out git branch of cwd (read from .git/HEAD, cached). Empty when
    // not a repo.
    var gitBranch: String = ""

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

/// Per-session summary archived when a session ends (Stop / SessionEnd / stale).
/// Persisted so the history panel survives app restarts.
struct SessionRecord: Identifiable, Codable {
    var id: UUID = UUID()
    let sessionKey: String   // session_id or normalized cwd
    let project: String
    let cwd: String
    let startedAt: Date
    var endedAt: Date?
    var contextTokens: Int = 0
    var costUSD: Double = 0
    var toolCallCount: Int = 0
    var model: String = ""
    // Optional so snapshots written before these existed still decode (a
    // non-optional new key would make the whole history array fail to decode).
    var linesAdded: Int? = nil
    var linesRemoved: Int? = nil
    // A one-line human summary of what the session was about — the session's
    // /rename title if it has one, else the first line of its last reply. This
    // is what makes the history searchable and scannable ("what did I do in
    // project X last week") instead of a wall of cost figures.
    var summary: String? = nil
    var filesTouched: Int? = nil
    var gitBranch: String? = nil
    var agent: String? = nil   // "claude" / "codex", inferred from the model

    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
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

/// Set on a request that the budget hard-stop is holding back: the relevant
/// cap is already exceeded and enforcement is on, so the card forces a decision
/// (Deny / Allow once / Raise cap) instead of letting it auto-allow.
struct BudgetBlock: Equatable {
    let scope: String    // "session" or "daily"
    let cost: Double
    let cap: Double
    var pct: Int { cap > 0 ? Int((cost / cap * 100).rounded()) : 0 }
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
    // Non-nil when the budget hard-stop is holding this request (cap exceeded
    // + enforcement on). Drives the budget framing + Raise-cap button.
    var budgetBlock: BudgetBlock? = nil

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
struct DailySpendSummary {
    var costUSD: Double
    var sessionCount: Int
    var topProject: String
    var totalTokens: Int
}

@MainActor protocol PermissionMirroring: AnyObject {
    func mirror(_ req: PermissionRequest)
    func withdraw(_ id: UUID)
    func withdrawAll()
    func sendCompletion(project: String, snippet: String,
                        cwd: String, originatorBundleID: String?)
    func sendDigest(_ summary: DailySpendSummary)
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

/// What the first segment of the notch title shows. `.claude` is the default
/// "Claude"; `.project` tracks the active project name; `.custom` is a
/// user-typed label.
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

    @Published private(set) var mode: NotchMode = .idle
    @Published private(set) var permissionQueue: [PermissionRequest] = []
    @Published private(set) var completedQueue: [CompletedTask] = []
    @Published private(set) var questionQueue: [QuestionRequest] = []
    @Published private(set) var allowRules: Set<AllowRule> = []
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
    /// Per-category sound overrides (category key -> sound name). Empty entries
    /// fall back to ToolSoundCategory.defaultSound. Persisted.
    @Published private(set) var perToolSoundMap: [String: String] = [:]
    @Published var persistentNotchDisplay: Bool = false
    // Pet mode: the idle icon is the animated Claude Code mascot, and it lives
    // its own little life in and around the notch while the notch is at rest.
    // Behaviour and pose come from PetEngine; this class only owns the clock,
    // the interaction inputs, and the gate that keeps the pet out of the way.
    @Published var petEnabled: Bool = true
    @Published private(set) var petActivity: PetActivity = .tucked
    /// Cursor offset from the notch's centre in points, clamped by MouseTracker.
    /// Drives the pet's lean and which way it faces.
    @Published var petCursorX: Double = 0
    /// The cursor is resting on the pet: hold it out and give it a heart.
    @Published var petPetting: Bool = false {
        didSet { if petPetting, !oldValue { petPettingSince = Date() } }
    }
    /// A finished task makes the pet celebrate — but only briefly, so a task
    /// that finished ten minutes ago doesn't leave it hopping forever.
    private var petCelebrateUntil: Date = .distantPast
    /// The pet is startled until this instant (a turn died, or you said no).
    private var petStartleUntil: Date = .distantPast
    private var petActivityStart: Date = .distantPast
    private var petActivityDuration: Double = 0
    /// Seconds the current activity spent frozen under the user's cursor.
    /// Subtracted from elapsed time so petting genuinely pauses the timeline.
    private var petHeldSeconds: Double = 0
    private var petPettingSince: Date?
    /// When the pet is next allowed to do something unprompted.
    private var petNextActionAt: Date = .distantPast
    /// A boop interrupts whatever was happening; this is what to go back to.
    private var petInterrupted: (activity: PetActivity, elapsed: Double)?
    /// Boops landed in quick succession. Enough of them and the pet backflips.
    private var petBoopStreak = 0
    private var petLastBoopAt: Date = .distantPast
    private var petTimer: Timer?
    /// Demo mode: an activity was requested from the Demos menu, so it plays
    /// even while Claude is busy (the whole point is to watch it on demand).
    private var petDemoing = false
    private var petDemoQueue: [PetActivity] = []
    private var petRNG = SeededRNG(seed: UInt64(Date().timeIntervalSince1970.bitPattern))
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
    @Published private(set) var lastDigestDate: String? = nil
    // Weekly digest tracking — ISO week key, shown once per week.
    @Published private(set) var lastWeeklyDigestDate: String? = nil

    // Which agent a folder dropped on the notch launches. Default Claude.
    @Published private(set) var dropStartsCodex: Bool = false
    func setDropStartsCodex(_ on: Bool) { dropStartsCodex = on; schedulePersist() }

    // Update-available notch card: shown once per discovered version, so the
    // daily poll doesn't re-card users who chose to ignore an update.
    private var lastUpdateCardVersion: String? = nil

    // Version the user last ran — drives the one-time What's New card after
    // an update. Maintained per release alongside the changelog.
    private var lastSeenVersion: String? = nil
    static let whatsNewHighlights =
        "Reply to Claude from the notification banner · git branch shown per session · optional today-spend readout in the menu bar"

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
    /// The session the notch header is describing. Readable so the session LIST
    /// can avoid repeating what the header already says about it.
    private(set) var currentSessionId: String = ""
    @Published private(set) var lastActivity: String = ""          // "Bash: ls -la" etc.
    @Published private(set) var lastUserPrompt: String = ""
    @Published private(set) var recentProjects: [String] = []      // ordered, deduped cwds (newest first)
    // Project directories the user pinned to the top of the sessions list.
    @Published private(set) var pinnedProjects: Set<String> = []
    // User-given names/notes for sessions, keyed by session id.
    @Published private(set) var sessionNotes: [String: String] = [:]
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
    @Published private(set) var currentContextTokens: Int = 0
    @Published private(set) var currentCostUSD: Double = 0
    @Published private(set) var currentModel: String = ""
    @Published private(set) var currentPermissionMode: String = ""
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
    @Published private(set) var sessionCostCap: Double = 0
    @Published private(set) var dailyCostCap: Double = 0
    // Status-bar caps for the rolling 5-hour and weekly usage bars, used in
    // `.estimatedCost` mode. Non-zero enables the bar.
    @Published private(set) var fiveHourCostCap: Double = 5.0
    @Published private(set) var weeklyCostCap: Double = 50.0
    // Which items appear in the bottom status bar (ordered, max 2). Persisted.
    @Published private(set) var statusBarItems: [StatusBarItem] = [.fiveHourLimit, .weeklyLimit]
    // Context-window denominator selection (Auto / 200K / 1M). Persisted.
    @Published private(set) var contextWindowMode: ContextWindowMode = .auto
    // Real plan-limit usage (0...1), fed by Claude Code's statusLine input via
    // the /statusline route. -1 = no data yet (so the UI can show "—").
    @Published private(set) var fiveHourLimitPercent: Double = -1
    @Published private(set) var weeklyLimitPercent: Double = -1
    /// When each limit window resets. Reported by Claude Code's status line; nil
    /// until one arrives (and for anyone not on a subscription plan).
    @Published private(set) var fiveHourResetAt: Date?
    @Published private(set) var weeklyResetAt: Date?
    /// Warn as a plan limit fills, so hitting it is not a surprise mid-task. On
    /// by default: this is protective and rare (it fires at most twice per window,
    /// at 80% and 95%), the kind of thing you want without opting in.
    @Published var rateLimitWarningsEnabled: Bool = true
    nonisolated static let rateLimitThresholds: [Double] = [0.80, 0.95]
    /// The highest threshold already warned for in the current window, keyed by
    /// that window's reset instant so a fresh window re-arms.
    private var fiveHourWarned: (reset: Date?, level: Double) = (nil, 0)
    private var weeklyWarned: (reset: Date?, level: Double) = (nil, 0)

    func setRateLimitWarningsEnabled(_ on: Bool) {
        rateLimitWarningsEnabled = on
        schedulePersist()
    }

    /// The threshold to warn at, or nil, for a given usage and what has already
    /// been warned this window. Pure so the arming rule is testable.
    nonisolated static func rateLimitWarning(pct: Double, alreadyWarned: Double) -> Double? {
        rateLimitThresholds.last { pct >= $0 && $0 > alreadyWarned }
    }

    private func checkRateLimit(name: String, pct: Double, resetAt: Date?,
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
    @Published private(set) var limitsUpdatedAt: Date?
    // Hard-stop: when on, a tool request whose session/daily cap is already
    // exceeded is held for a decision (Deny / Allow once / Raise cap) instead
    // of being auto-allowed — even under an allow-rule or auto-approve. Off by
    // default (it actively blocks Claude). Persisted.
    @Published var enforceBudget: Bool = false
    // Today's total estimated cost across all sessions, pushed from EventServer.
    @Published private(set) var todayCostUSD: Double = 0
    // Rolling 5-hour and weekly cost totals, recomputed alongside todayCostUSD.
    @Published private(set) var fiveHourCostUSD: Double = 0
    @Published private(set) var weeklyCostUSD: Double = 0
    // Effort level read from ~/.claude/settings.json ("Auto", "Normal", "High", "Low").
    @Published private(set) var currentEffort: String = "Auto"
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

    // Completed-session summaries (newest first, ring-buffered).
    @Published private(set) var sessionHistory: [SessionRecord] = []
    private let sessionHistoryMax = 200
    private var archivedSessionKeys: Set<String> = []

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
            self.perToolSoundMap = snapshot.perToolSoundMap ?? [:]
            self.persistentNotchDisplay = snapshot.persistentNotchDisplay ?? false
            self.petEnabled = snapshot.petEnabled ?? true
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

    // MARK: - Pet mode

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

    var petMood: PetMood { PetEngine.mood(for: petContext) }

    /// 0...1 across the current activity. Frozen while the user is petting, so
    /// scratching the pet's head genuinely stops the clock on its retreat.
    func petProgress(at date: Date = Date()) -> Double {
        guard petActivityDuration > 0 else { return 0 }
        var held = petHeldSeconds
        if let since = petPettingSince { held += date.timeIntervalSince(since) }
        let elapsed = date.timeIntervalSince(petActivityStart) - held
        return min(1, max(0, elapsed / petActivityDuration))
    }

    /// One 4 Hz heartbeat drives everything: it retires finished activities,
    /// tucks the pet away the moment the notch stops being at rest, and starts
    /// the next unprompted performance when its turn comes round. A single
    /// timer (rather than a chain of one-shots) means the pet can always be
    /// interrupted on the very next tick, whatever it was doing.
    private func startPetDriver() {
        guard petEnabled else { return }
        petTimer?.invalidate()
        petNextActionAt = Date().addingTimeInterval(PetEngine.nextDelay(mood: .calm, using: &petRNG))
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.petTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        petTimer = t
    }

    private func petTick() {
        guard petEnabled else {
            if petActivity != .tucked { endPetActivity() }
            return
        }
        let now = Date()
        let ctx = petContext

        // A card opened / Claude started working while the cursor sat on the
        // pet: the pet loses, real content wins. Checked before the petting
        // freeze below, or it would never run. A demo is exempt — it was asked
        // for explicitly, and it's the only way to watch a rare activity.
        if petActivity != .tucked, !petDemoing, !ctx.allowsAutonomy || ctx.isWorking || ctx.isThinking {
            endPetActivity()
            return
        }
        // Being petted freezes the timeline — bank the held time and stop here
        // so nothing else can yank the pet away mid-scratch.
        if petPetting { return }
        if let since = petPettingSince {
            petHeldSeconds += now.timeIntervalSince(since)
            petPettingSince = nil
        }

        if petActivity != .tucked {
            guard petProgress(at: now) >= 1 else { return }
            // Walking the Demos menu's "Play All" list, one activity per turn.
            if petDemoing, !petDemoQueue.isEmpty {
                beginPetActivity(petDemoQueue.removeFirst())
                return
            }
            // A boop interrupted something — put the pet back where it was,
            // at the point in the performance it had reached.
            if let resume = petInterrupted {
                petInterrupted = nil
                beginPetActivity(resume.activity, elapsed: resume.elapsed)
                return
            }
            endPetActivity()
            return
        }

        guard now >= petNextActionAt else { return }
        // "Reduce motion" means the pet stops moving on its own. It still
        // answers a boop — that motion is one the user just asked for.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            petNextActionAt = now.addingTimeInterval(30)
            return
        }
        guard ctx.allowsAutonomy, !ctx.isWorking, !ctx.isThinking else {
            // Not the moment. Check back soon rather than burning the slot.
            // Not the moment (hovering, a card is open, Claude is busy). Check
            // back shortly rather than burning the slot on a full-length delay,
            // which would make the pet vanish for minutes after every hover.
            petNextActionAt = now.addingTimeInterval(5)
            return
        }
        let activity = PetEngine.pickActivity(mood: PetEngine.mood(for: ctx), using: &petRNG)
        guard activity != .tucked else {
            petNextActionAt = now.addingTimeInterval(4)
            return
        }
        beginPetActivity(activity)
    }

    private func beginPetActivity(_ activity: PetActivity, elapsed: Double = 0) {
        petActivityDuration = PetEngine.duration(of: activity, using: &petRNG)
        petActivityStart = Date().addingTimeInterval(-elapsed)
        petHeldSeconds = 0
        petPettingSince = petPetting ? Date() : nil
        petActivity = activity
        if activity == .spiderHang { playSpiderTheme() }
    }

    /// The Spider-Pet's entrance music. Held as a property because a local NSSound
    /// is deallocated the instant the call returns, which cuts it off before a
    /// note plays. Respects the same mute as every other sound.
    private var spiderSound: NSSound?
    private func playSpiderTheme() {
        guard !soundMuted else { return }
        guard let url = Bundle.main.url(forResource: "spiderman-meme-song", withExtension: "mp3") else { return }
        // Stop the previous run before starting a new one, or clicking the demo
        // twice stacks two tracks playing over each other.
        spiderSound?.stop()
        let sound = NSSound(contentsOf: url, byReference: true)
        spiderSound = sound
        sound?.play()
    }

    private func endPetActivity() {
        // Read these before they're reset: the next silence is proportional to
        // the performance that just ended.
        let finished = petActivity
        let lasted = petActivityDuration
        petDemoing = false
        petDemoQueue.removeAll()
        petInterrupted = nil
        petActivity = .tucked
        petActivityDuration = 0
        petHeldSeconds = 0
        petPettingSince = nil
        petPetting = false
        // The Spider-Pet's theme goes with him: when he climbs back into the
        // notch, the music stops instead of playing on to an empty notch.
        if finished == .spiderHang { spiderSound?.stop() }
        petNextActionAt = Date().addingTimeInterval(
            PetEngine.nextDelay(mood: petMood, after: finished, lasting: lasted, using: &petRNG)
        )
    }

    /// The user clicked the pet (or the bare notch). Always answers — a pet
    /// that ignores a poke isn't a pet. Whatever it was doing is resumed
    /// afterwards from the same point, so a boop feels like an interruption
    /// rather than a reset.
    func petBoop() {
        guard petEnabled else { return }
        let now = Date()
        // Boops within a couple of seconds of each other build a streak; the
        // fifth one tips the pet into a backflip. Pause and the streak resets.
        petBoopStreak = now.timeIntervalSince(petLastBoopAt) < 2.0 ? petBoopStreak + 1 : 1
        petLastBoopAt = now
        if petActivity != .tucked, petActivity != .boop, petActivity != .spin, petActivity != .celebrate {
            petInterrupted = (petActivity, petProgress() * petActivityDuration)
        }
        if petBoopStreak >= 5 {
            petBoopStreak = 0
            petInterrupted = nil
            beginPetActivity(.spin)
        } else {
            beginPetActivity(.boop)
        }
    }

    /// A turn just finished: give the pet a couple of seconds to notice and
    /// hop about it, once the notch settles back to idle.
    func petCelebrate() {
        guard petEnabled else { return }
        petCelebrateUntil = Date().addingTimeInterval(8)
        petNextActionAt = Date().addingTimeInterval(1.2)
    }

    /// Something went wrong: a turn died, or you denied a command. The pet jumps.
    /// Immediate, unlike the celebration — a fright has no delay in it.
    ///
    /// The window is generous because a failure usually raises a card, and the
    /// pet is not allowed to perform over a card the user is reading. It has to
    /// still be startled when that card clears, or it would sleep through the
    /// one event it exists to react to.
    func petStartle() {
        guard petEnabled else { return }
        petStartleUntil = Date().addingTimeInterval(14)
        petCelebrateUntil = .distantPast   // a dead turn did not finish
        petNextActionAt = Date()
    }

    /// Demos menu: perform these activities back to back, right now, whatever
    /// else is going on. Turns Pet Mode on if it was off — you asked to see the
    /// pet, so here is the pet.
    func demoPet(_ activities: [PetActivity]) {
        guard let first = activities.first else { return }
        if !petEnabled { setPetEnabled(true) }
        petDemoQueue = Array(activities.dropFirst())
        petDemoing = true
        petInterrupted = nil
        // Starts on the spot: the Demos > Pet rows keep the menu open, so the
        // pet performs in the notch while you pick the next one.
        beginPetActivity(first)
    }

    func setPetEnabled(_ on: Bool) {
        petEnabled = on
        if on {
            startPetDriver()
        } else {
            petTimer?.invalidate()
            petTimer = nil
            endPetActivity()
        }
        schedulePersist()
    }

    /// One-time post-update card: "Updated to vX — <highlights>".
    private func showWhatsNewCard(version: String) {
        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: "Updated to v\(version)",
            detail: Self.whatsNewHighlights,
            toolName: "WhatsNew",
            source: "ClaudeNotch",
            cwd: "",
            resolver: { _, _ in }
        ))
    }

    // MARK: - Usage stats

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// ISO year-and-week key (e.g. "2026-W30"), used to fire the weekly digest
    /// at most once per calendar week. Pure, so it is unit-tested (nonisolated
    /// so the tests can call it off the main actor).
    nonisolated static func weekKey(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        return "\(c.yearForWeekOfYear ?? 0)-W\(c.weekOfYear ?? 0)"
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
            petStartle()
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

    func setCompletionNotificationsEnabled(_ on: Bool) {
        completionNotificationsEnabled = on
        schedulePersist()
    }

    func setDigestNotificationsEnabled(_ on: Bool) {
        digestNotificationsEnabled = on
        schedulePersist()
    }

    func setHideFromScreenCapture(_ on: Bool) {
        hideFromScreenCapture = on
        schedulePersist()
    }

    func setShowSpendInMenuBar(_ on: Bool) {
        showSpendInMenuBar = on
        schedulePersist()
    }

    /// Estimated spend so far today: live sessions' running cost + archived
    /// sessions that started today and are no longer live (a live session's
    /// archived record would double-count, so those are skipped).
    var todaySpendUSD: Double {
        let todayStart = Calendar.current.startOfDay(for: Date())
        let liveKeys = Set(sessions.keys)
        let archived = sessionHistory
            .filter { $0.startedAt >= todayStart && !liveKeys.contains($0.sessionKey) }
            .reduce(0.0) { $0 + $1.costUSD }
        let live = sessions.values.reduce(0.0) { $0 + $1.sessionCostUSD }
        return archived + live
    }

    /// Yesterday's spend aggregated from session history.
    var yesterdaySpend: DailySpendSummary? {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        guard let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart) else { return nil }
        let sessions = sessionHistory.filter { $0.startedAt >= yesterdayStart && $0.startedAt < todayStart }
        guard !sessions.isEmpty else { return nil }
        let cost = sessions.reduce(0.0) { $0 + $1.costUSD }
        let tokens = sessions.reduce(0) { $0 + $1.contextTokens }
        let topProject = Dictionary(grouping: sessions, by: { ($0.project as NSString).lastPathComponent })
            .max(by: { $0.value.count < $1.value.count })?.key ?? ""
        return DailySpendSummary(costUSD: cost, sessionCount: sessions.count,
                                 topProject: topProject, totalTokens: tokens)
    }

    /// Show a one-time notch card when the daily update poll finds a newer
    /// release. Once per version — ignoring an update stays ignored until the
    /// next one ships. (The manual "Check for Updates…" flow shows an alert
    /// instead; this is only for the background poll most users rely on.)
    func showUpdateCard(version: String) {
        guard lastUpdateCardVersion != version else { return }
        lastUpdateCardVersion = version
        schedulePersist()
        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: "Update available: v\(version)",
            detail: "You're on v\(UpdateChecker.shared.currentVersion). Download via the menu bar icon → \"Update available\".",
            toolName: "Update",
            source: "ClaudeNotch",
            cwd: "",
            resolver: { _, _ in }
        ))
    }

    /// Fire the daily spend digest notification if enabled and not yet shown today.
    func fireDigestIfNeeded() {
        guard digestNotificationsEnabled, shouldShowDigest,
              let spend = yesterdaySpend else { return }
        permissionMirror?.sendDigest(spend)
        markDigestShown()
    }

    /// Fire a once-a-week roundup card if the daily digest is enabled and this
    /// week hasn't been shown yet. Uses in-memory data only (weekly cost map and
    /// recent session history), and goes through the normal notification card so
    /// it needs no new mirror plumbing. Costs are API-equivalent estimates.
    func fireWeeklyDigestIfNeeded() {
        guard digestNotificationsEnabled else { return }
        let key = Self.weekKey(Date())
        guard lastWeeklyDigestDate != key else { return }

        let cost = weekCostByProject.values.reduce(0, +)
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        let sessions = sessionHistory.filter { $0.startedAt >= weekAgo }.count
            + sessions.count   // include live sessions this week
        guard cost > 0 || sessions > 0 else { return }   // nothing to report

        let topCwd = weekCostByProject.max { $0.value < $1.value }?.key
        let top = topCwd.map { ($0 as NSString).lastPathComponent } ?? ""
        var detail = "\(sessions) session\(sessions == 1 ? "" : "s") this week"
        if cost > 0 { detail += " · ~\(ClaudeUsageReader.fmtMoney(cost)) API-equiv" }
        if !top.isEmpty { detail += " · top: \(top)" }

        lastWeeklyDigestDate = key
        schedulePersist()
        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: "Your week in Claude Code",
            detail: detail,
            toolName: "Digest",
            source: "ClaudeNotch",
            cwd: "",
            resolver: { _, _ in }
        ))
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

    /// Push rolling 5-hour and weekly cost totals for the status bar.
    func noteRollingCosts(fiveHour: Double, weekly: Double) {
        fiveHourCostUSD = fiveHour
        weeklyCostUSD = weekly
    }

    /// Effort read from ~/.claude/settings.json (cheap file read, call off-thread).
    ///
    /// Ignored once the status line has told us the *running* session's effort:
    /// the file says what a new session would start at, the status line says what
    /// this one is actually on, and they disagree the moment you change effort
    /// mid-session. A one-minute settings poll would otherwise keep stomping the
    /// live value back to the stale one.
    func noteEffort(_ effort: String) {
        guard !effortIsLive else { return }
        currentEffort = effort
    }

    /// True once Claude Code has reported the live effort for this session.
    private var effortIsLive = false

    func noteLiveEffort(_ effort: String) {
        guard !effort.isEmpty else { return }
        effortIsLive = true
        currentEffort = effort.prefix(1).uppercased() + effort.dropFirst()
    }

    /// Seed the model from a transcript scan at startup. Only fills in if
    /// the model is still unknown — a hook-driven update takes precedence.
    func noteStartupModel(_ model: String) {
        if currentModel.isEmpty { currentModel = model }
    }

    func setFiveHourCostCap(_ usd: Double) {
        fiveHourCostCap = max(0, usd)
        schedulePersist()
    }

    func setWeeklyCostCap(_ usd: Double) {
        weeklyCostCap = max(0, usd)
        schedulePersist()
    }

    /// Replace the visible status-bar items (max 2, order preserved).
    func setStatusBarItems(_ items: [StatusBarItem]) {
        statusBarItems = Array(items.prefix(2))
        schedulePersist()
    }

    func setContextWindowMode(_ mode: ContextWindowMode) {
        contextWindowMode = mode
        // Re-derive the visible header % from the last known token count so the
        // override takes effect immediately, not only on the next turn.
        if let s = currentSessionId.isEmpty ? nil : sessions[currentSessionId],
           s.contextTokens > 0 {
            let pct = ClaudeUsageReader.contextPercent(tokens: s.contextTokens, model: s.model, mode: mode)
            sessions[currentSessionId]?.contextPercent = pct
            currentContextPercent = pct
            currentContextTokens = sessions[currentSessionId]?.contextTokens ?? 0
        }
        schedulePersist()
    }

    /// Authoritative usage fed by Claude Code's statusLine command (the only
    /// local source of real plan-limit %). Percentages arrive as 0...100.
    func noteStatusLine(sessionId: String, model: String,
                        sessionName: String = "", worktree: String = "",
                        prNumber: Int? = nil, prURL: String = "", prState: String = "",
                        effort: String = "",
                        reportedCostUSD: Double? = nil,
                        linesAdded: Int? = nil, linesRemoved: Int? = nil,
                        contextPct: Double?, contextWindow: Int? = nil, contextTokens: Int? = nil,
                        fiveHourPct: Double?, sevenDayPct: Double?,
                        fiveHourResetsAt: Date? = nil, sevenDayResetsAt: Date? = nil) {
        if let p = fiveHourPct { fiveHourLimitPercent = min(1, max(0, p / 100)) }
        if let p = sevenDayPct { weeklyLimitPercent = min(1, max(0, p / 100)) }
        noteLiveEffort(effort)
        if let d = fiveHourResetsAt { fiveHourResetAt = d }
        if let d = sevenDayResetsAt { weeklyResetAt = d }
        // Warn before a plan limit runs out, so a lockout is not a surprise.
        if let p = fiveHourPct { checkRateLimit(name: "5-hour", pct: p / 100, resetAt: fiveHourResetAt, armed: &fiveHourWarned) }
        if let p = sevenDayPct { checkRateLimit(name: "weekly", pct: p / 100, resetAt: weeklyResetAt, armed: &weeklyWarned) }
        if fiveHourPct != nil || sevenDayPct != nil {
            limitsUpdatedAt = Date()
            schedulePersist()
        }

        // Model update is independent of contextPct — a status line may carry a
        // model string but no context percentage (e.g. early in a session).
        let pct = contextPct.map { min(1, max(0, $0 / 100)) }
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            if let pct { s.contextPercent = pct }
            if !model.isEmpty { s.model = model }
            if let w = contextWindow, w > 0 { s.contextWindow = w }
            if let t = contextTokens, t > 0 { s.contextTokens = t }
            if !sessionName.isEmpty { s.title = sessionName }
            if !worktree.isEmpty { s.worktree = worktree }
            if let pr = prNumber, pr > 0 {
                s.prNumber = pr
                s.prURL = prURL
                s.prState = prState
            }
            if let c = reportedCostUSD, c > 0 { s.reportedCostUSD = c }
            if let l = linesAdded, l > 0 { s.linesAdded = l }
            if let l = linesRemoved, l > 0 { s.linesRemoved = l }
        }
        let isCurrent = currentSessionId.isEmpty || sessionId == currentSessionId
        guard isCurrent else { return }
        if let pct { currentContextPercent = pct }
        if !model.isEmpty { currentModel = model }
        if let c = reportedCostUSD, c > 0 { currentCostUSD = c }
        if let w = contextWindow, w > 0 {
            currentContextWindow = w
            // Remember it per model, so the next session on this model shows the
            // right window from its first frame instead of guessing until the
            // first status line lands.
            if !model.isEmpty, learnedContextWindows[model] != w {
                learnedContextWindows[model] = w
                schedulePersist()
            }
        }
        if let t = contextTokens, t > 0 { currentContextTokens = t }
    }

    /// The context window Claude Code says it is measuring the current session
    /// against. 0 until a status line has been seen.
    @Published private(set) var currentContextWindow: Int = 0

    /// Windows reported by Claude Code, keyed by model id. Persisted, so a fresh
    /// session starts with the true window rather than an inference.
    @Published private(set) var learnedContextWindows: [String: Int] = [:]

    /// The window to measure a session against: what Claude Code reported for it,
    /// else what it reported for this model before, else the inference.
    nonisolated static func windowFor(model: String, reported: Int, learned: [String: Int],
                                      tokens: Int, mode: ContextWindowMode) -> Int {
        if mode == .auto {
            if reported > 0 { return reported }
            if let known = learned[model], known > 0 { return known }
        }
        return ClaudeUsageReader.contextWindow(forModel: model, tokens: tokens, mode: mode)
    }

    /// Demo entry point: show the budget alert card exactly as a real
    /// over-budget event renders it.
    func demoBudgetAlert() {
        warnBudget(scope: "session", level: 100, cost: 27.40, cap: 25)
    }

    /// Demo entry point: show a budget hard-stop card (Deny / Allow once /
    /// Raise cap) for a fake over-cap command.
    func demoBudgetBlock() {
        let req = PermissionRequest(
            kind: .toolUse, title: "Run shell command", detail: "npm run build",
            toolName: "Bash", source: "Demo", cwd: NSHomeDirectory(),
            resolver: { _, _ in })
        req.budgetBlock = BudgetBlock(scope: "session", cost: 10.40, cap: 10)
        permissionQueue.append(req)
        playAlert(toolName: "Bash")
        recompute()
    }

    func setEnforceBudget(_ on: Bool) { enforceBudget = on; schedulePersist() }

    /// Is this tool request over a cap that enforcement should hold back? Daily
    /// is checked first (broader); session uses the originating session's spend.
    func budgetBlock(for req: PermissionRequest) -> BudgetBlock? {
        if dailyCostCap > 0, todayCostUSD >= dailyCostCap {
            return BudgetBlock(scope: "daily", cost: todayCostUSD, cap: dailyCostCap)
        }
        if sessionCostCap > 0 {
            let cost = sessionCost(forCwd: req.cwd)
            if cost >= sessionCostCap {
                return BudgetBlock(scope: "session", cost: cost, cap: sessionCostCap)
            }
        }
        return nil
    }

    /// Best estimate of the spend for the session a request belongs to: the
    /// priciest live session at that cwd, falling back to the global mirror.
    private func sessionCost(forCwd cwd: String) -> Double {
        var c = cwd
        while c.count > 1, c.hasSuffix("/") { c.removeLast() }
        let matching = sessions.values.filter { $0.cwd == c }.map { $0.sessionCostUSD }
        return matching.max() ?? currentCostUSD
    }

    /// Raise the blocked cap above the current spend and allow the held request,
    /// so the flow continues instead of re-blocking on the next call.
    func raiseBudgetAndAllow() {
        guard let req = permissionQueue.first, let block = req.budgetBlock else { return }
        let newCap = Self.nextCap(covering: block.cost, current: block.cap)
        if block.scope == "daily" { setDailyCostCap(newCap) } else { setSessionCostCap(newCap) }
        resolveCurrentPermission(.allow)
    }

    /// Turn enforcement off and allow the held request in one click.
    func disableEnforcementAndAllow() {
        setEnforceBudget(false)
        resolveCurrentPermission(.allow)
    }

    /// Next sensible cap above both the current cap and the spend that tripped
    /// it, so the allow goes through and isn't re-blocked immediately.
    static func nextCap(covering cost: Double, current cap: Double) -> Double {
        let presets: [Double] = [1, 2, 5, 10, 25, 50, 100, 200, 500]
        if let n = presets.first(where: { $0 > cost && $0 > cap }) { return n }
        return (cost / 50).rounded(.down) * 50 + 50   // beyond presets: next $50
    }

    /// The dollar amount the Raise-cap button would set, for its label.
    func raisedCapTarget(for block: BudgetBlock) -> Double {
        Self.nextCap(covering: block.cost, current: block.cap)
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
            sessionHistory: sessionHistory,
            allowRules: allowRules,
            recentProjects: recentProjects,
            // Don't persist a timed auto-approve as a permanent ON — would
            // get stuck on after a restart since the timer is gone.
            autoApprove: autoApprove && autoApproveUntil == nil,
            soundMuted: soundMuted,
            stats: stats,
            alertSound: alertSound,
            perToolSounds: perToolSounds,
            perToolSoundMap: perToolSoundMap,
            persistentNotchDisplay: persistentNotchDisplay,
            petEnabled: petEnabled,
            lastDigestDate: lastDigestDate,
            lastUpdateCardVersion: lastUpdateCardVersion,
            lastSeenVersion: lastSeenVersion,
            sessionCostCap: sessionCostCap,
            dailyCostCap: dailyCostCap,
            fiveHourCostCap: fiveHourCostCap,
            weeklyCostCap: weeklyCostCap,
            requireTouchID: requireTouchID,
            mirrorToNotificationCenter: mirrorToNotificationCenter,
            completionNotificationsEnabled: completionNotificationsEnabled,
            digestNotificationsEnabled: digestNotificationsEnabled,
            hideFromScreenCapture: hideFromScreenCapture,
            showSpendInMenuBar: showSpendInMenuBar,
            enforceBudget: enforceBudget,
            statusBarItems: statusBarItems.map(\.rawValue),
            contextWindowMode: contextWindowMode.rawValue,
            notchTitleMode: notchTitleMode.rawValue,
            customNotchTitle: customNotchTitle,
            learnedContextWindows: learnedContextWindows,
            fiveHourLimitPercent: fiveHourLimitPercent,
            weeklyLimitPercent: weeklyLimitPercent,
            fiveHourResetAt: fiveHourResetAt,
            weeklyResetAt: weeklyResetAt,
            limitsUpdatedAt: limitsUpdatedAt,
            breakRemindersEnabled: breakRemindersEnabled,
            longRunAlertsEnabled: longRunAlertsEnabled,
            rateLimitWarningsEnabled: rateLimitWarningsEnabled,
            pinnedProjects: Array(pinnedProjects),
            sessionNotes: sessionNotes,
            lastWeeklyDigestDate: lastWeeklyDigestDate,
            dropStartsCodex: dropStartsCodex
        ))
    }

    /// Pin or unpin a project directory to the top of the sessions list.
    func togglePinnedProject(_ cwd: String) {
        if pinnedProjects.contains(cwd) { pinnedProjects.remove(cwd) }
        else { pinnedProjects.insert(cwd) }
        schedulePersist()
    }

    /// Set (or clear, when empty) a user-given name for a session.
    func setSessionNote(id: String, _ note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { sessionNotes[id] = nil }
        else { sessionNotes[id] = trimmed }
        schedulePersist()
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
        noteFocusActivity()
        upsertSession(id: sessionId, cwd: c, authoritativeCwd: true, create: true) { s in
            if let bid { s.originatorBundleID = bid }
        }
        refreshGitBranch(cwd: c, sessionId: sessionId)
        ensureStaleTimer()
    }

    // MARK: - Git branch

    // Branch per cwd, re-read at most every 15 s — the file is tiny but hooks
    // arrive every second for an active session.
    private var branchCache: [String: (branch: String, readAt: Date)] = [:]

    private func refreshGitBranch(cwd: String, sessionId: String) {
        let now = Date()
        if let hit = branchCache[cwd], now.timeIntervalSince(hit.readAt) < 15 {
            upsertSession(id: sessionId, cwd: cwd) { s in
                if s.gitBranch != hit.branch { s.gitBranch = hit.branch }
            }
            return
        }
        let branch = Self.readGitBranch(cwd: cwd)
        branchCache[cwd] = (branch, now)
        upsertSession(id: sessionId, cwd: cwd) { s in
            if s.gitBranch != branch { s.gitBranch = branch }
        }
    }

    /// Read the checked-out branch from `.git/HEAD` without running git.
    /// Handles worktrees (`.git` is a file pointing at the real gitdir) and
    /// detached HEADs (short hash). Empty when cwd isn't a repo.
    static func readGitBranch(cwd: String) -> String {
        var gitDir = (cwd as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitDir, isDirectory: &isDir) else { return "" }
        if !isDir.boolValue {
            // Worktree/submodule: ".git" is a file — "gitdir: /path/to/gitdir"
            guard let content = try? String(contentsOfFile: gitDir, encoding: .utf8),
                  let path = content.split(separator: "\n").first?
                      .replacingOccurrences(of: "gitdir:", with: "")
                      .trimmingCharacters(in: .whitespaces), !path.isEmpty else { return "" }
            gitDir = path.hasPrefix("/") ? path : (cwd as NSString).appendingPathComponent(path)
        }
        let headPath = (gitDir as NSString).appendingPathComponent("HEAD")
        guard let head = try? String(contentsOfFile: headPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return "" }
        if head.hasPrefix("ref: refs/heads/") {
            return String(head.dropFirst("ref: refs/heads/".count))
        }
        // Detached HEAD: show a short hash.
        return head.count >= 7 ? String(head.prefix(7)) : head
    }

    /// When the tool named in `lastActivity` started running. Nil when nothing
    /// is running. This is what lets the notch answer the question every long
    /// agent run raises: is it still doing something, and for how long?
    @Published private(set) var activityStartedAt: Date?

    /// "42s" / "3m 05s" — a live run timer, not an age. Seconds matter here:
    /// the whole point is seeing it move.
    nonisolated static func runningDuration(seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        // Past an hour, minutes-only reads as nonsense ("15543m 54s"). Roll up
        // into hours, and into days once a session spans more than one.
        if s < 86_400 { return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60) }
        return String(format: "%dd %02dh", s / 86_400, (s % 86_400) / 3600)
    }

    func noteActivity(_ label: String, sessionId: String = "") {
        // A tool is starting: the turn is live again, so late hooks from the
        // previous turn stop being ignored.
        turnGate.workStarted(TurnGate.key(sessionId: sessionId, cwd: currentCwd))
        lastActivity = label
        activityStartedAt = Date()   // each tool call restarts the run clock
        let status = Self.statusLabel(fromActivity: label)
        claudeActionStatus = status
        lastActivityAt = Date()
        lastHookAt = Date()
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.activity = label
            s.status = status
            s.toolCallCount += 1
        }
        ensureStaleTimer()
    }

    /// Called after a tool completes (PostToolUse) to show Claude is reasoning
    /// before the next tool call. Clears the command strip and sets status to
    /// "thinking" — persists until the next noteActivity call.
    ///
    /// Ignored outright once the turn has ended. A backgrounded Bash reports its
    /// PostToolUse after Stop, and honouring it would strand the notch on
    /// "thinking" with no further hook coming to clear it.
    func noteThinkingBetweenTools(sessionId: String = "") {
        guard !turnGate.isLate(TurnGate.key(sessionId: sessionId, cwd: currentCwd)) else { return }
        claudeActionStatus = "thinking"
        lastActivity = ""
        activityStartedAt = nil
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
    func noteSessionMeter(sessionId: String, contextTokens: Int, costUSD: Double, model: String) {
        let contextPercent = ClaudeUsageReader.contextPercent(
            tokens: contextTokens, model: model, mode: contextWindowMode)
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.contextPercent = contextPercent
            s.contextTokens = contextTokens
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
        currentContextTokens = contextTokens
        // Our estimate must not overwrite Claude Code's own figure. This poll runs
        // constantly, so without the guard the real cost would be replaced by the
        // estimate seconds after every status line delivered it.
        let key = !sessionId.isEmpty ? sessionId : currentCwd
        let reported = sessions[key]?.reportedCostUSD ?? 0
        currentCostUSD = reported > 0 ? reported : costUSD
        if !model.isEmpty { currentModel = model }
    }

    /// Push a Codex session's context/token usage (parsed from its rollout).
    /// Codex sends no status line, so this is how a Codex session gets a live
    /// meter. Uses the real window from the rollout; no dollar cost (unknown
    /// gpt pricing).
    func noteCodexUsage(sessionId: String, cwd: String, contextTokens: Int,
                        contextWindow: Int, model: String, gitBranch: String = "") {
        let pct = contextWindow > 0 ? min(1.0, max(0, Double(contextTokens) / Double(contextWindow))) : 0
        upsertSession(id: sessionId, cwd: cwd.isEmpty ? currentCwd : cwd) { s in
            s.contextTokens = contextTokens
            s.contextWindow = contextWindow
            s.contextPercent = pct
            if !model.isEmpty { s.model = model }
            if !gitBranch.isEmpty { s.gitBranch = gitBranch }
            s.isCompacting = false
        }
        let isCurrent = currentSessionId.isEmpty || sessionId == currentSessionId
        guard isCurrent else { return }
        currentContextPercent = pct
        currentContextTokens = contextTokens
        currentContextWindow = contextWindow
        // Codex has no dollar cost; clear the global mirror so a previous
        // Claude session's cost doesn't bleed onto the Codex header.
        currentCostUSD = 0
        if !model.isEmpty { currentModel = model }
    }

    /// PreCompact: context is about to be compacted. Flag the session so the UI
    /// can show a "compacting" cue; cleared by the next meter/activity update.
    func noteSubagentStarted(sessionId: String = "") {
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.runningAgentCount += 1
        }
    }

    func noteSubagentStopped(sessionId: String = "") {
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.runningAgentCount = max(0, s.runningAgentCount - 1)
        }
    }

    func noteCompacting(sessionId: String = "") {
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.isCompacting = true
            // The pre-compact occupancy is about to be wrong (context shrinks).
            // Drop it now so the bar doesn't sit stale-high until the next turn.
            s.contextPercent = 0
            s.contextTokens = 0
        }
        let isCurrent = currentSessionId.isEmpty || sessionId == currentSessionId
        if isCurrent { currentContextPercent = 0; currentContextTokens = 0 }
    }

    func noteUserPrompt(_ prompt: String, sessionId: String = "") {
        // A new turn: whatever was in flight for the last one is now irrelevant.
        turnGate.workStarted(TurnGate.key(sessionId: sessionId, cwd: currentCwd))
        lastUserPrompt = String(prompt.prefix(140))
        lastClaudeResponse = ""
        fullClaudeResponse = ""
        lastClaudeResponseAt = nil
        claudeActionStatus = "thinking"
        lastHookAt = Date()
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.status = "thinking"
            s.lastResponse = ""
            // A finished checklist belongs to the previous turn. Clear a fully
            // completed task list on a new prompt so its 100% bar does not
            // linger; a still-in-progress list is left alone (the turn may be
            // continuing it) and will refresh on the next TodoWrite.
            if s.todoTotal > 0, s.todoDone >= s.todoTotal {
                s.todoTotal = 0; s.todoDone = 0
            }
            if !s.createdTaskIds.isEmpty, s.completedTaskIds.count >= s.createdTaskIds.count {
                s.createdTaskIds.removeAll(); s.completedTaskIds.removeAll()
            }
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

    /// The TodoWrite checklist changed. Store the whole snapshot (total items,
    /// completed items) on the session; this is what most sessions use, so it
    /// drives the notch task meter.
    func noteTodos(total: Int, done: Int, sessionId: String = "") {
        upsertSession(id: sessionId, cwd: currentCwd, create: true) { s in
            s.todoTotal = max(0, total)
            s.todoDone = min(max(0, done), max(0, total))
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
        let resolvedCwd = cwd.isEmpty ? currentCwd : cwd
        upsertSession(id: sessionId, cwd: resolvedCwd) { s in
            s.status = s.lastResponse.isEmpty ? "done" : "last reply"
        }
        petCelebrate()
        let key = TurnGate.key(sessionId: sessionId, cwd: resolvedCwd)
        // The turn is over: ignore hooks that were already in flight for it.
        turnGate.turnEnded(key)
        if let s = sessions[key] { archiveSession(s) }
    }

    /// SessionStart hook: the session just opened. Sets the model id straight
    /// from the payload — the only pre-transcript source — so the notch shows
    /// the right model from the first second instead of waiting for the first
    /// transcript read or status line. Also captures the session title.
    func noteSessionStart(sessionId: String, cwd: String,
                          model: String, title: String, source: String) {
        upsertSession(id: sessionId, cwd: cwd) { s in
            if !model.isEmpty { s.model = model }
            if !title.isEmpty { s.title = title }
        }
        let isCurrent = currentSessionId.isEmpty || sessionId == currentSessionId
        if isCurrent, !model.isEmpty { currentModel = model }
    }

    /// A file was edited/written by Claude (PostToolUse for Edit / Write /
    /// MultiEdit / NotebookEdit). Kept unique and ordered, newest last.
    func noteFileTouched(_ path: String, sessionId: String, cwd: String) {
        guard !path.isEmpty else { return }
        upsertSession(id: sessionId, cwd: cwd) { s in
            if let i = s.touchedFiles.firstIndex(of: path) {
                s.touchedFiles.remove(at: i)      // re-touch moves to the end
            }
            s.touchedFiles.append(path)
            if s.touchedFiles.count > 50 { s.touchedFiles.removeFirst() }
        }
    }

    /// The session the header is showing, plus any sibling in the same folder,
    /// newest first. A long session that compacts or resumes gets a NEW id and a
    /// fresh, empty entry: its cost and context survive (they are read from the
    /// transcript) but its touched-files and branch, which live in memory per id,
    /// start blank — so the notch would suddenly show no files and no branch
    /// halfway through real work. Falling back to a sibling in the same cwd that
    /// still has them restores that detail across the id change.
    private var currentAndSiblings: [LiveSession] {
        let current = currentSessionId.isEmpty ? nil : sessions[currentSessionId]
        let cwd = current?.cwd
            ?? sessions.values.max(by: { $0.lastHookAt < $1.lastHookAt })?.cwd
        guard let cwd, !cwd.isEmpty else { return current.map { [$0] } ?? [] }
        let inFolder = sessions.values.filter { $0.cwd == cwd }
            .sorted { $0.lastHookAt > $1.lastHookAt }
        // Current first (it is the one being shown), then its folder-mates.
        if let current { return [current] + inFolder.filter { $0.id != current.id } }
        return inFolder
    }

    /// Files touched by the session the notch header is currently showing, or the
    /// most recent sibling in its folder that has any.
    var currentTouchedFiles: [String] {
        for s in currentAndSiblings where !s.touchedFiles.isEmpty { return s.touchedFiles }
        return []
    }

    /// Git branch of the session the notch header is showing, or a sibling's.
    var currentGitBranch: String {
        for s in currentAndSiblings where !s.gitBranch.isEmpty { return s.gitBranch }
        return ""
    }

    /// Record the permission mode carried on every hook payload. Cheap no-op
    /// when unchanged; drives the BYPASS / PLAN / AUTO badge in the notch.
    func notePermissionMode(_ mode: String, sessionId: String, cwd: String) {
        guard !mode.isEmpty else { return }
        upsertSession(id: sessionId, cwd: cwd) { s in
            if s.permissionMode != mode { s.permissionMode = mode }
        }
        let isCurrent = currentSessionId.isEmpty || sessionId == currentSessionId
        if isCurrent, currentPermissionMode != mode { currentPermissionMode = mode }
    }

    /// A turn died from an API-level failure (StopFailure hook: rate limit,
    /// overloaded, billing…). Shows a blocking alert card + native banner so a
    /// long task never dies silently while the user is away.
    func noteStopFailure(title: String, detail: String, cwd: String, sessionId: String) {
        markSessionDone(cwd: cwd, sessionId: sessionId)
        petStartle()
        upsertSession(id: sessionId, cwd: cwd) { s in
            s.status = "error"
        }
        let req = PermissionRequest(
            kind: .notification,
            title: "⚠️ \(title)",
            detail: detail,
            toolName: "StopFailure",
            source: "Claude Code",
            cwd: cwd,
            originatorBundleID: nil,
            resolver: { _, _ in }
        )
        enqueuePermission(req)
        if mirrorToNotificationCenter, !NSApp.isActive {
            let project = (cwd as NSString).lastPathComponent
            permissionMirror?.sendCompletion(
                project: project.isEmpty ? title : "\(project) — \(title)",
                snippet: detail.isEmpty ? title : detail,
                cwd: "", originatorBundleID: nil)   // failures aren't replyable
        }
    }

    // Statuses a session rests in once a turn ends — don't let late transcript
    // polling drag a finished session back into a pulsing "replying" state.
    private static let terminalSessionStatuses: Set<String> = ["done", "last reply", "ready"]

    /// Drops hooks that arrive after their turn already ended — see TurnGate.
    private var turnGate = TurnGate()

    /// Manually wipe the live session info — useful when you closed the
    /// terminal and want the notch to forget what was running there.
    func clearSession() {
        currentProject = ""
        currentCwd = ""
        lastActivity = ""
        activityStartedAt = nil
        lastUserPrompt = ""
        lastClaudeResponse = ""
        claudeActionStatus = "ready"
        lastHookAt = nil
        sessions.removeAll()
        turnGate.reset()
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
        "\(entityName) · \(claudeActionStatus)"
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
    /// alive. Filters out anything past the project-stale window.
    ///
    /// Ordered by `createdAt` (oldest first), NOT `lastHookAt`: liveness is
    /// gauged by lastHookAt but that field updates on every hook, so sorting by
    /// it made the rows swap position every second whenever more than one
    /// session was active. createdAt is fixed for a session's lifetime, so the
    /// rows stay put and a new session simply appears at the bottom. The `id`
    /// tiebreaker keeps the order deterministic if two sessions share a tick.
    var activeSessions: [LiveSession] {
        let cutoff = Date().addingTimeInterval(-projectStaleAfter)
        let live = sessions.values.filter { $0.lastHookAt > cutoff }

        // Collapse phantom rows for the same folder. One physical Claude session
        // can leave more than one entry behind: a hook that arrives before the
        // session_id is known keys a fallback by the cwd (its id is the path), and
        // a session that got a new id (after /clear, a compact, a resume) lingers
        // under the old one until it ages out. Both show as a bare row — no
        // session name, no cost/context meter — beside the real one, same project
        // and same branch.
        //
        // So within a folder, a bare session is treated as a duplicate of a richer
        // one: if any session in a cwd has a name or a live meter, the nameless,
        // meterless siblings for that same cwd are dropped. The current session is
        // always kept, and two sessions that are both real (each with its own name
        // or meter) both stay, because those are genuinely two sessions.
        func isRich(_ s: LiveSession) -> Bool { !s.title.isEmpty || s.hasMeter }
        // Folders that have a real, id-keyed session, and folders that have a rich
        // one (a name or a live meter).
        let idKeyedCwds = Set(live.filter { !$0.id.hasPrefix("/") }.map(\.cwd))
        let richCwds = Set(live.filter(isRich).map(\.cwd))
        let deduped = live.filter { session in
            if session.id == currentSessionId { return true }   // never hide the one in front of you
            // A path-keyed placeholder is a pre-id fallback: drop it the moment any
            // real id-keyed session shares its folder, rich or not.
            if session.id.hasPrefix("/") { return !idKeyedCwds.contains(session.cwd) }
            // A bare id-keyed session (no name, no meter) is a phantom left by an
            // id that changed under one physical session: drop it when a richer
            // session covers the same folder. A rich session always stands.
            if isRich(session) { return true }
            return !richCwds.contains(session.cwd)
        }
        return deduped.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    var activeSessionCount: Int { activeSessions.count }

    var totalRunningAgentCount: Int {
        sessions.values.reduce(0) { $0 + $1.runningAgentCount }
    }

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
            lastHookAt: Date(),
            createdAt: Date()
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
        case "Skill":                 return "loading skill"
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

    /// Send a reply typed into a completion notification's text field. Same
    /// routing as beginReply: type into the terminal that ran the session when
    /// it's still running, else open a fresh terminal in the project folder.
    func sendNotificationReply(_ text: String, cwd: String, originatorBundleID: String?) {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        if let bid = originatorBundleID, !bid.isEmpty,
           !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty,
           TerminalAutomator.isAccessibilityTrusted {
            TerminalAutomator.sendText(msg, toBundleID: bid)
            playSound("Tink")
        } else if !cwd.isEmpty {
            TerminalAutomator.startClaude(in: cwd, message: msg)
            playSound("Tink")
        }
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
        returnToPreviousApp()
    }

    /// Copy the reply currently shown in the detail card (⌘C / Copy button).
    func copyDetailResponse() {
        guard !detailResponseText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(detailResponseText, forType: .string)
    }

    // MARK: - History drawer

    func openHistory() {
        guard !history.isEmpty else { return }
        isHistoryOpen = true
        recompute()
        refreshProjectSpend()
        refreshBackgroundAgents()
    }

    /// Break reminders. Off by default: an unasked-for interruption is the thing
    /// people switch off first, and once it is off you lose every later one too.
    @Published var breakRemindersEnabled: Bool = false
    private var focus = FocusTracker()

    func setBreakRemindersEnabled(_ on: Bool) {
        breakRemindersEnabled = on
        schedulePersist()
    }

    /// Warn when a single tool call has been running a long time. Off by default,
    /// like every other unprompted nudge. This is the answer to the one thing the
    /// whole notch-app ecosystem keeps asking for — "is this long agent run stuck"
    /// — without your having to watch the notch: it fires once, past the
    /// threshold, and does not fire again until a NEW tool call goes long.
    @Published var longRunAlertsEnabled: Bool = false
    static let longRunThreshold: TimeInterval = 5 * 60
    /// The activityStartedAt we have already alerted for, so one stuck tool alerts
    /// once rather than every heartbeat.
    private var longRunAlertedFor: Date?

    func setLongRunAlertsEnabled(_ on: Bool) {
        longRunAlertsEnabled = on
        schedulePersist()
    }

    /// Called on the stale heartbeat. Fires one alert when the running tool passes
    /// the threshold; the flag is keyed to the run's start, so a new tool call
    /// (which resets `activityStartedAt`) can alert again.
    /// Whether a long-run alert should fire right now. Pure so the timing rule
    /// can be pinned without a clock: fires once when a run passes the threshold,
    /// and not again for the same run (keyed by its start).
    nonisolated static func shouldAlertLongRun(enabled: Bool, working: Bool,
                                               startedAt: Date?, alertedFor: Date?,
                                               now: Date, threshold: TimeInterval) -> Bool {
        guard enabled, working, let started = startedAt else { return false }
        guard alertedFor != started else { return false }
        return now.timeIntervalSince(started) >= threshold
    }

    private func checkLongRun() {
        guard Self.shouldAlertLongRun(enabled: longRunAlertsEnabled, working: isClaudeWorking,
                                      startedAt: activityStartedAt, alertedFor: longRunAlertedFor,
                                      now: Date(), threshold: Self.longRunThreshold),
              let started = activityStartedAt else { return }
        let elapsed = Date().timeIntervalSince(started)
        longRunAlertedFor = started
        let minutes = Int(elapsed / 60)
        let req = PermissionRequest(
            kind: .notification,
            title: "Still running — \(minutes)m",
            detail: lastActivity.isEmpty
                ? "This tool call has been going for \(minutes) minutes."
                : "\(lastActivity) has been running for \(minutes) minutes.",
            toolName: "LongRun",
            source: "ClaudeNotch",
            cwd: currentCwd,
            originatorBundleID: nil,
            resolver: { _, _ in }
        )
        enqueuePermission(req)
    }

    /// How long you have been working without a break, in seconds. 0 when you are
    /// on one. Measured from Claude Code's hooks rather than a timer you start:
    /// the app already knows when work is happening.
    var focusStretch: TimeInterval { focus.stretch(now: Date()) }

    /// Called on every hook. Ends the stretch if you have been away, and nudges
    /// once when a stretch gets long.
    private func noteFocusActivity() {
        let now = Date()
        focus.noteActivity(at: now)
        guard breakRemindersEnabled, focus.shouldNudge(now: now) else { return }
        let minutes = Int(focus.stretch(now: now) / 60)
        let req = PermissionRequest(
            kind: .notification,
            title: "\(minutes)m without a break",
            detail: "You have been at this for \(minutes) minutes. Claude will still be here.",
            toolName: "Focus",
            source: "ClaudeNotch",
            cwd: currentCwd,
            originatorBundleID: nil,
            resolver: { _, _ in }
        )
        enqueuePermission(req)
    }

    /// Background agents the Claude Code daemon is currently running.
    ///
    /// They already reach the app as sessions (their hooks fire like any other),
    /// but nothing distinguished them from a session you are sitting in front of,
    /// and a background agent is precisely the thing you are NOT looking at.
    @Published private(set) var backgroundAgents: [BackgroundAgent] = []

    func refreshBackgroundAgents() {
        let agents = BackgroundAgentReader.read()
        guard agents != backgroundAgents else { return }
        backgroundAgents = agents

        // Stamp the sessions we already know about, so their rows can say what
        // they are and what they were asked to do.
        let byId = Dictionary(uniqueKeysWithValues: agents.map { ($0.sessionId, $0) })
        for (key, var session) in sessions {
            guard let agent = byId[session.id] ?? byId[key] else { continue }
            guard session.backgroundAgentId != agent.id else { continue }
            session.backgroundAgentId = agent.id
            session.backgroundIntent = agent.intent
            sessions[key] = session
        }
    }

    /// A background agent said it needs input, or that it finished.
    func noteAgentNotice(_ notice: AgentNotice, sessionId: String) {
        guard !sessionId.isEmpty else { return }
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.agentNeedsInput = (notice == .needsInput)
        }
        // The roster is how we know it is a background agent at all, and a notice
        // is the moment it is most worth being right about.
        refreshBackgroundAgents()
    }

    /// Background agents currently blocked on you.
    var blockedAgents: [LiveSession] {
        sessions.values.filter { $0.agentNeedsInput && !$0.backgroundAgentId.isEmpty }
    }

    /// Open a background agent in a terminal. It has no terminal of its own, so
    /// this is the only way to see it or answer it.
    func attachBackgroundAgent(id: String, cwd: String) {
        // Attaching answers it, so it is no longer waiting on you.
        for (key, var session) in sessions where session.backgroundAgentId == id {
            session.agentNeedsInput = false
            sessions[key] = session
        }
        guard !id.isEmpty else { return }
        TerminalAutomator.attachAgent(id: id, in: cwd)
    }

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
    @Published private(set) var weekCostByProject: [String: Double] = [:]

    /// Spend per calendar day (yyyy-MM-dd), same source. The daily bars used to
    /// be built from the session records, which only exist for sessions the app
    /// happened to be running for and archived — so a week of real work showed up
    /// as one tall bar today and six flat ones.
    @Published private(set) var weekCostByDay: [String: Double] = [:]

    func refreshProjectSpend() {
        Task { [weak self] in
            let usage = await Task.detached { ClaudeUsageReader.compute() }.value
            self?.weekCostByProject = usage.weekByProject.mapValues(\.costUSD)
            self?.weekCostByDay = usage.dailyCostUSD
        }
    }

    func closeHistory() {
        isHistoryOpen = false
        recompute()
        returnToPreviousApp()
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
            returnToPreviousApp()
            return
        }
        let csv = url.pathExtension.lowercased() == "csv"
        let data = csv ? Self.historyCSV(history) : Self.historyJSON(history)
        try? data.write(to: url, options: .atomic)
        returnToPreviousApp()
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

    /// Save the session history to a user-chosen file. CSV when the chosen
    /// name ends in `.csv`, otherwise pretty JSON — same pattern as
    /// exportHistory above.
    func exportSessionHistory() {
        guard !sessionHistory.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export Session History"
        panel.nameFieldStringValue = "claudenotch-sessions.csv"
        panel.allowedContentTypes = [.commaSeparatedText, .json]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            returnToPreviousApp()
            return
        }
        let json = url.pathExtension.lowercased() == "json"
        let data = json ? Self.sessionsJSON(sessionHistory) : Self.sessionsCSV(sessionHistory)
        try? data.write(to: url, options: .atomic)
        returnToPreviousApp()
    }

    private static func sessionsJSON(_ records: [SessionRecord]) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(records)) ?? Data()
    }

    private static func sessionsCSV(_ records: [SessionRecord]) -> Data {
        let iso = ISO8601DateFormatter()
        func esc(_ s: String) -> String {
            guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["started,ended,project,cwd,duration_s,tokens,cost_usd,tool_calls,model"]
        for r in records {
            lines.append([
                iso.string(from: r.startedAt),
                r.endedAt.map(iso.string(from:)) ?? "",
                r.project, r.cwd,
                r.duration.map { String(Int($0)) } ?? "",
                String(r.contextTokens),
                String(format: "%.4f", r.costUSD),
                String(r.toolCallCount),
                r.model,
            ].map(esc).joined(separator: ","))
        }
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    /// Build a "what I shipped" standup from the archived session digests over
    /// the last `days` days, grouped by project: the session summaries, the code
    /// churn and cost, and the actual git commit subjects from each project dir.
    /// Nonisolated + async because it shells out to `git log` per project; call
    /// it off the main actor and put the result on the clipboard.
    nonisolated static func standupText(records: [SessionRecord],
                                        extraDirs: [String] = [],
                                        days: Int) -> String {
        let cal = Calendar.current
        let since = cal.date(byAdding: .day, value: -(max(days, 1) - 1),
                             to: cal.startOfDay(for: Date())) ?? Date()
        let recent = records.filter { $0.startedAt >= since }
        let header: String = {
            let df = DateFormatter(); df.dateFormat = "EEE MMM d"
            if days <= 1 { return "Standup — \(df.string(from: Date()))" }
            return "What I shipped — last \(days) days"
        }()

        // Group session records by project dir (cwd is the stable key), then
        // fold in recent project dirs that have no archived session in the
        // window but DO have commits shipped — otherwise a project you worked on
        // all day but never formally ended a session in goes missing.
        var order: [String] = []
        var byCwd: [String: [SessionRecord]] = [:]
        for r in recent {
            let key = r.cwd.isEmpty ? r.project : r.cwd
            if byCwd[key] == nil { order.append(key) }
            byCwd[key, default: []].append(r)
        }
        for dir in extraDirs where !dir.isEmpty && byCwd[dir] == nil {
            byCwd[dir] = []
            order.append(dir)
        }

        var blocks: [String] = []
        for key in order {
            let rs = byCwd[key] ?? []
            // Session summaries (deduped, non-empty).
            var lines: [String] = []
            var seen = Set<String>()
            for s in rs.compactMap({ $0.summary }) where !s.isEmpty {
                if seen.insert(s.lowercased()).inserted { lines.append("  • \(s)") }
            }
            // Actual commits shipped from this project dir in the window.
            let commits = gitCommits(inDir: key, since: since)
            for c in commits.prefix(8) { lines.append("  · \(c)") }
            // Nothing to say about this project: skip it entirely.
            guard !lines.isEmpty else { continue }

            let label = rs.first?.project ?? (key as NSString).lastPathComponent
            let add = rs.reduce(0) { $0 + ($1.linesAdded ?? 0) }
            let rem = rs.reduce(0) { $0 + ($1.linesRemoved ?? 0) }
            let cost = rs.reduce(0.0) { $0 + $1.costUSD }

            var block = [label] + lines
            var meta: [String] = []
            if add + rem > 0 { meta.append("+\(add) / -\(rem)") }
            if !rs.isEmpty { meta.append("\(rs.count) session\(rs.count == 1 ? "" : "s")") }
            if cost > 0 { meta.append(String(format: "~$%.2f", cost)) }
            if !meta.isEmpty { block.append("  (\(meta.joined(separator: ", ")))") }
            blocks.append(block.joined(separator: "\n"))
        }

        guard !blocks.isEmpty else {
            return header + "\n\nNo sessions or commits in this window."
        }
        return header + "\n\n" + blocks.joined(separator: "\n\n")
    }

    /// Commit subjects authored in `dir` since a date (`git log --since`), merges
    /// excluded. Empty when not a repo or git is unavailable.
    nonisolated private static func gitCommits(inDir dir: String, since: Date) -> [String] {
        guard !dir.isEmpty,
              FileManager.default.fileExists(atPath: dir + "/.git") else { return [] }
        let iso = ISO8601DateFormatter()
        guard let out = Shell.output("/usr/bin/git",
                                     ["-C", dir, "log", "--no-merges",
                                      "--since=\(iso.string(from: since))",
                                      "--pretty=format:%s"]) else { return [] }
        return out.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    fileprivate func appendHistory(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        if history.count > historyMax {
            history = Array(history.prefix(historyMax))
        }
        schedulePersist()
    }

    /// Whether a finished session is worth a row in the history.
    ///
    /// The old rule ("it ran a tool, or it has a project name") let anything
    /// through, because every hook payload carries a cwd and therefore a project
    /// name. Any single stray hook — a probe, a script, a one-off command in a
    /// scratch directory — became a session in the list, which is why the
    /// history filled up with one-second entries named after folders that no
    /// longer exist.
    ///
    /// A session is a session if Claude actually did something in it: it burned
    /// tokens, it cost money, or it changed a file. Everything else is noise.
    nonisolated static func isWorthArchiving(_ session: LiveSession) -> Bool {
        guard isRealProject(session.cwd) else { return false }
        return session.contextTokens > 0 || session.sessionCostUSD > 0 || !session.touchedFiles.isEmpty
    }

    /// The same rule applied to an already-archived row, so history saved under
    /// the old rule gets swept clean on the next launch. A record has no file
    /// list, so the evidence is tokens or money.
    nonisolated static func isWorthKeeping(_ record: SessionRecord) -> Bool {
        guard isRealProject(record.cwd) else { return false }
        return record.contextTokens > 0 || record.costUSD > 0
    }

    /// Whether a working directory is somebody's project, or just a scratch
    /// directory the machine will delete on its own.
    ///
    /// A one-off run in a temp directory is real work — it burns real tokens and
    /// costs real money, so the "did Claude actually do something" rule keeps it —
    /// but it is not a PROJECT. It shows up in the Projects tab next to the
    /// repository you have spent a fortnight in, and it will not exist tomorrow.
    /// Anything the OS owns (/tmp, /private/tmp, /var/folders) is a scratch space,
    /// not a project.
    nonisolated static func isRealProject(_ cwd: String) -> Bool {
        guard !cwd.isEmpty else { return false }
        let path = (cwd as NSString).standardizingPath
        let scratchRoots = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
        for root in scratchRoots where path == root || path.hasPrefix(root + "/") {
            return false
        }
        return true
    }

    /// Write (or rewrite) this session's history row.
    ///
    /// This is called at the end of every *turn*, not only at the end of the
    /// session — Stop fires each time Claude finishes replying. The first cut
    /// archived once and then refused to touch the row again, so a session's
    /// record froze the moment its first turn ended: an afternoon of work was
    /// filed as "27s", with the cost and the tool count from that one turn.
    ///
    /// The row is therefore keyed by the session and updated in place. Its start
    /// stays put, its end moves with the latest turn, and the totals track the
    /// live session, so the duration is the whole session and not its first
    /// breath.
    /// One-line human summary of a session for the searchable history: its
    /// /rename title if it set one, else the first sentence of its last reply.
    /// Trimmed to a scannable length. Nil when there's nothing worth showing.
    static func sessionSummary(_ session: LiveSession) -> String? {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return String(title.prefix(120)) }
        let reply = session.fullResponse.isEmpty ? session.lastResponse : session.fullResponse
        let firstLine = reply
            .split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !firstLine.isEmpty else { return nil }
        return String(firstLine.prefix(120))
    }

    private func archiveSession(_ session: LiveSession) {
        guard Self.isWorthArchiving(session) else { return }
        archivedSessionKeys.insert(session.id)

        if let i = sessionHistory.firstIndex(where: { $0.sessionKey == session.id }) {
            sessionHistory[i].endedAt = Date()
            sessionHistory[i].contextTokens = session.contextTokens
            sessionHistory[i].costUSD = session.sessionCostUSD
            sessionHistory[i].toolCallCount = session.toolCallCount
            sessionHistory[i].model = session.model
            sessionHistory[i].linesAdded = session.linesAdded
            sessionHistory[i].linesRemoved = session.linesRemoved
            // Keep a summary once we have one; a later empty reply shouldn't
            // wipe the title the session already earned.
            if let s = Self.sessionSummary(session) { sessionHistory[i].summary = s }
            sessionHistory[i].filesTouched = session.touchedFiles.count
            if !session.gitBranch.isEmpty { sessionHistory[i].gitBranch = session.gitBranch }
            sessionHistory[i].agent = AgentKind.infer(fromModel: session.model).rawValue
            schedulePersist()
            return
        }

        let record = SessionRecord(
            sessionKey: session.id,
            project: session.project.isEmpty ? "unnamed" : session.project,
            cwd: session.cwd,
            startedAt: session.createdAt,
            endedAt: Date(),
            contextTokens: session.contextTokens,
            costUSD: session.sessionCostUSD,
            toolCallCount: session.toolCallCount,
            model: session.model,
            linesAdded: session.linesAdded,
            linesRemoved: session.linesRemoved,
            summary: Self.sessionSummary(session),
            filesTouched: session.touchedFiles.count,
            gitBranch: session.gitBranch.isEmpty ? nil : session.gitBranch,
            agent: AgentKind.infer(fromModel: session.model).rawValue
        )
        sessionHistory.insert(record, at: 0)
        if sessionHistory.count > sessionHistoryMax {
            sessionHistory = Array(sessionHistory.prefix(sessionHistoryMax))
        }
        schedulePersist()
    }

    func clearSessionHistory() {
        sessionHistory.removeAll()
        archivedSessionKeys.removeAll()
        schedulePersist()
    }

    private func ensureStaleTimer() {
        guard staleTimer == nil else { return }
        staleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkStale()
                self?.checkLongRun()
                // Same heartbeat: an agent can start or die without any hook
                // reaching us (it is a daemon, not a terminal).
                self?.refreshBackgroundAgents()
            }
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
        // Pick the most-recently-active survivor explicitly by lastHookAt.
        // (Don't use activeSessions.first — that list is ordered by createdAt for
        // stable row display, so .first is the oldest session, not the newest.)
        if let newest = activeSessions.max(by: { $0.lastHookAt < $1.lastHookAt }) {
            currentSessionId = newest.id
            currentCwd = newest.cwd
            currentProject = newest.project
            lastActivity = newest.activity
            // Approximate: this session's last hook is the best start we have for
            // a run we did not watch begin. Off by seconds, never by minutes.
            activityStartedAt = newest.activity.isEmpty ? nil : newest.lastHookAt
            claudeActionStatus = newest.status
            lastClaudeResponse = newest.lastResponse
            fullClaudeResponse = newest.fullResponse
            currentContextPercent = newest.contextPercent
            currentContextTokens = newest.contextTokens
            currentCostUSD = newest.sessionCostUSD
            if !newest.model.isEmpty { currentModel = newest.model }
            currentPermissionMode = newest.permissionMode
        } else {
            currentSessionId = ""
            currentProject = ""
            currentCwd = ""
            lastActivity = ""
            activityStartedAt = nil
            lastUserPrompt = ""
            claudeActionStatus = lastClaudeResponse.isEmpty ? "ready" : "last reply"
            lastHookAt = nil
            currentContextPercent = 0
            currentContextTokens = 0
            currentCostUSD = 0
            currentModel = ""
            currentPermissionMode = ""
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
        for k in keys { if let s = sessions[k] { archiveSession(s) } }
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
            for k in dead { if let s = sessions[k] { archiveSession(s) } }
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
            activityStartedAt = nil
            lastUserPrompt = ""
            claudeActionStatus = lastClaudeResponse.isEmpty ? "ready" : "last reply"
            lastHookAt = nil
            staleTimer?.invalidate()
            staleTimer = nil
        } else if age > activityStaleAfter {
            // Just drop the volatile fields.
            if !lastActivity.isEmpty { lastActivity = "" }
            if activityStartedAt != nil { activityStartedAt = nil }
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
        // Budget hard-stop: when enforcement is on and the relevant cap is
        // already exceeded, force a decision before any allow-rule or
        // auto-approve can spend past the cap. The card shows Deny / Allow once
        // / Raise cap.
        if !bypassRules, req.kind == .toolUse, enforceBudget,
           let block = budgetBlock(for: req) {
            req.budgetBlock = block
            if req.source != "Demo" {
                recordToolRequested(req.toolName, dangerousShown: req.isDangerous)
            }
            permissionQueue.append(req)
            playAlert(toolName: req.toolName)
            if mirrorToNotificationCenter { permissionMirror?.mirror(req) }
            recompute()
            return
        }

        if !bypassRules, !req.isDangerous, let matched = allowRules.first(where: { $0.matches(req) }) {
            // Auto-allowed by a rule the user installed earlier. Still
            // log it to history so they can see what we approved silently.
            // Dangerous commands are exempt — even a tool-wide always-allow
            // rule must not skip the hold-to-confirm / Touch ID guardrail.
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

    /// An external agent (Codex, etc.) is starting a tool. That agent owns its
    /// own approval, so we never gate; we pop a brief no-button info card so the
    /// notch shows what is running. When `needsApproval` is true (the agent is
    /// about to prompt for a risky command), the card is framed as a heads-up so
    /// the user knows to go approve it in the agent. Also records session
    /// activity.
    func noteExternalActivity(tool: String, detail: String, needsApproval: Bool = false,
                              dangerReasons: [String] = [], sessionId: String = "") {
        noteActivity(detail.isEmpty ? tool : "\(tool): \(String(detail.prefix(80)))", sessionId: sessionId)
        let title = needsApproval ? "Codex needs your approval" : tool
        let body: String
        if needsApproval {
            body = detail.isEmpty ? "Approve it in Codex" : "\(detail)\n\nApprove or deny it in Codex."
        } else {
            body = detail.isEmpty ? "Running" : detail
        }
        let req = PermissionRequest(
            kind: needsApproval ? .notification : .toolUse,
            title: title,
            detail: body,
            toolName: tool,
            source: "Codex",
            cwd: currentCwd,
            dangerReasons: needsApproval ? dangerReasons : [],
            resolver: { _, _ in })
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
        // Fire a native banner if the user has switched away from the notch.
        if completionNotificationsEnabled, !NSApp.isActive {
            let project = (task.cwd as NSString).lastPathComponent
            permissionMirror?.sendCompletion(project: project, snippet: task.detail,
                                             cwd: task.cwd,
                                             originatorBundleID: task.originatorBundleID)
        }
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
    /// Set for one card-resolve when the resolver itself opens something (e.g.
    /// the drop chooser launches a terminal). Stops the notch from reactivating
    /// the previously-frontmost app, which could be a full-screen app on another
    /// Space and would yank the display there.
    var suppressReturnToApp = false

    func returnKeyboardToTerminal(preferred: String? = nil) {
        if suppressReturnToApp { suppressReturnToApp = false; return }
        switch mode {
        case .permission, .question, .compose, .completed, .responseDetail, .history:
            return   // still interactive — keep keyboard on the notch
        default:
            break
        }
        let bid = preferred ?? lastOriginatorBundleID
        openOriginator(bid)
    }

    /// After the user CLOSES a panel they opened themselves (history, the response
    /// detail, an export), return to whatever app they were actually using —
    /// which is the last app that was frontmost before the notch took focus, not
    /// the terminal that happened to run Claude. Closing history from a
    /// full-screen browser must land you back in that browser, not yank you into
    /// the terminal.
    func returnToPreviousApp() {
        if suppressReturnToApp { suppressReturnToApp = false; return }
        switch mode {
        case .permission, .question, .compose, .completed, .responseDetail, .history:
            return   // another interactive card is still up — keep focus here
        default:
            break
        }
        frontmost.activateLastApp()
    }

    func playSound(_ name: String) {
        guard !soundMuted else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    private func playAlert(toolName: String? = nil) {
        let name: String
        if perToolSounds, let t = toolName {
            name = soundForTool(t)
        } else {
            name = alertSound
        }
        playSound(name)
    }

    /// The user-set (or default) chime for a tool when "Per-tool sounds" is on.
    func soundForTool(_ tool: String) -> String {
        let category = ToolSoundCategory.category(for: tool)
        return perToolSoundMap[category.rawValue] ?? category.defaultSound
    }

    /// Set (or clear, when equal to the default) the sound for a category.
    func setToolSound(_ category: ToolSoundCategory, _ sound: String) {
        if sound == category.defaultSound {
            perToolSoundMap.removeValue(forKey: category.rawValue)
        } else {
            perToolSoundMap[category.rawValue] = sound
        }
        schedulePersist()
    }

    /// The current sound for a category (override or default).
    func toolSound(_ category: ToolSoundCategory) -> String {
        perToolSoundMap[category.rawValue] ?? category.defaultSound
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
        updateReAlertTimer()
    }

    // MARK: - Waiting-on-you re-alert

    // One missed chime shouldn't cost 20 minutes: while a blocking card sits
    // unanswered, keep nudging every `reAlertAfter` — replay the sound, re-post
    // the native notification (same identifier, so it replaces rather than
    // stacks), and request user attention. Capped at `maxReAlerts` nudges per
    // request so it escalates without turning into an endless nag.
    static let reAlertAfter: TimeInterval = 180
    static let maxReAlerts = 3
    private var reAlertTimer: Timer?
    // Per-request nudge bookkeeping: how many times nudged, and when last.
    private var reAlertState: [UUID: (count: Int, lastAt: Date)] = [:]

    private func updateReAlertTimer() {
        let hasPending = permissionQueue.contains { $0.kind == .toolUse } || !questionQueue.isEmpty
        if hasPending, reAlertTimer == nil {
            reAlertTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkReAlert() }
            }
        } else if !hasPending, reAlertTimer != nil {
            reAlertTimer?.invalidate(); reAlertTimer = nil
            reAlertState.removeAll()
        }
    }

    /// True when a request that has waited `reAlertAfter` since it arrived is
    /// also due for its next nudge (never nudged, or last nudge was a full
    /// interval ago) and hasn't used up its nudge budget.
    private func reAlertDue(id: UUID, receivedAt: Date, now: Date) -> Bool {
        guard now.timeIntervalSince(receivedAt) >= Self.reAlertAfter else { return false }
        let s = reAlertState[id]
        guard (s?.count ?? 0) < Self.maxReAlerts else { return false }
        if let last = s?.lastAt, now.timeIntervalSince(last) < Self.reAlertAfter { return false }
        return true
    }

    private func noteReAlert(id: UUID, now: Date) {
        let prior = reAlertState[id]?.count ?? 0
        reAlertState[id] = (prior + 1, now)
    }

    private func checkReAlert() {
        let now = Date()
        for req in permissionQueue where req.kind == .toolUse {
            guard reAlertDue(id: req.id, receivedAt: req.receivedAt, now: now) else { continue }
            noteReAlert(id: req.id, now: now)
            playAlert(toolName: req.toolName)
            if mirrorToNotificationCenter { permissionMirror?.mirror(req) }
            bounceDockForAttention()
            return   // one nudge per tick
        }
        for q in questionQueue {
            guard reAlertDue(id: q.id, receivedAt: q.receivedAt, now: now) else { continue }
            noteReAlert(id: q.id, now: now)
            playAlert()
            bounceDockForAttention()
            return
        }
    }

    /// Ask the OS to draw the user to the app (a critical attention request:
    /// bounces the Dock icon until the app is activated). This is a menu-bar
    /// (LSUIElement) app so there is usually no Dock icon to bounce — the call
    /// is a harmless no-op then, and the replayed sound + re-posted notification
    /// carry the nudge. It still fires for the rare case the app is run with a
    /// Dock presence, and documents the intent in one place.
    private func bounceDockForAttention() {
        NSApp.requestUserAttention(.criticalRequest)
    }

    /// Oldest unanswered blocking request for a session (matched by cwd) —
    /// drives the "waiting Xm" chip on multi-session rows.
    func pendingWaitStart(forCwd cwd: String) -> Date? {
        guard !cwd.isEmpty else { return nil }
        let perm = permissionQueue.first { $0.kind == .toolUse && $0.cwd == cwd }?.receivedAt
        let ques = questionQueue.first { $0.cwd == cwd }?.receivedAt
        switch (perm, ques) {
        case let (p?, q?): return min(p, q)
        case let (p?, nil): return p
        case let (nil, q?): return q
        default: return nil
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
