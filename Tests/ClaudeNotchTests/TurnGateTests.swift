import XCTest
@testable import ClaudeNotch

/// Claude Code's hooks aren't ordered. A backgrounded Bash reports its
/// PostToolUse after the turn's Stop, and treating that as "Claude is thinking"
/// strands the notch on a pulsing status forever — nothing else is coming,
/// because Claude is idle waiting for the user.
///
/// These pin the rule: a finished turn is absorbing until real new work starts.
final class TurnGateTests: XCTestCase {

    func testALateHookAfterStopIsIgnored() {
        var gate = TurnGate()
        let key = TurnGate.key(sessionId: "abc", cwd: "/tmp/x")
        XCTAssertFalse(gate.isLate(key))
        gate.turnEnded(key)
        XCTAssertTrue(gate.isLate(key), "PostToolUse arriving after Stop must be dropped")
    }

    func testAHookDuringALiveTurnIsHonoured() {
        var gate = TurnGate()
        let key = TurnGate.key(sessionId: "abc", cwd: "")
        gate.workStarted(key)
        XCTAssertFalse(gate.isLate(key))
    }

    func testANewUserPromptRevivesTheSession() {
        var gate = TurnGate()
        let key = TurnGate.key(sessionId: "abc", cwd: "")
        gate.turnEnded(key)
        gate.workStarted(key)   // UserPromptSubmit
        XCTAssertFalse(gate.isLate(key), "the next turn's hooks must not be swallowed")
    }

    func testTheNextTurnsFirstToolRevivesTheSession() {
        var gate = TurnGate()
        let key = TurnGate.key(sessionId: "abc", cwd: "")
        gate.turnEnded(key)
        gate.workStarted(key)   // PreToolUse
        XCTAssertFalse(gate.isLate(key))
    }

    func testEndingOneTurnDoesNotSilenceAnotherSession() {
        var gate = TurnGate()
        let finished = TurnGate.key(sessionId: "one", cwd: "")
        let running = TurnGate.key(sessionId: "two", cwd: "")
        gate.turnEnded(finished)
        XCTAssertTrue(gate.isLate(finished))
        XCTAssertFalse(gate.isLate(running), "sessions run independently")
    }

    func testEndingATurnTwiceIsHarmless() {
        var gate = TurnGate()
        let key = TurnGate.key(sessionId: "abc", cwd: "")
        gate.turnEnded(key)
        gate.turnEnded(key)
        gate.workStarted(key)
        XCTAssertFalse(gate.isLate(key))
    }

    func testResetForgetsEverything() {
        var gate = TurnGate()
        gate.turnEnded(TurnGate.key(sessionId: "abc", cwd: ""))
        gate.reset()
        XCTAssertFalse(gate.isLate("abc"))
    }

    // MARK: - Keys

    func testSessionIdWinsOverCwd() {
        XCTAssertEqual(TurnGate.key(sessionId: "abc", cwd: "/tmp/x"), "abc")
    }

    func testCwdIsTheFallbackAndIsNormalised() {
        // Must agree with `upsertSession`, or Stop files the session under one
        // key and PostToolUse looks it up under another — and the gate never fires.
        XCTAssertEqual(TurnGate.key(sessionId: "", cwd: "/tmp/x/"), "/tmp/x")
        XCTAssertEqual(TurnGate.key(sessionId: "", cwd: "/tmp/x///"), "/tmp/x")
        XCTAssertEqual(TurnGate.key(sessionId: "", cwd: "/tmp/x"), "/tmp/x")
        XCTAssertEqual(TurnGate.key(sessionId: "", cwd: "/"), "/")
    }

    func testAnEmptyKeyIsNeverGated() {
        // No session id and no cwd: we can't tell whose turn ended, so don't
        // silence hooks for everyone.
        var gate = TurnGate()
        gate.turnEnded("")
        XCTAssertFalse(gate.isLate(""))
    }
}
