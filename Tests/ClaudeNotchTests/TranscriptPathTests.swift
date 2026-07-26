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

    func testSymlinkEscapeRejected() throws {
        // A symlink planted INSIDE a transcript root that points outside it must
        // not let the read follow it to an arbitrary file.
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("cn-symtest-\(UUID().uuidString)")
        let rootDir = tmp.appendingPathComponent("root")
        let secretDir = tmp.appendingPathComponent("secret")
        try fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: secretDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let secret = secretDir.appendingPathComponent("id_rsa")
        try "PRIVATE".write(to: secret, atomically: true, encoding: .utf8)
        let link = rootDir.appendingPathComponent("evil.jsonl")
        try fm.createSymbolicLink(at: link, withDestinationURL: secret)

        // Resolve the root path itself (temp dir is under a /var symlink on macOS).
        let root = rootDir.resolvingSymlinksInPath().path + "/"
        // A genuine file under the root passes; the symlink escaping it does not.
        let real = rootDir.appendingPathComponent("real.jsonl")
        try "{}".write(to: real, atomically: true, encoding: .utf8)
        XCTAssertTrue(EventServer.isAllowedTranscriptPath(real.path, roots: [root]))
        XCTAssertFalse(EventServer.isAllowedTranscriptPath(link.path, roots: [root]))
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
