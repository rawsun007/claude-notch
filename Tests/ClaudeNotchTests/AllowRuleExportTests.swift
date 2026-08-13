import XCTest
@testable import ClaudeNotch

/// Reading an allow rule back out: as the command a human approved, and as a
/// Claude Code permission string.
///
/// These rules are the app's security policy, so both directions have to be
/// exact. A rule shown as something other than what it matches, or exported as
/// something broader than what it matches, is worse than no feature at all.
final class AllowRuleExportTests: XCTestCase {

    // MARK: - Recovering the literal command

    func testAnExactCommandRoundTrips() {
        let rule = AllowRule.exactCommand(tool: "Bash", command: "npm test")
        XCTAssertEqual(rule.literalCommand, "npm test")
    }

    /// Commands are full of regex metacharacters, which is the whole reason the
    /// stored pattern is escaped.
    func testCommandsFullOfMetacharactersRoundTrip() {
        for command in ["grep -E '^foo.*bar$' src/",
                        "rm -rf ./build/*",
                        "git log --format=%H | head -3",
                        "echo \"a (b) [c] {d}\""] {
            let rule = AllowRule.exactCommand(tool: "Bash", command: command)
            XCTAssertEqual(rule.literalCommand, command, "did not round-trip: \(command)")
        }
    }

    /// The same shape the permission card writes, built the old way, must still
    /// read back — these rules are already on disk in people's snapshots.
    func testTheShapeWrittenByThePermissionCardIsUnderstood() {
        let escaped = NSRegularExpression.escapedPattern(for: "ls -la")
        let rule = AllowRule(tool: "Bash", commandRegex: "^\(escaped)$")
        XCTAssertEqual(rule.literalCommand, "ls -la")
    }

    func testAToolWideRuleHasNoLiteralCommand() {
        XCTAssertNil(AllowRule(tool: "Read", commandRegex: nil).literalCommand)
    }

    /// A pattern that only looks literal must not be presented as one: `npm .*`
    /// matches far more than the text "npm .*".
    func testARealPatternIsNotMistakenForACommand() {
        XCTAssertNil(AllowRule(tool: "Bash", commandRegex: "^npm .*$").literalCommand)
        XCTAssertNil(AllowRule(tool: "Bash", commandRegex: "npm test").literalCommand)
        XCTAssertNil(AllowRule(tool: "Bash", commandRegex: "^(a|b)$").literalCommand)
    }

    func testATrailingBackslashIsNotALiteral() {
        XCTAssertNil(AllowRule(tool: "Bash", commandRegex: "^npm\\$").literalCommand)
    }

    // MARK: - Claude Code permissions

    func testAToolWideRuleExportsAsTheToolName() {
        XCTAssertEqual(AllowRule(tool: "Read", commandRegex: nil).claudePermission, "Read")
    }

    func testAnExactCommandExportsWithItsArgument() {
        XCTAssertEqual(AllowRule.exactCommand(tool: "Bash", command: "npm test").claudePermission,
                       "Bash(npm test)")
    }

    /// Claude Code has no way to say "this regex", and a guess would export a
    /// rule that means something different from the one in the list.
    func testAPatternRuleIsNotExportable() {
        XCTAssertNil(AllowRule(tool: "Bash", commandRegex: "^npm .*$").claudePermission)
    }

    /// The argument ends at the closing paren, so a command holding one cannot
    /// survive the trip.
    func testACommandWithAParenIsNotExportable() {
        XCTAssertNil(AllowRule.exactCommand(tool: "Bash", command: "echo (hi)").claudePermission)
    }

    // MARK: - The settings fragment

    func testTheJSONCarriesEveryExportableRuleSorted() throws {
        let rules = [
            AllowRule.exactCommand(tool: "Bash", command: "npm test"),
            AllowRule(tool: "Read", commandRegex: nil),
            AllowRule.exactCommand(tool: "Bash", command: "ls"),
        ]
        let text = AppState.claudePermissionsJSON(rules)
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let allow = ((obj?["permissions"] as? [String: Any])?["allow"] as? [String]) ?? []
        XCTAssertEqual(allow, ["Bash(ls)", "Bash(npm test)", "Read"])
    }

    func testUnexportableRulesAreReportedRatherThanApproximated() {
        let pattern = AllowRule(tool: "Bash", commandRegex: "^npm .*$")
        let rules = [AllowRule(tool: "Read", commandRegex: nil), pattern]
        XCTAssertEqual(AppState.unexportableRules(rules), [pattern])
        XCTAssertFalse(AppState.claudePermissionsJSON(rules).contains("npm"))
    }

    // MARK: - Deprecated permission forms (Claude Code 2.1.210)

    /// 2.1.210 warns at startup about `Write(path)`, `NotebookEdit(path)` and
    /// `Glob(path)` rules and says to use `Edit(path)` / `Read(path)`. An
    /// export that emitted the old spelling would hand the user a settings.json
    /// that nags on every launch, for rules the app told them to add.
    func testDeprecatedArgumentFormsExportUnderTheirReplacement() {
        XCTAssertEqual(AllowRule.exactCommand(tool: "Write", command: "/tmp/a.swift").claudePermission,
                       "Edit(/tmp/a.swift)")
        XCTAssertEqual(AllowRule.exactCommand(tool: "NotebookEdit", command: "/tmp/n.ipynb").claudePermission,
                       "Edit(/tmp/n.ipynb)")
        XCTAssertEqual(AllowRule.exactCommand(tool: "Glob", command: "src/**/*.ts").claudePermission,
                       "Read(src/**/*.ts)")
    }

    /// Only the argument form was deprecated. A tool-wide `Write` rule is still
    /// current, and rewriting it to `Edit` would widen a rule the user never
    /// widened.
    func testToolWideRulesForThoseToolsAreLeftAlone() {
        XCTAssertEqual(AllowRule(tool: "Write", commandRegex: nil).claudePermission, "Write")
        XCTAssertEqual(AllowRule(tool: "Glob", commandRegex: nil).claudePermission, "Glob")
        XCTAssertFalse(AllowRule(tool: "Write", commandRegex: nil).exportRenamesTool)
    }

    func testARenamedRuleIsReportedToTheUI() {
        let renamed = AllowRule.exactCommand(tool: "Write", command: "/tmp/a.swift")
        let plain = AllowRule.exactCommand(tool: "Bash", command: "ls")
        // A rule that cannot be exported at all is not "renamed" either.
        let unexportable = AllowRule.exactCommand(tool: "Write", command: "/tmp/a(1).swift")
        XCTAssertEqual(AppState.renamedOnExport([renamed, plain, unexportable]), [renamed])
        XCTAssertEqual(AppState.unexportableRules([renamed, plain, unexportable]), [unexportable])
    }

    /// Two rules can now collapse onto one permission, and a settings file
    /// listing the same entry twice is noise the user has to clean up by hand.
    func testARenamedRuleAndItsReplacementDoNotExportTwice() throws {
        let rules = [
            AllowRule.exactCommand(tool: "Write", command: "/tmp/a.swift"),
            AllowRule.exactCommand(tool: "Edit", command: "/tmp/a.swift"),
        ]
        let text = AppState.claudePermissionsJSON(rules)
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let allow = ((obj?["permissions"] as? [String: Any])?["allow"] as? [String]) ?? []
        XCTAssertEqual(allow, ["Edit(/tmp/a.swift)"])
    }

    /// The guard that matters: whatever the list holds, the exported fragment
    /// never contains a form Claude Code warns about. Runs over every rule
    /// shape the app can produce, so a future tool added to the export cannot
    /// quietly reintroduce one.
    func testTheExportNeverEmitsAWarnedAboutForm() {
        var rules: [AllowRule] = []
        for tool in ["Write", "NotebookEdit", "Glob", "Edit", "Read", "Bash", "WebFetch"] {
            rules.append(AllowRule(tool: tool, commandRegex: nil))
            rules.append(AllowRule.exactCommand(tool: tool, command: "/tmp/x.txt"))
            rules.append(AllowRule(tool: tool, commandRegex: "^.*$"))
        }
        let text = AppState.claudePermissionsJSON(rules)
        for deprecated in ["Write(", "NotebookEdit(", "Glob("] {
            XCTAssertFalse(text.contains(deprecated),
                           "export emitted a deprecated permission form: \(deprecated)")
        }
    }

    /// Golden: rule in, permission out. The table is the contract the export
    /// writes into someone's settings.json, so each line is pinned.
    func testGoldenPermissionTable() {
        let cases: [(tool: String, command: String?, expected: String?)] = [
            ("Bash", nil, "Bash"),
            ("Bash", "npm test", "Bash(npm test)"),
            ("Read", nil, "Read"),
            ("Read", "/etc/hosts", "Read(/etc/hosts)"),
            ("Edit", "/tmp/a.swift", "Edit(/tmp/a.swift)"),
            ("Write", nil, "Write"),
            ("Write", "/tmp/a.swift", "Edit(/tmp/a.swift)"),
            ("NotebookEdit", nil, "NotebookEdit"),
            ("NotebookEdit", "/tmp/n.ipynb", "Edit(/tmp/n.ipynb)"),
            ("Glob", nil, "Glob"),
            ("Glob", "**/*.swift", "Read(**/*.swift)"),
            ("WebFetch", "domain:example.com", "WebFetch(domain:example.com)"),
            ("Write", "/tmp/a(1).swift", nil),      // paren: cannot round-trip
        ]
        for c in cases {
            let rule = c.command.map { AllowRule.exactCommand(tool: c.tool, command: $0) }
                ?? AllowRule(tool: c.tool, commandRegex: nil)
            XCTAssertEqual(rule.claudePermission, c.expected,
                           "\(c.tool)(\(c.command ?? "-"))")
        }
    }

    func testAnEmptyListIsStillValidJSON() throws {
        let text = AppState.claudePermissionsJSON([])
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let allow = ((obj?["permissions"] as? [String: Any])?["allow"] as? [String]) ?? ["not empty"]
        XCTAssertEqual(allow, [])
    }
}
