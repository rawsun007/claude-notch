import XCTest
@testable import ClaudeNotch

/// Codex sends argv arrays and patch blobs where Claude sends plain strings.
/// When the extraction misses, every Codex card degrades to a bare tool name
/// ("shell", "web_search") with no line saying what is actually running, which
/// is the whole point of the card.
final class CodexToolDetailTests: XCTestCase {

    func testShellArgvArrayUnwrapsBashWrapper() {
        let input: [String: Any] = ["command": ["bash", "-lc", "git status --short"], "workdir": "/repo"]
        XCTAssertEqual(humanDetail(for: "shell", input: input), "git status --short")
        XCTAssertEqual(humanTitle(for: "shell"), "Run shell command")
    }

    func testShellPlainArgvIsJoined() {
        let input: [String: Any] = ["command": ["ls", "-la", "/tmp"]]
        XCTAssertEqual(humanDetail(for: "shell", input: input), "ls -la /tmp")
    }

    func testShellStringCommandStillWorks() {
        XCTAssertEqual(humanDetail(for: "shell", input: ["command": "echo hi"]), "echo hi")
    }

    func testShellFallsBackToJustification() {
        XCTAssertEqual(humanDetail(for: "shell", input: ["justification": "install deps"]),
                       "install deps")
    }

    func testWebSearchQuery() {
        XCTAssertEqual(humanDetail(for: "web_search", input: ["query": "swift 6 concurrency"]),
                       "swift 6 concurrency")
        XCTAssertEqual(humanTitle(for: "web_search"), "Search the web")
    }

    /// The exact payload Codex 0.145 sends for its web tool, captured from a
    /// live hook: the query is nested in an array of action objects.
    func testWebRunSearchQueryArray() {
        let input: [String: Any] = [
            "search_query": [["q": "swift concurrency news"]],
            "response_length": "short",
        ]
        XCTAssertEqual(humanDetail(for: "webrun", input: input), "swift concurrency news")
        XCTAssertEqual(humanTitle(for: "webrun"), "Search the web")
    }

    func testWebRunOpenAction() {
        let input: [String: Any] = ["open": [["url": "https://swift.org"]]]
        XCTAssertEqual(humanDetail(for: "webrun", input: input), "open https://swift.org")
    }

    func testWebRunMultipleQueriesAreJoined() {
        let input: [String: Any] = ["search_query": [["q": "one"], ["q": "two"]]]
        XCTAssertEqual(humanDetail(for: "webrun", input: input), "one  ·  two")
    }

    /// Codex carries the whole patch envelope under `command`, not `input`.
    func testApplyPatchUnderCommandKey() {
        let patch = "*** Begin Patch\n*** Update File: /tmp/a.txt\n@@\n-hello\n+goodbye\n*** End Patch"
        XCTAssertEqual(humanDetail(for: "apply_patch", input: ["command": patch]), "/tmp/a.txt")
    }

    func testApplyPatchNamesTheFile() {
        let patch = """
        *** Begin Patch
        *** Update File: Sources/ClaudeNotch/EventServer.swift
        @@
        -old
        +new
        *** End Patch
        """
        let detail = humanDetail(for: "apply_patch", input: ["input": patch])
        XCTAssertEqual(detail, "Sources/ClaudeNotch/EventServer.swift")
        XCTAssertEqual(humanTitle(for: "apply_patch"), "Edit file")
    }

    func testApplyPatchMultipleFilesAreCounted() {
        let patch = """
        *** Begin Patch
        *** Add File: a.swift
        *** Delete File: b.swift
        *** End Patch
        """
        XCTAssertEqual(humanDetail(for: "apply_patch", input: ["patch": patch]),
                       "2 files  ·  a.swift, b.swift")
    }

    func testApplyPatchPreviewShowsPatchHead() {
        let patch = "*** Begin Patch\n*** Add File: a.swift\n+line\n*** End Patch"
        guard case .write(let head, let total)? =
                ToolPreviewParser.preview(for: "apply_patch", input: ["input": patch]) else {
            return XCTFail("expected a write preview")
        }
        XCTAssertTrue(head.hasPrefix("*** Begin Patch"))
        XCTAssertEqual(total, 4)
    }

    func testUpdatePlanShowsCurrentStep() {
        let input: [String: Any] = ["plan": [
            ["step": "read the code", "status": "completed"],
            ["step": "write the fix", "status": "in_progress"],
            ["step": "test", "status": "pending"],
        ]]
        XCTAssertEqual(humanDetail(for: "update_plan", input: input), "write the fix  (1/3)")
    }

    func testShellDangerScansArgvArray() {
        let input: [String: Any] = ["command": ["bash", "-lc", "sudo rm -rf /tmp/x"]]
        let reasons = ToolPreviewParser.dangerReasons(for: "shell", input: input)
        XCTAssertTrue(reasons.contains { $0.hasPrefix("rm -rf") })
        XCTAssertTrue(reasons.contains { $0.hasPrefix("sudo") })
    }

    func testApplyPatchIntoSystemDirIsFlagged() {
        let patch = "*** Begin Patch\n*** Update File: /etc/hosts\n*** End Patch"
        XCTAssertFalse(ToolPreviewParser.dangerReasons(for: "apply_patch", input: ["input": patch]).isEmpty)
    }

    func testUnknownToolStillFindsAnArgvCommand() {
        XCTAssertEqual(humanDetail(for: "some_future_tool", input: ["command": ["echo", "hi"]]),
                       "echo hi")
    }

    func testEmptyInputYieldsEmptyDetail() {
        XCTAssertEqual(humanDetail(for: "shell", input: [:]), "")
        XCTAssertEqual(humanDetail(for: "web_search", input: [:]), "")
    }
}
