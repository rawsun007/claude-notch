import XCTest
@testable import ClaudeNotch

/// The key normalizer is the seam that lets non-Claude agents reuse the whole
/// hook pipeline, so a wrong or lossy mapping would silently break Grok/Codex
/// support while looking fine for Claude.
final class AgentAdapterTests: XCTestCase {

    func testClaudePayloadPassesThroughUnchanged() {
        let p: [String: Any] = ["session_id": "abc", "tool_name": "Bash", "cwd": "/tmp"]
        let out = AgentAdapter.normalizeKeys(p)
        XCTAssertEqual(out["session_id"] as? String, "abc")
        XCTAssertEqual(out["tool_name"] as? String, "Bash")
        XCTAssertEqual(out["cwd"] as? String, "/tmp")
    }

    func testCamelCaseIsMappedToSnakeCase() {
        let p: [String: Any] = [
            "hookEventName": "PreToolUse",
            "sessionId": "s1",
            "toolName": "shell",
            "toolInput": ["command": "ls"],
            "workspaceRoot": "/repo",
        ]
        let out = AgentAdapter.normalizeKeys(p)
        XCTAssertEqual(out["hook_event_name"] as? String, "PreToolUse")
        XCTAssertEqual(out["session_id"] as? String, "s1")
        XCTAssertEqual(out["tool_name"] as? String, "shell")
        XCTAssertEqual((out["tool_input"] as? [String: Any])?["command"] as? String, "ls")
        // workspaceRoot fills cwd when cwd is absent.
        XCTAssertEqual(out["cwd"] as? String, "/repo")
    }

    func testRealCwdWinsOverWorkspaceRoot() {
        let p: [String: Any] = ["cwd": "/real", "workspaceRoot": "/root"]
        let out = AgentAdapter.normalizeKeys(p)
        XCTAssertEqual(out["cwd"] as? String, "/real")
    }

    func testModelInference() {
        XCTAssertEqual(AgentKind.infer(fromModel: "grok-4.5"), .grok)
        XCTAssertEqual(AgentKind.infer(fromModel: "gpt-5-codex"), .codex)
        XCTAssertEqual(AgentKind.infer(fromModel: "claude-opus-4-8"), .claude)
        XCTAssertEqual(AgentKind.infer(fromModel: ""), .claude)
    }

    func testNotchLabels() {
        XCTAssertEqual(AgentKind.claude.notchLabel, "Claude")
        XCTAssertEqual(AgentKind.grok.notchLabel, "Grok")
        XCTAssertEqual(AgentKind.codex.notchLabel, "Codex")
    }
}
