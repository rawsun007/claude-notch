import XCTest
@testable import ClaudeNotch

/// resumeCommand is the "Copy resume command" clipboard text and mirrors the
/// same claude-vs-codex branch that resume(model:) dispatches on. If the two
/// ever drift, the copied command would launch the wrong CLI for a session, so
/// pin the mapping: Codex-family models get `codex resume`, everything else
/// (Claude, Grok Build) gets `claude --resume`.
final class ResumeCommandTests: XCTestCase {

    func testCodexModelsUseCodexResume() {
        for model in ["gpt-5-codex", "gpt-4o", "codex-mini", "o1-preview", "o3"] {
            XCTAssertEqual(
                TerminalAutomator.resumeCommand(model: model, sessionId: "abc123"),
                "codex resume abc123",
                "expected codex resume for \(model)")
        }
    }

    func testClaudeAndGrokUseClaudeResume() {
        for model in ["claude-opus-4-8", "claude-sonnet-5", "grok-2", "", "unknown-model"] {
            XCTAssertEqual(
                TerminalAutomator.resumeCommand(model: model, sessionId: "sess-9"),
                "claude --resume sess-9",
                "expected claude --resume for \(model)")
        }
    }

    func testSessionIdIsCarriedVerbatim() {
        XCTAssertEqual(
            TerminalAutomator.resumeCommand(model: "claude-opus-4-8",
                                            sessionId: "7f3e-AB_9.0"),
            "claude --resume 7f3e-AB_9.0")
    }
}
