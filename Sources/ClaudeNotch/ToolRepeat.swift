import Foundation

// A session doing the same thing over and over, and nobody watching.
//
// The reported shape: $313 spent in eight and a half hours, roughly ninety-eight
// near-identical tool invocations, none of it noticed until the bill. Claude
// Code has no circuit breaker and no per-session budget ceiling, so a retry loop
// that cannot make progress costs money at full speed until a human happens to
// look at the terminal.
//
// The notch sees every tool call as it happens, which makes it the one place
// that can count them. This does not stop anything, and deliberately so: killing
// somebody's session on a heuristic is a far worse failure than letting a loop
// run one minute longer. It only says the number out loud.
//
// Pure and nonisolated: signatures and thresholds are the whole of the logic and
// belong in tests, not in a six-hour session someone has to reproduce.
enum ToolRepeat {

    /// How many identical calls before it is worth saying anything.
    ///
    /// High on purpose. Re-running one test command while chasing a fix is
    /// normal and can reach double digits honestly, so the bar has to sit above
    /// legitimate iteration or this becomes the card everyone disables. Forty
    /// identical calls is not iteration.
    static let warnAt = 40

    /// Said once more, much later, for a loop that nobody acted on. At this
    /// point the first card has been on screen for a long time and the session
    /// is still going.
    static let urgentAt = 150

    /// Longest signature kept. Two Bash commands identical for their first two
    /// hundred characters are the same call for this purpose, and the cap keeps
    /// a payload-fed dictionary key bounded.
    static let signatureLimit = 200

    /// What makes two tool calls "the same call".
    ///
    /// Keyed on the field that actually identifies the work rather than the
    /// whole input, so a Bash command is its command line and an edit is its
    /// path. An unknown tool falls back to its string inputs in sorted key
    /// order, which is stable across calls without needing to know the tool.
    ///
    /// Returns empty for a tool with nothing identifying in it, and an empty
    /// signature is never counted: guessing that two featureless calls are the
    /// same call is how a legitimate session gets accused of looping.
    nonisolated static func signature(tool: String, input: [String: Any]) -> String {
        let name = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }

        func str(_ key: String) -> String? {
            guard let v = input[key] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        let identifying: String?
        switch name {
        case "Bash", "BashOutput":
            identifying = str("command")
        case "Read", "Write", "Edit", "NotebookEdit":
            identifying = str("file_path") ?? str("notebook_path")
        case "Grep":
            identifying = [str("pattern"), str("path")].compactMap { $0 }.joined(separator: " ")
        case "Glob":
            identifying = [str("pattern"), str("path")].compactMap { $0 }.joined(separator: " ")
        case "WebFetch", "WebSearch":
            identifying = str("url") ?? str("query")
        default:
            // Stable across calls without knowing the tool: every string input,
            // in sorted key order.
            let pairs = input.keys.sorted().compactMap { key -> String? in
                guard let v = str(key) else { return nil }
                return "\(key)=\(v)"
            }
            identifying = pairs.isEmpty ? nil : pairs.joined(separator: " ")
        }

        guard let ident = identifying?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ident.isEmpty
        else { return "" }

        // Collapse runs of whitespace so the same command formatted two ways is
        // one signature.
        let collapsed = ident.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String("\(name) \(collapsed)".prefix(signatureLimit))
    }

    /// Whether this count is one of the two the app speaks at.
    ///
    /// Exactly at the thresholds, never past them: a session that keeps looping
    /// must not raise a card per call once it crosses forty.
    nonisolated static func worthAnnouncing(count: Int) -> Bool {
        count == warnAt || count == urgentAt
    }

    // MARK: - What it says

    nonisolated static func cardTitle(count: Int, tool: String) -> String {
        String(format: L("This session has run the same %@ call %d times",
                         comment: "Card title for a repeated tool call. %@ is the tool name, %d the count"),
               tool, count)
    }

    nonisolated static func cardDetail(count: Int, preview: String) -> String {
        let head = count >= urgentAt
            ? L("It is still going.",
                comment: "Lead sentence when a repeated tool call has continued to a very high count")
            : L("Identical input each time.",
                comment: "Lead sentence when a tool call has repeated with the same input")
        guard !preview.isEmpty else {
            return head + " " + L("A loop that cannot make progress bills at full speed, so this is worth a look at the terminal.",
                                  comment: "Card body explaining why a repeated tool call matters")
        }
        return head + " " + String(format: L("The call is %@. A loop that cannot make progress bills at full speed, so this is worth a look at the terminal.",
                                             comment: "Card body naming the repeated call. %@ is a short preview of it"),
                                   preview)
    }

    /// The signature shortened for display. The signature itself can be two
    /// hundred characters of shell.
    nonisolated static func preview(_ signature: String, limit: Int = 60) -> String {
        let body = signature.split(separator: " ").dropFirst().joined(separator: " ")
        guard !body.isEmpty else { return "" }
        return body.count <= limit ? body : String(body.prefix(limit - 1)) + "\u{2026}"
    }
}
