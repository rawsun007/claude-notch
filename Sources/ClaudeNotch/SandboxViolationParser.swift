import Foundation

// What the sandbox actually stopped.
//
// The sandbox badge (see SandboxReader) says a fence exists. This says when the
// agent walked into it. Claude Code 2.1.224 started putting the details into
// the Bash tool result, inside a `<sandbox_violations>` block, so they arrive
// on the PostToolUse payload the app already receives — no new hook needed.
//
// Everything here is pure and takes the raw payload value, because the block's
// inner format is not a documented contract: it is whatever the CLI writes
// today. So the parser reads the shapes it knows, keeps the raw line for
// everything else, and never drops a violation just because it could not
// classify it.

enum SandboxViolationParser {

    enum Kind: Equatable {
        case network   // egress the proxy refused
        case file      // a path the filesystem fence refused
        case other     // real, but not a shape this build recognizes
    }

    struct Violation: Equatable {
        let kind: Kind
        /// The host or path that was refused, when one could be read out of
        /// the line. Empty otherwise — the raw line still says what happened.
        let target: String
        /// The line as the CLI wrote it, trimmed and length-capped.
        let raw: String
    }

    /// A tool result can be a string or a structured object; violations can be
    /// in either, and in stderr as often as stdout.
    nonisolated static func responseText(_ response: Any?) -> String {
        guard let response, !(response is NSNull) else { return "" }
        if let text = response as? String { return text }
        if let dict = response as? [String: Any] {
            return [dict["stdout"], dict["stderr"], dict["output"], dict["content"]]
                .compactMap { $0 as? String }
                .joined(separator: "\n")
        }
        return ""
    }

    static let maxViolations = 8
    static let maxLineLength = 200

    /// Violations reported in a tool result, newest-format-first, capped.
    ///
    /// Returns [] when the block is absent, which is the overwhelmingly common
    /// case — this runs on every PostToolUse, so the cheap `contains` check
    /// comes before any parsing.
    nonisolated static func violations(in response: Any?) -> [Violation] {
        let text = responseText(response)
        guard text.contains("<sandbox_violations>") else { return [] }
        guard let body = block(in: text) else { return [] }

        var out: [Violation] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-• "))
            guard !trimmed.isEmpty else { continue }
            // Untrusted text on its way to a card and to the history file.
            let raw = String(SecretRedactor.redact(trimmed).prefix(maxLineLength))
            out.append(Violation(kind: classify(raw), target: target(in: raw), raw: raw))
            if out.count == maxViolations { break }
        }
        return out
    }

    /// The text between the tags. Nil when the block is unterminated, which
    /// means the output was truncated mid-block: reporting half a violation
    /// list as the whole one would be worse than reporting none.
    nonisolated static func block(in text: String) -> String? {
        guard let start = text.range(of: "<sandbox_violations>"),
              let end = text.range(of: "</sandbox_violations>", range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// Network or filesystem, by the words the line uses.
    ///
    /// Matched on word boundaries rather than as substrings. `/etc/hosts` is a
    /// file, and a substring test for "host" calls it a network denial — which
    /// is the kind of wrong that reads as authoritative in a card.
    nonisolated static func classify(_ line: String) -> Kind {
        let lower = line.lowercased()
        // "request to <host>" is the CLI's own phrasing for a blocked egress.
        if lower.contains("request to ") { return .network }
        if containsWord(lower, ["network", "egress", "dns", "domain", "hostname",
                                "socket", "proxy", "connect", "connection",
                                "tcp", "udp", "url"]) {
            return .network
        }
        if containsWord(lower, ["read", "write", "open", "file", "filesystem",
                                "path", "directory", "credential"])
            || line.contains("/") {
            return .file
        }
        return .other
    }

    nonisolated private static func containsWord(_ haystack: String, _ words: [String]) -> Bool {
        let pattern = "\\b(" + words.joined(separator: "|") + ")\\b"
        return haystack.range(of: pattern, options: .regularExpression) != nil
    }

    /// The host or path a line is about. Best effort by design: a line whose
    /// shape this build does not know still reaches the user as its raw text.
    nonisolated static func target(in line: String) -> String {
        // "Blocked network request to api.example.com (allowManagedDomainsOnly)"
        if let hostRange = line.range(of: #"(?<=request to )[^\s,;()]+"#, options: .regularExpression) {
            return String(line[hostRange])
        }
        // A quoted path or host: deny 'foo', denied "bar".
        if let quoted = line.range(of: #"(?<=['"])[^'"]{2,}(?=['"])"#, options: .regularExpression) {
            return String(line[quoted])
        }
        // A bare absolute path or ~ path.
        if let path = line.range(of: #"[~/][^\s'"(),;]{2,}"#, options: .regularExpression) {
            return String(line[path])
        }
        // A bare hostname (has a dot, no slash, not a sentence).
        if let host = line.range(of: #"\b[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9\-]+)+(:\d+)?\b"#,
                                 options: [.regularExpression]) {
            return String(line[host])
        }
        return ""
    }

    /// One line for the card: what was refused, in the user's terms.
    nonisolated static func summary(_ v: Violation) -> String {
        switch (v.kind, v.target.isEmpty) {
        case (.network, false):
            return String(format: L("Blocked network access to %@", comment: "Sandbox violation card. %@ is a host name"), v.target)
        case (.file, false):
            return String(format: L("Blocked file access to %@", comment: "Sandbox violation card. %@ is a file path"), v.target)
        default:
            return v.raw
        }
    }
}
