import XCTest
@testable import ClaudeNotch

/// The suggestion exists to move people from answering the same question
/// forever to making one rule. Two things must never happen: suggesting a rule
/// for a destructive command, and suggesting one that already exists.
@MainActor
final class RuleSuggestionTests: XCTestCase {

    /// isDangerous is derived from the reasons the parser found, not settable,
    /// so a dangerous fixture is built the way a real one is.
    private func request(tool: String = "Bash", detail: String = "npm test",
                         dangerous: Bool = false) -> PermissionRequest {
        PermissionRequest(kind: .toolUse, title: "Run shell command", detail: detail,
                          toolName: tool, source: "test", cwd: "/tmp",
                          dangerReasons: dangerous ? ["recursive delete"] : [],
                          resolver: { _, _ in })
    }

    private func approve(_ s: AppState, _ req: PermissionRequest, times: Int) {
        for _ in 0..<times { s.noteManualApproval(req) }
    }

    func testNothingIsSuggestedUntilItIsAHabit() {
        let s = AppState()
        let req = request()
        approve(s, req, times: AppState.ruleSuggestionThreshold - 1)
        XCTAssertFalse(s.suggestsRule(for: req),
                       "twice is a coincidence; suggesting that early is nagging")

        s.noteManualApproval(req)
        XCTAssertTrue(s.suggestsRule(for: req))
        XCTAssertEqual(s.approvalCount(for: req), AppState.ruleSuggestionThreshold)
    }

    func testDangerousCommandsAreNeverSuggestedAway() {
        let s = AppState()
        let req = request(detail: "rm -rf ~/project", dangerous: true)
        approve(s, req, times: 10)
        XCTAssertEqual(s.approvalCount(for: req), 0,
                       "a destructive command is exactly the one that should keep asking")
        XCTAssertFalse(s.suggestsRule(for: req))
    }

    func testAnExistingRuleSilencesTheSuggestion() {
        let s = AppState()
        let req = request()
        approve(s, req, times: 5)
        XCTAssertTrue(s.suggestsRule(for: req))

        s.allowRules.insert(AllowRule(tool: "Bash", commandRegex: nil))
        XCTAssertFalse(s.suggestsRule(for: req),
                       "the app must not suggest something it has already done")
    }

    func testDifferentCommandsAreCountedApart() {
        let s = AppState()
        let test = request(detail: "npm test")
        let build = request(detail: "npm run build")
        approve(s, test, times: 4)
        approve(s, build, times: 1)

        XCTAssertTrue(s.suggestsRule(for: test))
        XCTAssertFalse(s.suggestsRule(for: build),
                       "a habit with one command says nothing about another")
    }

    func testTheSameCommandFromAnotherToolIsAnotherHabit() {
        let s = AppState()
        let bash = request(tool: "Bash", detail: "npm test")
        let other = request(tool: "Write", detail: "npm test")
        approve(s, bash, times: 4)
        XCTAssertFalse(s.suggestsRule(for: other),
                       "the key follows the rule that would be made, and a rule names its tool")
    }

    /// Making the rule spends the tally. Keeping it means deleting the rule
    /// brings the suggestion straight back, which reads as the app arguing.
    func testMakingTheRuleClearsTheCount() {
        let s = AppState()
        let req = request()
        approve(s, req, times: 4)
        s.clearApprovalCount(for: req)
        XCTAssertEqual(s.approvalCount(for: req), 0)
        XCTAssertFalse(s.suggestsRule(for: req))
    }

    func testDemoCardsDoNotTeachTheAppAnything() {
        let s = AppState()
        let demo = PermissionRequest(kind: .toolUse, title: "Run shell command",
                                     detail: "npm test", toolName: "Bash", source: "Demo",
                                     cwd: "/tmp", resolver: { _, _ in })
        approve(s, demo, times: 6)
        XCTAssertEqual(s.approvalCount(for: demo), 0,
                       "pressing the demo button in settings is not a habit")
    }

    /// One entry per distinct command, and a busy machine sees a lot of them.
    /// The cap has to drop the noise without losing a real habit.
    func testTheTallyIsCappedWithoutLosingRepeats() {
        let s = AppState()
        let habit = request(detail: "npm test")
        approve(s, habit, times: 3)

        for i in 0...(AppState.repeatApprovalsCap + 10) {
            s.noteManualApproval(request(detail: "echo one-off-\(i)"))
        }

        XCTAssertLessThanOrEqual(s.repeatApprovals.count, AppState.repeatApprovalsCap + 1,
                                 "the map must not grow without bound")
        XCTAssertEqual(s.approvalCount(for: habit), 3,
                       "the command that was actually repeated must survive the cull")
    }

    func testTheKeyMatchesTheRuleThatWouldBeMade() {
        let key = AppState.approvalKey(tool: "Bash", detail: "npm test")
        let rule = AllowRule(tool: "Bash",
                             commandRegex: "^\(NSRegularExpression.escapedPattern(for: "npm test"))$")
        XCTAssertEqual(key, rule.id,
                       "count and rule must share an identity, or the count survives the rule")
    }
}
