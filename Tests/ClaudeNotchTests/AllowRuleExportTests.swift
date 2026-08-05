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

    func testAnEmptyListIsStillValidJSON() throws {
        let text = AppState.claudePermissionsJSON([])
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let allow = ((obj?["permissions"] as? [String: Any])?["allow"] as? [String]) ?? ["not empty"]
        XCTAssertEqual(allow, [])
    }
}
