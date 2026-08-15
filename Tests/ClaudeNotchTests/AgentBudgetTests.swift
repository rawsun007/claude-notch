import XCTest
@testable import ClaudeNotch

/// A session that quietly stops delegating, or stops searching, reads as one
/// that decided not to bother. Both budgets are only ever stated in a tool
/// result, so that string is the whole contract.
final class AgentBudgetTests: XCTestCase {

    // MARK: - Limits

    func testDefaultsMatchClaudeCode() {
        let limits = AgentBudgets.limits(env: [:])
        XCTAssertEqual(limits.concurrentSubagents, 20)
        XCTAssertEqual(limits.webSearchesPerSession, 200)
    }

    func testRaisedCapsAreRead() {
        let limits = AgentBudgets.limits(env: [
            "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS": "40",
            "CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION": "1000",
        ])
        XCTAssertEqual(limits.concurrentSubagents, 40)
        XCTAssertEqual(limits.webSearchesPerSession, 1000)
    }

    /// A zero or unreadable cap would draw every session as permanently out of
    /// budget, so it is ignored rather than believed.
    func testNonsenseValuesFallBackToTheDefaults() {
        for bad in ["0", "-3", "", "lots", "20; rm -rf /"] {
            let limits = AgentBudgets.limits(env: ["CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS": bad])
            XCTAssertEqual(limits.concurrentSubagents, 20, "\(bad)")
        }
    }

    func testSettingsEnvIsRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-budget-settings-\(UUID().uuidString).json")
        try #"{"env":{"CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS":30,"CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION":"5"}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let limits = AgentBudgets.limits(env: AgentBudgets.settingsEnv(at: url.path))
        XCTAssertEqual(limits.concurrentSubagents, 30)   // a JSON number counts
        XCTAssertEqual(limits.webSearchesPerSession, 5)
    }

    func testAMissingOrBrokenSettingsFileIsNotAnError() {
        XCTAssertEqual(AgentBudgets.settingsEnv(at: "/nonexistent/settings.json"), [:])
    }

    // MARK: - Reading the refusal

    func testTheSubagentRefusalIsRecognised() {
        let response = "Concurrent subagent limit reached. You can run 20 subagents at once. Do not retry."
        XCTAssertEqual(AgentBudgets.capReached(in: response), .subagents)
    }

    func testTheWebSearchRefusalIsRecognised() {
        let response = ["content": [["type": "text",
                                     "text": "Web search was not performed: this session has used its web search budget (200 of 200 WebSearch calls)."]]]
        XCTAssertEqual(AgentBudgets.capReached(in: response), .webSearches)
    }

    func testOrdinaryResultsAreNotRefusals() {
        XCTAssertNil(AgentBudgets.capReached(in: "Done."))
        XCTAssertNil(AgentBudgets.capReached(in: nil))
        XCTAssertNil(AgentBudgets.capReached(in: 42))
        XCTAssertNil(AgentBudgets.capReached(in: ["ok": true]))
    }

    /// A tool result can be megabytes. Only the start of it is searched.
    func testFlattenIsBounded() {
        let huge = String(repeating: "a", count: 100_000)
        XCTAssertLessThanOrEqual(AgentBudgets.flatten(["text": huge]).count, 4000)
    }

    // MARK: - What the session records

    @MainActor
    private func state() -> AppState {
        let s = AppState()
        s.currentCwd = "/tmp/proj"
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        return s
    }

    @MainActor
    func testPeakConcurrencyIsTheHighWaterMark() {
        let s = state()
        s.noteSubagentStarted(sessionId: "s1")
        s.noteSubagentStarted(sessionId: "s1")
        s.noteSubagentStopped(sessionId: "s1")
        XCTAssertEqual(s.sessions["s1"]?.runningAgentCount, 1)
        XCTAssertEqual(s.sessions["s1"]?.peakAgentCount, 2)
    }

    @MainActor
    func testSearchesAreCounted() {
        let s = state()
        s.noteWebSearch(sessionId: "s1")
        s.noteWebSearch(sessionId: "s1")
        XCTAssertEqual(s.sessions["s1"]?.webSearchCount, 2)
    }

    @MainActor
    func testACapIsRecordedOnceNoMatterHowOftenItIsHit() {
        let s = state()
        s.noteBudgetCapReached(.subagents, sessionId: "s1", cwd: "/tmp/proj")
        s.noteBudgetCapReached(.subagents, sessionId: "s1", cwd: "/tmp/proj")
        s.noteBudgetCapReached(.subagents, sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertTrue(s.sessions["s1"]?.agentCapHit ?? false)
        XCTAssertEqual(s.history.filter { $0.toolName == "Task" }.count, 1)
    }

    @MainActor
    func testTheTwoBudgetsAreTrackedSeparately() {
        let s = state()
        s.noteBudgetCapReached(.webSearches, sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertTrue(s.sessions["s1"]?.webSearchCapHit ?? false)
        XCTAssertFalse(s.sessions["s1"]?.agentCapHit ?? true)
    }
}
