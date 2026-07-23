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
