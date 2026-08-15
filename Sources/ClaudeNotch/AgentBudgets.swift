import Foundation

// The two budgets a Claude Code session can quietly run out of.
//
// A session may have 20 subagents running at once, and may issue 200 WebSearch
// calls in its lifetime. Both are configurable, and both fail the same way:
// the tool call comes back with a refusal, Claude carries on without the work
// it was going to delegate, and from the outside the session just... does less.
// It reads as stuck, or as having decided not to bother.
//
// Nothing about either budget reaches the app on a hook of its own. What does
// arrive is the refusal itself, in the PostToolUse tool result, and that is
// what this reads. The limits are read from the same settings file Claude Code
// reads them from, so a raised cap shows as a raised cap.
//
// Pure and `nonisolated`: tool results are untrusted input.
enum AgentBudgets {

    /// Claude Code's own defaults (2.1.x).
    static let defaultConcurrentSubagents = 20
    static let defaultWebSearchesPerSession = 200

    struct Limits: Equatable {
        var concurrentSubagents = defaultConcurrentSubagents
        var webSearchesPerSession = defaultWebSearchesPerSession
    }

    /// Which budget a tool result says was reached.
    enum Cap: Equatable {
        case subagents
        case webSearches
    }

    /// Limits from an environment map: the `env` block of settings.json, or the
    /// process environment. A value that is not a positive integer is ignored
    /// rather than treated as zero — a zero cap would draw every session as
    /// permanently out of budget.
    nonisolated static func limits(env: [String: String]) -> Limits {
        var out = Limits()
        if let n = positive(env["CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS"]) {
            out.concurrentSubagents = n
        }
        if let n = positive(env["CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION"]) {
            out.webSearchesPerSession = n
        }
        return out
    }

    /// The `env` block of a settings.json, which is where a raised cap is
    /// normally written. Values are stringified: JSON allows a number there and
    /// Claude Code accepts both.
    nonisolated static func settingsEnv(at path: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let env = obj["env"] as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in env {
            if let s = v as? String { out[k] = s }
            else if let i = v as? Int { out[k] = String(i) }
        }
        return out
    }

    /// Whether a tool result is Claude Code refusing on a budget, and which one.
    ///
    /// Matched on the phrasing Claude Code uses, which is not a documented
    /// contract — so a miss costs a badge and never a wrong one, and the
    /// counters below stand on their own either way.
    nonisolated static func capReached(in toolResponse: Any?) -> Cap? {
        let text = flatten(toolResponse).lowercased()
        guard !text.isEmpty else { return nil }
        if text.contains("concurrent subagent limit reached") { return .subagents }
        if text.contains("web search budget") { return .webSearches }
        return nil
    }

    /// Tool results arrive as a string, a dict, or a list of content blocks.
    /// Only the text matters here, and only the first few KB of it: a refusal
    /// is short, and a tool result is not.
    nonisolated static func flatten(_ any: Any?, budget: Int = 4000) -> String {
        var out = ""
        func walk(_ value: Any?) {
            guard out.count < budget else { return }
            switch value {
            case let s as String: out += s + "\n"
            case let d as [String: Any]: for key in d.keys.sorted() { walk(d[key]) }
            case let a as [Any]: for v in a { walk(v) }
            default: break
            }
        }
        walk(any)
        return String(out.prefix(budget))
    }

    nonisolated private static func positive(_ raw: String?) -> Int? {
        guard let raw, let n = Int(raw.trimmingCharacters(in: .whitespaces)), n > 0 else { return nil }
        return n
    }
}
