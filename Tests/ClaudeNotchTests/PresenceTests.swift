import XCTest
@testable import ClaudeNotch

/// Holding the chime while nobody is there is only safe if "there" is decided
/// correctly: hold it while someone is at the keyboard and they lose the one
/// signal that a task finished.
@MainActor
final class PresenceTests: XCTestCase {

    private func task(_ title: String = "Ran the tests") -> CompletedTask {
        CompletedTask(title: title, detail: "42 passed", source: "test", cwd: "/tmp/project")
    }

    private func state(idle: TimeInterval) -> AppState {
        let s = AppState()
        s.idleSecondsProvider = { idle }
        return s
    }

    func testTheThresholdIsWhereItSays() {
        XCTAssertFalse(AppState.isAway(idleSeconds: 0))
        XCTAssertFalse(AppState.isAway(idleSeconds: AppState.awayAfter - 1),
                       "reading a diff for two minutes is not being away")
        XCTAssertTrue(AppState.isAway(idleSeconds: AppState.awayAfter))
        XCTAssertTrue(AppState.isAway(idleSeconds: 3600))
    }

    func testAtTheKeyboardNothingIsHeld() {
        let s = state(idle: 5)
        s.enqueueCompleted(task())
        XCTAssertEqual(s.completedWhileAway, 0,
                       "someone is here to hear it, so the chime is not deferred")
        XCTAssertEqual(s.completedQueue.count, 1)
    }

    func testAwayHoldsTheChimeButNotTheCard() {
        let s = state(idle: AppState.awayAfter + 60)
        s.enqueueCompleted(task("First"))
        s.enqueueCompleted(task("Second"))

        XCTAssertEqual(s.completedWhileAway, 2, "both finished with nobody here")
        XCTAssertEqual(s.completedQueue.count, 2,
                       "the cards must still be waiting: holding the sound is not dropping the work")
    }

    func testComingBackAnnouncesOnceAndClears() {
        let s = state(idle: AppState.awayAfter + 60)
        s.enqueueCompleted(task("First"))
        s.enqueueCompleted(task("Second"))

        s.idleSecondsProvider = { 0 }   // a keypress: they are back
        XCTAssertTrue(s.checkReturnFromAway())
        XCTAssertEqual(s.completedWhileAway, 0)

        XCTAssertFalse(s.checkReturnFromAway(),
                       "the second tick a second later must not announce it all again")
    }

    func testStillAwayIsNotAReturn() {
        let s = state(idle: AppState.awayAfter + 60)
        s.enqueueCompleted(task())
        XCTAssertFalse(s.checkReturnFromAway(),
                       "nobody has come back yet, so nothing should be announced")
        XCTAssertEqual(s.completedWhileAway, 1, "and the tally must survive the tick")
    }

    func testNothingHappenedWhileAwayIsNotWorthSaying() {
        let s = state(idle: 0)
        XCTAssertFalse(s.checkReturnFromAway(),
                       "sitting down to an idle machine should be silent")
    }

    /// The tally is deliberately not persisted: opening the app tomorrow to
    /// "4 tasks finished while you were away" is a stale receipt, not news.
    func testTheTallyStartsEmptyOnAFreshState() {
        XCTAssertEqual(AppState().completedWhileAway, 0)
    }
}
