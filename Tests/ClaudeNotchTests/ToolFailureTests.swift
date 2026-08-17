import XCTest
@testable import ClaudeNotch

/// A session whose every command fails looked exactly like a session working:
/// the only thing on screen was the name of the tool it had just started.
final class ToolFailureTests: XCTestCase {

    private func payload(tool: String = "Bash",
                         error: Any = "npm ERR! code ELIFECYCLE",
                         interrupt: Bool = false,
                         durationMs: Int = 1200) -> [String: Any] {
        [
            "hook_event_name": "PostToolUseFailure",
            "session_id": "s1",
            "cwd": "/tmp/proj",
            "tool_name": tool,
            "tool_use_id": "tu_1",
            "error": error,
            "is_interrupt": interrupt,
            "duration_ms": durationMs,
        ]
    }

    // MARK: - Reading the payload

    func testAFailureIsParsed() throws {
        let e = try XCTUnwrap(ToolFailure.parse(payload()))
        XCTAssertEqual(e.toolName, "Bash")
        XCTAssertEqual(e.reason, "npm ERR! code ELIFECYCLE")
        XCTAssertEqual(e.durationMs, 1200)
        XCTAssertTrue(e.isWorthRecording)
    }

    /// Pressing Esc comes through this same hook and is the one failure that is
    /// not one: they know, they did it.
    func testAnInterruptIsNotAFailure() throws {
        let e = try XCTUnwrap(ToolFailure.parse(payload(interrupt: true)))
        XCTAssertFalse(e.isWorthRecording)
    }

    func testInterruptIsReadFromEveryShapeItArrivesIn() throws {
        for raw in [true as Any, 1 as Any, "true" as Any] {
            var p = payload()
            p["is_interrupt"] = raw
            XCTAssertFalse(try XCTUnwrap(ToolFailure.parse(p)).isWorthRecording, "\(raw)")
        }
    }

    func testAPayloadWithoutAToolIsIgnored() {
        var p = payload()
        p["tool_name"] = ""
        XCTAssertNil(ToolFailure.parse(p))
        XCTAssertNil(ToolFailure.parse(["hook_event_name": "PostToolUseFailure"]))
    }

    /// A tool error is written for a model to read, so it can be a paragraph or
    /// a stack trace. The first meaningful line is what a person wants.
    func testTheReasonIsOneLine() throws {
        let e = try XCTUnwrap(ToolFailure.parse(payload(error: "\n\n  error: no such file\n  at foo()\n  at bar()")))
        XCTAssertEqual(e.reason, "error: no such file")
    }

    func testAStructuredErrorIsFlattened() throws {
        let e = try XCTUnwrap(ToolFailure.parse(payload(error: ["message": "connection refused"])))
        XCTAssertEqual(e.reason, "connection refused")
    }

    func testAHugeErrorIsCapped() throws {
        let e = try XCTUnwrap(ToolFailure.parse(payload(error: String(repeating: "x", count: 10_000))))
        XCTAssertEqual(e.reason.count, ToolFailure.maxReason)
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
    private func fail(_ s: AppState, tool: String = "Bash", times: Int) {
        let event = ToolFailure.parse(payload(tool: tool))!
        for _ in 0..<times { s.noteToolFailed(event, sessionId: "s1", cwd: "/tmp/proj") }
    }

    @MainActor
    func testEveryFailureIsRecorded() {
        let s = state()
        fail(s, times: 2)
        XCTAssertEqual(s.history.filter { $0.title.contains("failed") }.count, 2)
    }

    /// Tools fail on purpose all the time. One card per failure is noise you
    /// learn to dismiss, which is worse than no card at all.
    @MainActor
    func testOneFailureRaisesNoCard() {
        let s = state()
        fail(s, times: 1)
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }

    @MainActor
    func testARunOfTheSameFailureRaisesOneCard() {
        let s = state()
        fail(s, times: ToolFailure.failuresBeforeCard)
        XCTAssertEqual(s.permissionQueue.count, 1)
        XCTAssertTrue(s.permissionQueue.first?.title.contains("3 times") ?? false)

        // And not again at four and five: the point has been made.
        fail(s, times: 2)
        XCTAssertEqual(s.permissionQueue.count, 1)
    }

    /// Different tools failing once each is a session doing several things,
    /// not a session stuck.
    @MainActor
    func testFailuresOfDifferentToolsDoNotAccumulate() {
        let s = state()
        fail(s, tool: "Bash", times: 1)
        fail(s, tool: "Read", times: 1)
        fail(s, tool: "Edit", times: 1)
        XCTAssertTrue(s.permissionQueue.isEmpty)
        XCTAssertEqual(s.sessions["s1"]?.consecutiveFailures, 1)
    }

    /// A tool that works ends the run.
    @MainActor
    func testSuccessResetsTheRun() {
        let s = state()
        fail(s, times: 2)
        s.noteToolSucceeded(sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertEqual(s.sessions["s1"]?.consecutiveFailures, 0)
        fail(s, times: 2)
        XCTAssertTrue(s.permissionQueue.isEmpty, "the run should have restarted from zero")
    }

    @MainActor
    func testAnInterruptRecordsNothing() {
        let s = state()
        let event = ToolFailure.parse(payload(interrupt: true))!
        s.noteToolFailed(event, sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertTrue(s.history.isEmpty)
        XCTAssertTrue(s.permissionQueue.isEmpty)
        XCTAssertEqual(s.sessions["s1"]?.consecutiveFailures, 0)
    }

    // MARK: - Wiring

    func testTheHookIsInstalled() {
        var hooks: [String: Any] = [:]
        HookInstaller.appendHook(to: "PostToolUseFailure", in: &hooks, matcher: ".*")
        XCTAssertNotNil(hooks["PostToolUseFailure"])
    }

    func testTheCardSaysSomethingWhenTheErrorTextIsEmpty() {
        XCTAssertFalse(ToolFailure.stuckDetail(reason: "   \n ").isEmpty)
        XCTAssertEqual(ToolFailure.stuckDetail(reason: "boom"), "boom")
    }
}
