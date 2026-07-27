import Foundation

/// Checks whether a finished turn did what it says it did.
///
/// The most common complaint about agentic coding is not a bad edit, it is a
/// confident "I've updated the handler and the tests pass" on a turn where
/// nothing was written and no test was run. The notch already sees both halves:
/// the assistant's closing message, and what the tools actually did. Nobody
/// compares them.
///
/// The bar for speaking up is deliberately high. A verifier that cries wolf is
/// worse than none, because the one time it is right you will have stopped
/// reading it. So this stays silent unless the reply makes a checkable claim,
/// and it only contradicts when the evidence is flatly against it. Anything
/// ambiguous is `.silent`.
enum CompletionAudit {

    /// What the turn asserted, and what it actually did.
    struct Evidence: Equatable {
        /// The assistant's closing message.
        var claim: String
        /// How many distinct files the turn's Edit/Write tools touched.
        var filesEdited: Int
        /// Whether the turn ran any shell command. A command can change files
        /// without an Edit tool, so this does not prove work happened, only
        /// that "nothing was touched" cannot be proven either.
        var ranCommands: Bool
        /// Whether a recognised test command ran during the turn.
        var testCommandRan: Bool
        /// Whether it failed. Nil when nothing ran, or the result is unknown.
        var testFailed: Bool?

        init(claim: String, filesEdited: Int = 0, ranCommands: Bool = false,
             testCommandRan: Bool = false, testFailed: Bool? = nil) {
            self.claim = claim
            self.filesEdited = filesEdited
            self.ranCommands = ranCommands
            self.testCommandRan = testCommandRan
            self.testFailed = testFailed
        }
    }

    enum Verdict: Equatable {
        /// Nothing worth saying. The default, and the common case.
        case silent
        /// Claimed a change, made one, and the tests back it up.
        case verified(String)
        /// The claim may well be true, but the turn did not demonstrate it.
        case unverified(String)
        /// The evidence is against the claim.
        case contradicted(String)

        var message: String? {
            switch self {
            case .silent: return nil
            case .verified(let m), .unverified(let m), .contradicted(let m): return m
            }
        }
    }

    // MARK: - Reading the claim

    /// Strip fenced code blocks and inline code before matching. Claude quotes
    /// commands and sample output constantly, and "all tests passed" inside a
    /// pasted transcript is not the assistant claiming anything.
    nonisolated static func prose(_ text: String) -> String {
        var out = ""
        var inFence = false
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            // Indented code blocks.
            if line.hasPrefix("    ") || line.hasPrefix("\t") { continue }
            out += line + "\n"
        }
        // Inline code spans.
        out = out.replacingOccurrences(of: "`[^`]*`", with: " ",
                                       options: [.regularExpression])
        // Quoted spans. Quoting something is reporting it, not asserting it,
        // and the app's own wording gets quoted back constantly: a sentence
        // like: ask for an edit and it says "2 files changed, tests passed"
        // is documentation, and reading it as a claim accuses a turn that
        // never made one. Straight and typographic quotes both.
        for pattern in ["\"[^\"]*\"", "\u{201C}[^\u{201D}]*\u{201D}"] {
            out = out.replacingOccurrences(of: pattern, with: " ",
                                           options: [.regularExpression])
        }
        return out
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Sentences that are actually asserting something, with instructions and
    /// conditionals dropped.
    ///
    /// "Check that all tests pass" contains the same words as "all tests pass"
    /// and means the opposite: it is telling YOU to go and look. Matching the
    /// words alone flags a turn that behaved perfectly, so the sentence has to
    /// be read for whether it is a claim at all.
    nonisolated static func assertions(_ text: String) -> [String] {
        let cues = [
            "check that", "make sure", "ensure", "verify that", "confirm that",
            "so that", "as long as", "provided that", "in order to",
            "if ", "once ", "until ", "unless ", "when you", "after you",
            "you can", "you could", "you should", "you might", "you will",
            "we should", "we could", "would ", "might ", "may ", "please ",
            "do you want", "should i", "shall i", "let me know",
        ]
        return prose(text)
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n;"))
            .filter { sentence in
                let l = sentence.lowercased()
                return !cues.contains { l.contains($0) }
            }
    }

    /// Did the reply assert that it changed code?
    ///
    /// Requires a first-person past-tense assertion. "You could update the
    /// handler" and "this would fix it" are suggestions, not claims, and a
    /// looser pattern flags them constantly.
    nonisolated static func claimsCodeChange(_ text: String) -> Bool {
        let verbs = "updated|fixed|added|implemented|created|removed|deleted|refactored|renamed|changed|migrated|wired|replaced|moved|extracted|split"
        return assertions(text).contains { s in
            matches(s, "\\bi(?:'ve| have)\\s+(?:\\w+\\s+){0,2}(?:\(verbs))\\b")
                || matches(s, "\\bi\\s+(?:\(verbs))\\b")
                || matches(s, "^\\s*(?:\(verbs))\\s+the\\b")
                || matches(s, "\\bthe\\s+(?:fix|change|update)\\s+is\\s+(?:in|done|complete)\\b")
        }
    }

    /// Did the reply assert the tests pass?
    nonisolated static func claimsTestsPass(_ text: String) -> Bool {
        assertions(text).contains { s in
            matches(s, "\\b(?:all\\s+)?tests?\\s+(?:now\\s+)?(?:are\\s+)?(?:pass|passes|passed|passing|green)\\b")
                || matches(s, "\\btest\\s+suite\\s+(?:passes|passed|is green)\\b")
                || matches(s, "\\beverything\\s+(?:passes|passed)\\b")
                || matches(s, "\\bsuite\\s+is\\s+green\\b")
        }
    }

    // MARK: - The verdict

    nonisolated static func audit(_ e: Evidence) -> Verdict {
        let saidChange = claimsCodeChange(e.claim)
        let saidTestsPass = claimsTestsPass(e.claim)
        // Only per-turn signals. An earlier version counted the session's git
        // diff, which is cumulative: once Claude edited anything the test was
        // true for the rest of the session and a contradiction could never
        // fire again. A shell command counts because it could have changed
        // files without an Edit tool, so staying quiet is the honest answer.
        let didSomething = e.filesEdited > 0 || e.ranCommands

        // A turn that ran the tests and watched them fail, then reported
        // success. The strongest signal available and worth interrupting for.
        if e.testFailed == true, saidChange || saidTestsPass {
            return .contradicted("Claude reported success, but the test command it ran failed.")
        }

        // Said it edited something, and the turn ran no tool that could have.
        if saidChange, !didSomething {
            return .contradicted("Claude says it changed the code, but this turn edited no file and ran no command.")
        }

        // Said the tests pass without running any.
        if saidTestsPass, !e.testCommandRan {
            return .unverified("Claude says the tests pass, but no test command ran this turn.")
        }

        if saidChange, didSomething {
            if e.testCommandRan, e.testFailed == false {
                return .verified("\(fileCount(e.filesEdited)) changed, tests passed.")
            }
            // Edited code and never ran anything. True of most turns, so this is
            // a note rather than an accusation, and only when there is a real
            // edit to talk about.
            if !e.testCommandRan, e.filesEdited > 0 {
                return .unverified("\(fileCount(e.filesEdited)) changed, no tests run.")
            }
        }

        return .silent
    }

    private static func fileCount(_ n: Int) -> String {
        n == 1 ? "1 file" : "\(n) files"
    }

    // MARK: - Recognising a test run

    /// Whether a Bash command looks like it runs a project's tests. Used to
    /// decide if a claim about tests was actually demonstrated.
    nonisolated static func isTestCommand(_ command: String) -> Bool {
        let c = command.lowercased()
        // A command that only lists or builds tests is not a test run.
        if matches(c, "--(?:help|list|collect-only|dry-run)\\b") { return false }
        let runners = [
            "npm t\\b", "npm run test", "npm test", "yarn test", "pnpm test", "bun test",
            "swift test", "xcodebuild test", "pytest\\b", "python -m pytest",
            "cargo test", "go test", "make test", "rake test", "mvn test",
            "gradle test", "jest\\b", "vitest\\b", "phpunit\\b", "rspec\\b",
            "dotnet test", "ctest\\b", "tox\\b",
        ]
        if runners.contains(where: { matches(c, "(?:^|[;&|]\\s*)\\s*\($0)") }) { return true }

        // A project's own test script, run directly or through an interpreter.
        // Plenty of repos test with ./run-tests.sh rather than a package
        // manager, and missing those reports "no test command ran" for a turn
        // that ran the whole suite. Anchored at command position, so
        // `cat tests/test_api.py` and `vim tools/test-foo.sh` still do not
        // count: there the command is cat and vim, and the script is an
        // argument being read, not run.
        let interpreter = "(?:(?:bash|sh|zsh|python3?|ruby|node)\\s+)?"
        let script = "(?:\\./|/)?[\\w./-]*?(?:test|run-tests?)[\\w.-]*\\.(?:sh|py|rb|js|mjs)\\b"
        return matches(c, "(?:^|[;&|]\\s*)\\s*\(interpreter)\(script)")
    }

    /// Read a PostToolUse `tool_response` for whether the command failed.
    ///
    /// Returns nil far more often than not, and that is the point. Nil means
    /// "could not tell", which keeps the audit quiet. Only a structured error
    /// field or an unmistakable runner failure line returns true, because a
    /// wrong "the tests failed" is a worse bug than saying nothing at all.
    /// Untrusted input: this is hook payload, so it is read as data only.
    nonisolated static func toolReportedFailure(_ response: Any?) -> Bool? {
        guard let response, !(response is NSNull) else { return nil }

        if let dict = response as? [String: Any] {
            // Structured signals are trustworthy, so they win outright.
            if let isError = dict["is_error"] as? Bool { return isError }
            if let success = dict["success"] as? Bool { return !success }
            if let code = dict["exit_code"] as? Int { return code != 0 }
            if let code = dict["exitCode"] as? Int { return code != 0 }
            let text = [dict["stdout"], dict["stderr"], dict["output"], dict["content"]]
                .compactMap { $0 as? String }
                .joined(separator: "\n")
            return failureInOutput(text)
        }
        if let text = response as? String { return failureInOutput(text) }
        return nil
    }

    /// Case-sensitive match, for the all-caps tokens runners print as a status.
    /// `FAILED` as a jest/pytest status line means the run failed; the ordinary
    /// word "failed" appears in "0 failed, 20 passed", which is a pass.
    private static func matchesExactCase(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression]) != nil
    }

    /// Last resort: read the runner's own summary line. Deliberately narrow.
    private static func failureInOutput(_ text: String) -> Bool? {
        guard !text.isEmpty else { return nil }
        let countedFailures = [
            "\\b[1-9]\\d*\\s+failures?\\b",       // "3 failures", never "0 failures"
            "\\b[1-9]\\d*\\s+failed\\b",
            "\\bnpm ERR!",
            "\\bAssertionError\\b",
        ]
        if countedFailures.contains(where: { matches(text, $0) }) { return true }
        if matchesExactCase(text, "\\bFAILED\\b") { return true }

        let success = [
            "\\b0\\s+failures?\\b",
            "\\b0\\s+failed\\b",
            "\\ball tests passed\\b",
            "\\bTest Suite .* passed\\b",
            "\\btest result: ok\\b",
        ]
        if success.contains(where: { matches(text, $0) }) { return false }
        if matchesExactCase(text, "\\bPASS\\b") { return false }
        return nil
    }
}
