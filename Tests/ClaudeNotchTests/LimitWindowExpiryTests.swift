import XCTest
@testable import ClaudeNotch

/// Claude Code only reports plan usage while a session is redrawing, so a
/// reading can outlive the window it measured by many hours. From this
/// machine's own log: a 5-hour reading taken at 07:37 with reset=07:40, then
/// nothing at all until 05:28 the next day. For twenty-two hours the app held a
/// reset instant that had already passed.
final class LimitWindowExpiryTests: XCTestCase {

    // MARK: - The rendering that gave it away

    /// The countdown says the word "now" for a past date, which is what the
    /// stale reading turned into on screen.
    func testAPastResetRendersAsNow() {
        let past = Date().addingTimeInterval(-2 * 3600)
        XCTAssertEqual(ClaudeUsageReader.resetCountdown(until: past), "now")
    }

    // MARK: - Expiry

    @MainActor
    private func state(fiveHourResetAt: Date?, pct: Double = 0.82) -> AppState {
        let s = AppState()
        s.fiveHourLimitPercent = pct
        s.fiveHourResetAt = fiveHourResetAt
        return s
    }

    @MainActor
    func testAnExpiredWindowIsForgotten() {
        let s = state(fiveHourResetAt: Date().addingTimeInterval(-2 * 3600))
        XCTAssertTrue(s.expireStaleLimitWindows())
        XCTAssertNil(s.fiveHourResetAt)
        XCTAssertEqual(s.fiveHourLimitPercent, -1, "the percentage was measured in a window that ended")
    }

    /// Both halves go, not just the date. Clearing the date alone would leave a
    /// stale percentage looking like a current one, since nothing downstream
    /// would know its window had ended.
    @MainActor
    func testThePercentageGoesWithTheDate() {
        let s = state(fiveHourResetAt: Date().addingTimeInterval(-60))
        s.expireStaleLimitWindows()
        XCTAssertNil(StatusBarRow.livePercent(s.fiveHourLimitPercent, resetAt: s.fiveHourResetAt),
                     "an expired window must read as unknown, not as a number")
    }

    @MainActor
    func testARunningWindowIsLeftAlone() {
        let future = Date().addingTimeInterval(90 * 60)
        let s = state(fiveHourResetAt: future)
        XCTAssertFalse(s.expireStaleLimitWindows())
        XCTAssertEqual(s.fiveHourResetAt, future)
        XCTAssertEqual(s.fiveHourLimitPercent, 0.82)
    }

    @MainActor
    func testNoReadingIsNotAnExpiredOne() {
        let s = AppState()
        XCTAssertFalse(s.expireStaleLimitWindows())
        XCTAssertNil(s.fiveHourResetAt)
    }

    @MainActor
    func testTheWeeklyWindowExpiresToo() {
        let s = AppState()
        s.weeklyLimitPercent = 0.87
        s.weeklyResetAt = Date().addingTimeInterval(-3600)
        XCTAssertTrue(s.expireStaleLimitWindows())
        XCTAssertNil(s.weeklyResetAt)
        XCTAssertEqual(s.weeklyLimitPercent, -1)
    }

    /// One window ending must not take the other with it. The weekly window
    /// routinely outlives several five-hour ones.
    @MainActor
    func testOneWindowEndingDoesNotEndTheOther() {
        let s = AppState()
        s.fiveHourLimitPercent = 0.82
        s.fiveHourResetAt = Date().addingTimeInterval(-3600)
        s.weeklyLimitPercent = 0.40
        let weekly = Date().addingTimeInterval(3 * 24 * 3600)
        s.weeklyResetAt = weekly
        s.expireStaleLimitWindows()
        XCTAssertNil(s.fiveHourResetAt)
        XCTAssertEqual(s.weeklyResetAt, weekly)
        XCTAssertEqual(s.weeklyLimitPercent, 0.40)
    }

    // MARK: - Through a status line

    /// The regression, in the shape the log recorded it.
    ///
    /// A status line arrives carrying a fresh percentage but no reset instant,
    /// while the stored reset is from a window that ended hours ago. The old
    /// date must not survive to be described as "now".
    @MainActor
    func testAFreshReadingWithNoResetDoesNotInheritADeadWindow() {
        let s = AppState()
        s.fiveHourLimitPercent = 0.82
        s.fiveHourResetAt = Date().addingTimeInterval(-2 * 3600)

        s.noteStatusLine(sessionId: "s1", model: "claude-opus-5",
                         contextPct: nil, fiveHourPct: 58, sevenDayPct: nil)

        XCTAssertNil(s.fiveHourResetAt, "the dead window's date must not survive")
        XCTAssertEqual(s.fiveHourLimitPercent, 0.58, accuracy: 0.001,
                       "but the reading this line actually brought must")
    }

    /// The other half of the ordering: expiry runs before the new values land,
    /// so a line carrying both a percentage and a new reset keeps both.
    @MainActor
    func testAFreshReadingWithANewResetKeepsBoth() {
        let s = AppState()
        s.fiveHourLimitPercent = 0.82
        s.fiveHourResetAt = Date().addingTimeInterval(-2 * 3600)
        let next = Date().addingTimeInterval(3 * 3600)

        s.noteStatusLine(sessionId: "s1", model: "claude-opus-5",
                         contextPct: nil, fiveHourPct: 58, sevenDayPct: nil,
                         fiveHourResetsAt: next)

        XCTAssertEqual(s.fiveHourResetAt, next)
        XCTAssertEqual(s.fiveHourLimitPercent, 0.58, accuracy: 0.001)
    }

    /// The warning card must never tell somebody a window "resets in now" when
    /// deciding whether to wait it out is the whole reason they are reading it.
    @MainActor
    func testTheWarningCardNeverSaysResetsInNow() {
        let s = AppState()
        s.fiveHourLimitPercent = 0.5
        s.fiveHourResetAt = Date().addingTimeInterval(-2 * 3600)

        s.noteStatusLine(sessionId: "s1", model: "claude-opus-5",
                         contextPct: nil, fiveHourPct: 95, sevenDayPct: nil)

        for card in s.permissionQueue where card.toolName == "RateLimit" {
            XCTAssertFalse(card.detail.contains("resets in now"), card.detail)
        }
    }
}
