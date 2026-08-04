import Foundation
import AppKit

// The things the notch asks you about: permissions, questions, allow rules, and completed tasks.

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
    func sendCompletion(project: String, snippet: String, agentName: String,
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
    /// Who to name as having finished: the agent that ran the turn, or the
    /// user's custom notch title. Carried on the task so the native banner
    /// says the same thing the card does.
    let entityName: String
    /// Whether the turn did what its closing message said it did. `.silent`
    /// for the ordinary case, which is most of them.
    var audit: CompletionAudit.Verdict = .silent

    init(title: String, detail: String, source: String, cwd: String,
         originatorBundleID: String? = nil, entityName: String = "Claude") {
        self.title = title
        self.detail = detail
        self.source = source
        self.cwd = cwd
        self.originatorBundleID = originatorBundleID
        self.entityName = entityName
    }

    static func == (lhs: CompletedTask, rhs: CompletedTask) -> Bool {
        lhs.id == rhs.id
    }
}

/// What the first segment of the notch title shows. `.claude` is the default
/// "Claude"; `.project` tracks the active project name; `.custom` is a
/// user-typed label.
