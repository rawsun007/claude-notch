import XCTest
@testable import ClaudeNotch

/// The break reminder. Every notch app's most-requested feature is some kind of
/// pomodoro, and every one of them makes you start a timer. This one is measured
/// from Claude Code's hooks, so it cannot be wrong about whether you were working,
/// and there is nothing to start.
final class FocusTrackerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func working(_ tracker: inout FocusTracker, minutes: [Double]) {
        for m in minutes { tracker.noteActivity(at: at(m)) }
    }

    func testAStretchIsMeasuredFromRealActivity() {
        var f = FocusTracker()
        working(&f, minutes: [0, 5, 10, 20, 30])
        XCTAssertEqual(f.stretch(now: at(30)), 30 * 60, accuracy: 1)
    }

    func testBeingAwayEndsTheStretch() {
        // The gap IS the break. Nothing to declare.
        var f = FocusTracker()
        working(&f, minutes: [0, 10])
        working(&f, minutes: [40])          // back after half an hour away
        XCTAssertEqual(f.stretch(now: at(45)), 5 * 60, accuracy: 1,
                       "the new stretch starts when you came back, not when you first sat down")
    }

    func testThinkingIsNotABreak() {
        // Reading a diff, or thinking, must not reset the stretch, or it never
        // reaches the point where a reminder is worth anything.
        var f = FocusTracker()
        working(&f, minutes: [0, 3, 9, 14])   // gaps of a few minutes
        XCTAssertEqual(f.stretch(now: at(14)), 14 * 60, accuracy: 1)
    }

    func testWhileYouAreOnABreakTheStretchIsZero() {
        var f = FocusTracker()
        working(&f, minutes: [0, 10])
        XCTAssertEqual(f.stretch(now: at(10 + 9)), 0, "away longer than the break window")
    }

    func testItNudgesOncePerStretch() {
        // A nudge that fires twice is a nag, and a nag gets switched off, which
        // costs you every later nudge as well.
        var f = FocusTracker()
        working(&f, minutes: Array(stride(from: 0.0, through: 60.0, by: 5.0)))
        XCTAssertTrue(f.shouldNudge(now: at(60)))
        XCTAssertFalse(f.shouldNudge(now: at(61)))
        XCTAssertFalse(f.shouldNudge(now: at(70)))
    }

    func testAShortStretchIsNotNudged() {
        var f = FocusTracker()
        working(&f, minutes: [0, 10, 20])
        XCTAssertFalse(f.shouldNudge(now: at(20)))
    }

    func testAFreshStretchCanBeNudgedAgain() {
        var f = FocusTracker()
        working(&f, minutes: Array(stride(from: 0.0, through: 60.0, by: 5.0)))
        XCTAssertTrue(f.shouldNudge(now: at(60)))

        // Long break, then a new long stretch: that one earns its own nudge.
        working(&f, minutes: Array(stride(from: 120.0, through: 180.0, by: 5.0)))
        XCTAssertTrue(f.shouldNudge(now: at(180)))
    }
}
