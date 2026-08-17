import Foundation

// A tool call that failed.
//
// Claude Code fires PostToolUseFailure with the tool, its input, the error, how
// long it ran, and whether the user interrupted it. Nothing in the notch showed
// any of it: a session whose every command is failing looked exactly like a
// session working, because the only thing on screen was the name of the tool it
// had just started.
//
// The rule this file exists to hold: a failure is worth recording, and a
// pattern of failures is worth interrupting someone for. One failed grep is
// neither.
enum ToolFailure {

    struct Event: Equatable {
        let toolName: String
        let reason: String
        let isInterrupt: Bool
        let durationMs: Int

        /// The user pressed Esc. Claude Code reports it through the same hook,
        /// and it is the one "failure" that is not one: they know, they did it.
        var isWorthRecording: Bool { !isInterrupt }
    }

    /// How many times the same tool has to fail in a row before the notch says
    /// something out loud. Two is a coincidence; three is a session going in
    /// circles while you look at a status line that says "Running command".
    static let failuresBeforeCard = 3

    /// The longest error text a card or a history row carries. The rest of a
    /// stack trace helps nobody at this size.
    static let maxReason = 200

    nonisolated static func parse(_ payload: [String: Any]) -> Event? {
        let tool = ((payload["tool_name"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        guard !tool.isEmpty else { return nil }
        return Event(toolName: tool,
                     reason: reason(from: payload),
                     isInterrupt: boolValue(payload["is_interrupt"]),
                     durationMs: intValue(payload["duration_ms"]) ?? 0)
    }

    /// The error, in one line, from whichever shape it arrived in. A tool error
    /// is written for a model to read, so it can be a paragraph, a JSON blob, or
    /// a stack trace; the first meaningful line is what a person wants.
    nonisolated static func reason(from payload: [String: Any]) -> String {
        let raw = AgentBudgets.flatten(payload["error"] ?? payload["tool_response"])
        let line = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return String(line.prefix(maxReason))
    }

    /// What the history row says.
    nonisolated static func title(_ event: Event) -> String {
        String(format: L("%@ failed", comment: "History row for a failed tool call. %@ is a tool name"),
               humanTitle(for: event.toolName))
    }

    /// What the card says when a session is failing the same way over and over.
    nonisolated static func stuckTitle(tool: String, count: Int) -> String {
        String(format: L("%1$@ has failed %2$d times in a row",
                         comment: "Card title when a tool keeps failing. %1$@ is a tool name, %2$d a count"),
               humanTitle(for: tool), count)
    }

    nonisolated static func stuckDetail(reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return L("The session is retrying something that is not working. Nothing is being asked of you.",
                     comment: "Card body when a tool keeps failing and no error text came with it")
        }
        return trimmed
    }

    nonisolated private static func boolValue(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        if let s = any as? String { return s == "true" || s == "1" }
        return false
    }

    nonisolated private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
