import XCTest
@testable import ClaudeNotch

/// transcript_path arrives in an untrusted hook payload and is handed to a
/// bounded file read. isAllowedTranscriptPath is the gate that keeps a crafted
/// path (an absolute system file, or a `..` escape out of the transcript root)
/// from being read: only files under the agent transcript roots pass.
final class TranscriptPathTests: XCTestCase {

    private let home = "/Users/tester"
    private lazy var roots = EventServer.transcriptRoots(home: home, env: [:])

    private func allowed(_ p: String) -> Bool {
        EventServer.isAllowedTranscriptPath(p, roots: roots)
    }

    func testRealTranscriptPathsAllowed() {
        XCTAssertTrue(allowed("\(home)/.claude/projects/foo/abc.jsonl"))
        XCTAssertTrue(allowed("\(home)/.codex/sessions/2026/01/x.jsonl"))
    }

    func testAbsoluteSystemFileRejected() {
        XCTAssertFalse(allowed("/etc/passwd"))
        XCTAssertFalse(allowed("\(home)/.ssh/id_rsa"))
    }

    func testTraversalEscapeRejected() {
        // Standardization collapses the .. so it can't climb out of the root.
        XCTAssertFalse(allowed("\(home)/.claude/../.ssh/id_rsa"))
        XCTAssertFalse(allowed("\(home)/.claude/projects/../../.ssh/id_rsa"))
    }

    func testSiblingPrefixNotMatched() {
        // "~/.claudeEVIL" must not pass just because it starts with the root name.
        XCTAssertFalse(allowed("\(home)/.claudeEVIL/x.jsonl"))
    }

    func testEmptyRejected() {
        XCTAssertFalse(allowed(""))
    }

    func testEnvOverrideRoots() {
        let env = ["CLAUDE_CONFIG_DIR": "/opt/claude", "CODEX_HOME": "/opt/codex/"]
        let r = EventServer.transcriptRoots(home: home, env: env)
        XCTAssertTrue(EventServer.isAllowedTranscriptPath("/opt/claude/projects/x.jsonl", roots: r))
        XCTAssertTrue(EventServer.isAllowedTranscriptPath("/opt/codex/sessions/x.jsonl", roots: r))
        // The default ~/.claude no longer counts once overridden.
        XCTAssertFalse(EventServer.isAllowedTranscriptPath("\(home)/.claude/x.jsonl", roots: r))
    }
}
