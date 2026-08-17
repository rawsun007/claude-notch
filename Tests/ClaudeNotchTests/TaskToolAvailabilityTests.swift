import XCTest
@testable import ClaudeNotch

/// The task meter is fed by tools Claude Code stopped handing to its newer
/// models in 2.1.233. An empty meter and a meter with nothing to show look the
/// same, so the app has to tell them apart before it says anything.
final class TaskToolAvailabilityTests: XCTestCase {

    private let busy = TaskToolAvailability.toolCallsBeforeConcluding

    func testASessionThatReportedATaskIsFine() {
        XCTAssertFalse(TaskToolAvailability.looksDisabled(
            toolCalls: busy * 5, everReportedTask: true, cliVersion: "2.1.233"))
    }

    /// A short piece of work with no checklist is ordinary, not evidence.
    func testAQuietSessionIsNotEvidence() {
        XCTAssertFalse(TaskToolAvailability.looksDisabled(
            toolCalls: busy - 1, everReportedTask: false, cliVersion: "2.1.233"))
    }

    func testALongSessionWithNoTaskEverIsEvidence() {
        XCTAssertTrue(TaskToolAvailability.looksDisabled(
            toolCalls: busy, everReportedTask: false, cliVersion: "2.1.233"))
    }

    /// On a CLI from before the removal, an empty meter means the work had no
    /// checklist. Saying anything there would be a guess dressed as advice.
    func testAnOlderCLIIsNeverBlamed() {
        XCTAssertFalse(TaskToolAvailability.looksDisabled(
            toolCalls: busy * 3, everReportedTask: false, cliVersion: "2.1.232"))
        XCTAssertTrue(TaskToolAvailability.looksDisabled(
            toolCalls: busy * 3, everReportedTask: false, cliVersion: "2.1.233"))
    }

    /// An unknown version is assumed current, because that is what a session
    /// the registry has not described is most likely to be.
    func testAnUnknownVersionIsTreatedAsCurrent() {
        XCTAssertTrue(TaskToolAvailability.looksDisabled(
            toolCalls: busy, everReportedTask: false, cliVersion: ""))
    }

    // MARK: - The flag that fixes it

    func testTheFlagIsReadFromAnEnvBlock() {
        XCTAssertTrue(TaskToolAvailability.isEnabled(env: ["CLAUDE_CODE_ENABLE_TODO_TOOLS": "1"]))
        XCTAssertTrue(TaskToolAvailability.isEnabled(env: ["CLAUDE_CODE_ENABLE_TODO_TOOLS": "true"]))
    }

    func testOffAndAbsentBothCountAsOff() {
        XCTAssertFalse(TaskToolAvailability.isEnabled(env: [:]))
        XCTAssertFalse(TaskToolAvailability.isEnabled(env: ["CLAUDE_CODE_ENABLE_TODO_TOOLS": "0"]))
        XCTAssertFalse(TaskToolAvailability.isEnabled(env: ["CLAUDE_CODE_ENABLE_TODO_TOOLS": "false"]))
        XCTAssertFalse(TaskToolAvailability.isEnabled(env: ["CLAUDE_CODE_ENABLE_TODO_TOOLS": "  "]))
    }

    /// The advice has to name the variable, or it is not advice.
    func testTheHintSaysWhatToSet() {
        XCTAssertTrue(TaskToolAvailability.hintDetail.contains("CLAUDE_CODE_ENABLE_TODO_TOOLS"))
        XCTAssertTrue(TaskToolAvailability.hintDetail.contains("2.1.233"))
        XCTAssertFalse(TaskToolAvailability.hintTitle.isEmpty)
    }

    // MARK: - Sessions

    @MainActor
    func testTheSessionFlagFollowsRealTaskData() {
        let s = AppState()
        s.currentCwd = "/tmp/proj"
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        XCTAssertFalse(s.sessions["s1"]?.everReportedTask ?? true)

        s.noteTodos(total: 3, done: 1, sessionId: "s1")
        XCTAssertTrue(s.sessions["s1"]?.everReportedTask ?? false)
    }

    @MainActor
    func testTaskCreatedAndCompletedAlsoCount() {
        let s = AppState()
        s.currentCwd = "/tmp/proj"
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        s.noteTaskCreated(id: "t1", sessionId: "s1")
        XCTAssertTrue(s.sessions["s1"]?.everReportedTask ?? false)

        let s2 = AppState()
        s2.currentCwd = "/tmp/proj"
        s2.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        s2.noteTaskCompleted(id: "t1", sessionId: "s1")
        XCTAssertTrue(s2.sessions["s1"]?.everReportedTask ?? false)
    }

    @MainActor
    func testOnlyTheBusyTasklessSessionsAreListed() {
        let s = AppState()
        s.currentCwd = "/tmp/proj"
        s.upsertSession(id: "busy", cwd: "/tmp/proj", create: true) {
            $0.toolCallCount = TaskToolAvailability.toolCallsBeforeConcluding
            $0.cliVersion = "2.1.233"
        }
        s.upsertSession(id: "quiet", cwd: "/tmp/proj2", create: true) {
            $0.toolCallCount = 2
            $0.cliVersion = "2.1.233"
        }
        s.upsertSession(id: "tasked", cwd: "/tmp/proj3", create: true) {
            $0.toolCallCount = 999
            $0.everReportedTask = true
            $0.cliVersion = "2.1.233"
        }
        XCTAssertEqual(s.sessionsWithoutTaskTools.map(\.id), ["busy"])
    }
}
