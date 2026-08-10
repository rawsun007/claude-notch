import XCTest
@testable import ClaudeNotch

/// Codex tracks tasks via update_plan JS embedded in an exec tool, so the plan
/// counter parses unquoted-JS keys out of a string. A miscount would show the
/// wrong N/M in the notch task bar.
final class CodexReaderTests: XCTestCase {

    func testPlanCounts() {
        let js = #"const r = await tools.update_plan({explanation:"go",plan:[{step:"a",status:"completed"},{step:"b",status:"in_progress"},{step:"c",status:"pending"}]})"#
        let c = CodexReader.planCounts(from: js)
        XCTAssertEqual(c?.total, 3)
        XCTAssertEqual(c?.done, 1)
    }

    func testAllCompleted() {
        let js = #"tools.update_plan({plan:[{step:"a",status:"completed"},{step:"b",status:"completed"}]})"#
        let c = CodexReader.planCounts(from: js)
        XCTAssertEqual(c?.total, 2)
        XCTAssertEqual(c?.done, 2)
    }

    func testNoSteps() {
        XCTAssertNil(CodexReader.planCounts(from: "tools.update_plan({plan:[]})"))
    }

    /// A step is counted by its status key, so "step:" inside the step's own
    /// text is text and not a fourth step. Counting raw substrings reported
    /// four steps here and drew a task meter that never reached the end.
    func testStepTextMentioningStepDoesNotInflateTheTotal() {
        let js = #"tools.update_plan({plan:[{step:"Problem 1: redo step: two",status:"completed"},{step:"b",status:"pending"}]})"#
        let c = CodexReader.planCounts(from: js)
        XCTAssertEqual(c?.total, 2)
        XCTAssertEqual(c?.done, 1)
    }

    /// Whitespace around the colon. The old literal `status:"completed"` match
    /// found nothing here, so a finished plan read as zero done.
    func testWhitespaceAroundTheColon() {
        let js = #"tools.update_plan({plan:[{step:"a", status: "completed"}, {step:"b", status: "pending"}]})"#
        let c = CodexReader.planCounts(from: js)
        XCTAssertEqual(c?.total, 2)
        XCTAssertEqual(c?.done, 1)
    }

    /// The word "completed" elsewhere in the call is not a completed step.
    func testExplanationMentioningCompletedIsNotCounted() {
        let js = #"tools.update_plan({explanation:"All tasks completed.",plan:[{step:"a",status:"pending"}]})"#
        let c = CodexReader.planCounts(from: js)
        XCTAssertEqual(c?.total, 1)
        XCTAssertEqual(c?.done, 0)
    }

    /// A shape carrying steps but no status still counts its steps.
    func testStepsWithoutStatusStillCount() {
        let c = CodexReader.planCounts(from: #"tools.update_plan({plan:[{step:"a"},{step:"b"}]})"#)
        XCTAssertEqual(c?.total, 2)
        XCTAssertEqual(c?.done, 0)
    }

    // MARK: - Rate limits

    /// The shape Codex 0.5x writes on a Go plan: one 30-day window, no
    /// secondary. Trimmed to the keys read here.
    private let rateLimits: [String: Any] = [
        "limit_id": "codex",
        "primary": ["used_percent": 28.0, "window_minutes": 43200, "resets_at": 1787301224],
        "secondary": NSNull(),
        "credits": ["has_credits": false, "unlimited": false, "balance": NSNull()],
        "plan_type": "go",
    ]

    func testParsesASingleMonthlyWindow() {
        let l = CodexReader.parseLimits(rateLimits)
        XCTAssertEqual(l?.limits.count, 1)
        XCTAssertEqual(l?.limits.first?.usedPercent, 28)
        XCTAssertEqual(l?.limits.first?.label, "Monthly limit")
        XCTAssertEqual(l?.limits.first?.isPrimary, true)
        XCTAssertEqual(l?.planType, "go")
        XCTAssertEqual(l?.hasCredits, false)
        XCTAssertEqual(l?.limits.first?.resetsAt.map { Int($0.timeIntervalSince1970) }, 1787301224)
    }

    /// A plan with both windows reports them in order, primary first.
    func testParsesBothWindows() {
        let rl: [String: Any] = [
            "primary": ["used_percent": 12, "window_minutes": 300],
            "secondary": ["used_percent": 61, "window_minutes": 10080],
        ]
        let l = CodexReader.parseLimits(rl)
        XCTAssertEqual(l?.limits.map(\.label), ["5-hour limit", "Weekly limit"])
        XCTAssertEqual(l?.limits.last?.isPrimary, false)
    }

    /// The window names come from the reported length, so a shape nobody has
    /// seen still reads as something true.
    func testWindowLabels() {
        XCTAssertEqual(CodexReader.limitLabel(windowMinutes: 300), "5-hour limit")
        XCTAssertEqual(CodexReader.limitLabel(windowMinutes: 10080), "Weekly limit")
        XCTAssertEqual(CodexReader.limitLabel(windowMinutes: 43200), "Monthly limit")
        XCTAssertEqual(CodexReader.limitLabel(windowMinutes: 1440), "Daily limit")
        XCTAssertEqual(CodexReader.limitLabel(windowMinutes: 0), "Usage limit")
        XCTAssertEqual(CodexReader.limitLabel(windowMinutes: 129600), "90-day limit")
    }

    /// A percentage outside 0...100 would draw a bar past the end of its track.
    func testPercentIsClamped() {
        let over = CodexReader.parseLimits(["primary": ["used_percent": 140, "window_minutes": 300]])
        XCTAssertEqual(over?.limits.first?.usedPercent, 100)
        let under = CodexReader.parseLimits(["primary": ["used_percent": -5, "window_minutes": 300]])
        XCTAssertEqual(under?.limits.first?.usedPercent, 0)
    }

    /// Another program's payload: a key that changes name upstream has to read
    /// as a missing row rather than a crash or an invented number.
    func testMissingAndWrongTypesAreTolerated() {
        XCTAssertNil(CodexReader.parseLimits([:]))
        XCTAssertNil(CodexReader.parseLimits(["primary": "not an object"]))
        // A window with no percentage is not a window worth drawing.
        XCTAssertNil(CodexReader.parseLimits(["primary": ["window_minutes": 300]]))
        // A plan with no windows at all is still worth the plan row.
        XCTAssertEqual(CodexReader.parseLimits(["plan_type": "pro"])?.planType, "pro")
        // Numeric strings still count.
        let s = CodexReader.parseLimits(["primary": ["used_percent": "42", "window_minutes": "10080"]])
        XCTAssertEqual(s?.limits.first?.usedPercent, 42)
        XCTAssertEqual(s?.limits.first?.label, "Weekly limit")
    }

    func testUnlimitedCredits() {
        let l = CodexReader.parseLimits([
            "primary": ["used_percent": 1, "window_minutes": 300],
            "credits": ["has_credits": true, "unlimited": true, "balance": 12.5],
        ])
        XCTAssertEqual(l?.unlimitedCredits, true)
        XCTAssertEqual(l?.creditBalance, 12.5)
    }

    // MARK: - Totals

    /// A quiet week is not an empty history. Judging emptiness on the week
    /// alone hid the whole section from anyone who had used Codex before but
    /// not in the last seven days.
    func testAQuietWeekWithHistoryIsNotEmpty() {
        var t = CodexReader.CodexTotals()
        t.allTimeTokens = 2_800_000
        t.allTimeSessions = 30
        XCTAssertFalse(t.isEmpty)
    }

    func testNothingAtAllIsEmpty() {
        XCTAssertTrue(CodexReader.CodexTotals().isEmpty)
    }

    func testThisWeeksWorkIsNotEmpty() {
        var t = CodexReader.CodexTotals()
        t.weekTokens = 14_032
        t.sessionsWeek = 1
        XCTAssertFalse(t.isEmpty)
    }

    // MARK: - Fixture-based rollout parsing

    private func writeRollout() throws -> URL {
        let lines = [
            #"{"type":"session_meta","payload":{"session_id":"abc","id":"abc","cwd":"/tmp/proj","context_window":258400}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-5.6-terra","cwd":"/tmp/proj"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","model_context_window":258400}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":87000,"input_tokens":86000},"last_token_usage":{"input_tokens":15000},"model_context_window":258400}}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"do the thing"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"All done."}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"tools.update_plan({plan:[{step:\"a\",status:\"completed\"},{step:\"b\",status:\"in_progress\"}]})"}}"#,
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-test-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testUsageFromRollout() throws {
        let url = try writeRollout()
        defer { try? FileManager.default.removeItem(at: url) }
        let u = CodexReader.usage(from: url)
        XCTAssertEqual(u?.contextTokens, 15000)   // last turn's input, not cumulative
        XCTAssertEqual(u?.totalTokens, 87000)
        XCTAssertEqual(u?.contextWindow, 258400)
        XCTAssertEqual(u?.model, "gpt-5.6-terra")
    }

    func testLatestPlanFromRollout() throws {
        let url = try writeRollout()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = CodexReader.latestPlan(from: url)
        XCTAssertEqual(p?.total, 2)
        XCTAssertEqual(p?.done, 1)
    }

    func testLastReplyFromRollout() throws {
        let url = try writeRollout()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(CodexReader.lastReply(from: url), "All done.")
    }

    func testGitBranch() throws {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)")
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/feature-x\n".write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: repo) }
        XCTAssertEqual(CodexReader.gitBranch(forCwd: repo.path), "feature-x")
        XCTAssertEqual(CodexReader.gitBranch(forCwd: fm.temporaryDirectory.path + "/definitely-not-a-repo-xyz"), "")
    }
}
