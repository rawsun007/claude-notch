import Foundation

/// Which coding agent a session belongs to. ClaudeNotch was built around Claude
/// Code's hook contract; other agents (Grok Build, Codex) expose very similar
/// hook events but with different payload key casing and pricing. This is the
/// seam that lets the rest of the app stay agent-agnostic.
enum AgentKind: String, Sendable {
    case claude
    case grok
    case codex

    /// Best-effort guess from a model id string. Defaults to Claude, which is
    /// both the home agent and the safe fallback for unknown models.
    static func infer(fromModel model: String) -> AgentKind {
        let m = model.lowercased()
        if m.contains("grok") { return .grok }
        if m.contains("gpt") || m.contains("codex") || m.contains("o1") || m.contains("o3") { return .codex }
        return .claude
    }

    /// Human name for the agent, e.g. shown in About / labels.
    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .grok:   return "Grok Build"
        case .codex:  return "Codex"
        }
    }
}

/// Cross-agent glue for the hook transport. Kept deliberately small: the only
/// thing that genuinely differs at the wire level today is payload key casing.
enum AgentAdapter {

    /// Canonicalize a raw hook payload so the rest of EventServer can keep
    /// reading Claude Code's snake_case keys regardless of which agent sent it.
    ///
    /// Claude Code sends snake_case (`session_id`, `tool_name`, ...). Grok Build
    /// and Codex send camelCase (`sessionId`, `toolName`, `hookEventName`,
    /// `workspaceRoot`, ...). We copy any camelCase alias into its snake_case
    /// name when that name isn't already present, so a Claude payload is left
    /// untouched and a Grok/Codex one becomes readable. Original keys are kept
    /// too, so nothing that already worked can break.
    static func normalizeKeys(_ payload: [String: Any]) -> [String: Any] {
        // camelCase alias -> canonical snake_case key the code reads.
        let aliases: [(from: String, to: String)] = [
            ("hookEventName", "hook_event_name"),
            ("sessionId", "session_id"),
            ("toolName", "tool_name"),
            ("toolInput", "tool_input"),
            ("toolResponse", "tool_response"),
            ("transcriptPath", "transcript_path"),
            ("permissionMode", "permission_mode"),
            ("sessionName", "session_name"),
            ("prUrl", "pr_url"),
            ("prState", "pr_state"),
            ("prNumber", "pr_number"),
            ("taskId", "task_id"),
            // Grok/Codex call the project root workspaceRoot; map to cwd only as
            // a fallback so a real cwd always wins.
            ("workspaceRoot", "cwd"),
        ]
        // Fast path: if nothing looks camelCase, return as-is (Claude payloads).
        guard aliases.contains(where: { payload[$0.from] != nil }) else { return payload }

        var out = payload
        for (from, to) in aliases {
            guard let v = payload[from] else { continue }
            if out[to] == nil || (out[to] as? String)?.isEmpty == true {
                out[to] = v
            }
        }
        return out
    }
}
