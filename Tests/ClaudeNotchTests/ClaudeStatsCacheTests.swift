import XCTest
@testable import ClaudeNotch

/// Claude Code's `~/.claude/stats-cache.json`, the file behind its `/stats`
/// screen. Worth reading because it is computed across all history, unlike the
/// bounded transcript window the app parses itself.
///
/// The fixtures below are the real file's shape, cut down. Its key names are
/// Claude Code's private contract, so a test that pins them is the thing that
/// tells us when a CLI update moves the ground.
final class ClaudeStatsCacheTests: XCTestCase {

    private func json(_ s: String) -> Data { Data(s.utf8) }

    private let sample = """
    {
      "version": 5,
      "lastComputedDate": "2026-09-07",
      "totalSessions": 99,
      "totalMessages": 90889,
      "firstSessionDate": "2026-04-17T12:03:51.758Z",
      "longestSession": { "duration": 2265008853, "messageCount": 19680 },
      "modelUsage": {
        "claude-opus-5": { "inputTokens": 100, "outputTokens": 200,
                           "cacheReadInputTokens": 3000, "cacheCreationInputTokens": 40,
                           "costUSD": 0 },
        "claude-sonnet-5": { "inputTokens": 1, "outputTokens": 2,
                             "cacheReadInputTokens": 3, "cacheCreationInputTokens": 4,
                             "costUSD": 0 }
      },
      "dailyActivity": [
        { "date": "2026-09-05", "messageCount": 10, "sessionCount": 1, "toolCallCount": 5 },
        { "date": "2026-09-06", "messageCount": 90, "sessionCount": 2, "toolCallCount": 9 },
        { "date": "2026-09-07", "messageCount": 20, "sessionCount": 1, "toolCallCount": 3 }
      ]
    }
    """

    func testReadsTheHeadlineFigures() throws {
        let s = try XCTUnwrap(ClaudeStatsCache.parse(json(sample)))
        XCTAssertEqual(s.totalSessions, 99)
        XCTAssertEqual(s.totalMessages, 90889)
        XCTAssertEqual(s.lastComputedDate, "2026-09-07")
    }

    /// The duration is milliseconds in the file. 2_265_008_853 is 26 days if it
    /// is ms and 71 years if it is seconds, and the CLI shows 26d, which is how
    /// the unit was established.
    func testLongestSessionDurationIsMilliseconds() throws {
        let s = try XCTUnwrap(ClaudeStatsCache.parse(json(sample)))
        XCTAssertEqual(s.longestSessionSeconds, 2_265_008)
        XCTAssertEqual(s.longestSessionSeconds / 86400, 26)
    }

    /// Total tokens includes cache, which is what makes the CLI's figure look
    /// enormous next to a cost estimate: cache reads dominate and are billed at
    /// a fraction.
    func testTotalTokensIncludesCache() throws {
        let s = try XCTUnwrap(ClaudeStatsCache.parse(json(sample)))
        XCTAssertEqual(s.perModel["claude-opus-5"]?.total, 3340)
        XCTAssertEqual(s.totalTokens, 3340 + 10)
    }

    func testFavouriteModelIsTheOneWithTheMostTokens() throws {
        let s = try XCTUnwrap(ClaudeStatsCache.parse(json(sample)))
        XCTAssertEqual(s.favouriteModel, "claude-opus-5")
    }

    /// The active-days denominator comes from the calendar, not from how many
    /// rows the file has. The file only records days that had activity, so
    /// counting rows gives 3/3 and says nothing.
    func testActiveDaysAreCountedAgainstTheElapsedSpan() throws {
        let s = try XCTUnwrap(ClaudeStatsCache.parse(json(sample)))
        XCTAssertEqual(s.activeDays, 3)
        let today = try XCTUnwrap(ClaudeStatsCache.isoDay("2026-04-19"))
        XCTAssertEqual(s.spanDays(today: today), 3, "17th, 18th, 19th inclusive")
    }

    func testMostActiveDayIsByMessageCount() throws {
        let s = try XCTUnwrap(ClaudeStatsCache.parse(json(sample)))
        XCTAssertEqual(s.mostActiveDay?.date, "2026-09-06")
    }

    // MARK: - Streaks

    func testConsecutiveDaysAreOneStreak() throws {
        let s = try XCTUnwrap(ClaudeStatsCache.parse(json(sample)))
        let (longest, current) = ClaudeStatsCache.streaks(s.daily, today: "2026-09-07")
        XCTAssertEqual(longest, 3)
        XCTAssertEqual(current, 3)
    }

    /// A streak that ended yesterday is still current. The cache is recomputed
    /// at most once a day, so demanding today's date would report every streak
    /// as broken each morning until the CLI caught up.
    func testAStreakEndingYesterdayIsStillCurrent() throws {
        let s = try XCTUnwrap(ClaudeStatsCache.parse(json(sample)))
        let (_, current) = ClaudeStatsCache.streaks(s.daily, today: "2026-09-08")
        XCTAssertEqual(current, 3)
    }

    func testAnOldStreakIsNotCurrent() throws {
        let s = try XCTUnwrap(ClaudeStatsCache.parse(json(sample)))
        let (longest, current) = ClaudeStatsCache.streaks(s.daily, today: "2026-09-20")
        XCTAssertEqual(longest, 3, "history keeps its longest run")
        XCTAssertEqual(current, 0)
    }

    func testAGapBreaksTheStreak() {
        let days = [
            ClaudeStatsCache.DayActivity(date: "2026-09-01", messages: 1, sessions: 1, toolCalls: 0),
            ClaudeStatsCache.DayActivity(date: "2026-09-02", messages: 1, sessions: 1, toolCalls: 0),
            ClaudeStatsCache.DayActivity(date: "2026-09-05", messages: 1, sessions: 1, toolCalls: 0),
        ]
        let (longest, current) = ClaudeStatsCache.streaks(days, today: "2026-09-05")
        XCTAssertEqual(longest, 2)
        XCTAssertEqual(current, 1)
    }

    /// Month ends are the calendar's problem, not string arithmetic's.
    func testStreaksCrossMonthBoundaries() {
        let days = [
            ClaudeStatsCache.DayActivity(date: "2026-08-30", messages: 1, sessions: 1, toolCalls: 0),
            ClaudeStatsCache.DayActivity(date: "2026-08-31", messages: 1, sessions: 1, toolCalls: 0),
            ClaudeStatsCache.DayActivity(date: "2026-09-01", messages: 1, sessions: 1, toolCalls: 0),
        ]
        let (longest, _) = ClaudeStatsCache.streaks(days, today: "2026-09-01")
        XCTAssertEqual(longest, 3)
        XCTAssertTrue(ClaudeStatsCache.isNextDay("2026-08-31", "2026-09-01"))
        XCTAssertFalse(ClaudeStatsCache.isNextDay("2026-08-31", "2026-09-02"))
    }

    // MARK: - Degrading

    /// The format is Claude Code's private contract and carries a version. A
    /// renamed key must cost us that one figure, not the whole file, which is
    /// why this is JSONSerialization rather than a strict Decodable.
    func testUnknownAndMissingKeysDegradeToZero() throws {
        let s = try XCTUnwrap(ClaudeStatsCache.parse(json("""
        { "version": 99, "totalSessions": 7, "somethingNew": true }
        """)))
        XCTAssertEqual(s.totalSessions, 7)
        XCTAssertEqual(s.totalMessages, 0)
        XCTAssertTrue(s.perModel.isEmpty)
        XCTAssertNil(s.favouriteModel)
    }

    func testGarbageIsRejectedRatherThanGuessed() {
        XCTAssertNil(ClaudeStatsCache.parse(json("not json")))
        XCTAssertNil(ClaudeStatsCache.parse(json("[1,2,3]")))
    }

    func testAMissingFileIsNotAnError() {
        XCTAssertNil(ClaudeStatsCache.load(from: "/nonexistent/stats-cache.json"))
    }

    /// Counts here exceed what a Double holds exactly, and the file has been
    /// seen writing both forms.
    func testLargeCountsSurviveEitherJsonNumberForm() throws {
        let s = try XCTUnwrap(ClaudeStatsCache.parse(json("""
        { "modelUsage": { "m": { "cacheReadInputTokens": 6841103263,
                                 "inputTokens": 264720.0 } } }
        """)))
        XCTAssertEqual(s.perModel["m"]?.cacheRead, 6_841_103_263)
        XCTAssertEqual(s.perModel["m"]?.input, 264_720)
    }
}
