import Foundation

// The value types behind a session: tool previews, the live session, and the archived record.

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
    // Cumulative tokens this session has burned, as the agent reports them.
    // Only Codex fills this in: it publishes no token pricing, so tokens are
    // the only honest unit to budget a Codex session in. 0 = not reported.
    var totalTokens: Int = 0
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

    // What THIS turn did, for CompletionAudit. Separate from touchedFiles,
    // which accumulates across the whole session: the audit asks whether the
    // reply that just landed is backed by the work that just happened, so a
    // file edited twenty minutes ago is not evidence. Reset on each new prompt.
    var turnFilesEdited: Int = 0
    /// Any Bash run this turn. Not proof that work happened, but it means
    /// "nothing changed" cannot be proven either, so the audit stays quiet.
    var turnRanCommand: Bool = false
    var turnRanTests: Bool = false
    /// Nil when nothing ran or the outcome could not be read. Only ever set to
    /// true on an explicit failure signal, never inferred from silence.
    var turnTestFailed: Bool? = nil

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

    /// A copy with any credential in its text replaced.
    ///
    /// A history entry is the most persistent copy of a command the app keeps:
    /// it goes into `state.json` and stays for five hundred entries, and it is
    /// what the CSV and JSON exports are built from. Redacting it on the way in
    /// covers the drawer, the settings page, the file and every export at once,
    /// rather than at four render sites that can each be forgotten.
    func redacted() -> HistoryEntry {
        HistoryEntry(id: id, timestamp: timestamp, kind: kind, toolName: toolName,
                     title: SecretRedactor.redact(title),
                     detail: SecretRedactor.redact(detail),
                     project: project, outcome: outcome)
    }

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
