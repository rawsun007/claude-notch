import XCTest
@testable import ClaudeNotch

/// The spend projections. A forecast that is confidently wrong is worse than no
/// forecast, so most of these are about the cases where it must stay silent.
final class CostForecastTests: XCTestCase {

    /// A fixed calendar so a test run in July behaves like one in February.
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func dayMap(_ pairs: [(Int, Double)], month: Int = 6, year: Int = 2025) -> [String: Double] {
        var out: [String: Double] = [:]
        for (day, cost) in pairs {
            out[CostForecast.dayKey(date(year, month, day), calendar: calendar)] = cost
        }
        return out
    }

    // MARK: - The month

    func testTheMonthProjectsFromTheCompletedDays() throws {
        // June 1-4 at $10 each, plus $3 so far today (the 5th). 30 days in June.
        let map = dayMap([(1, 10), (2, 10), (3, 10), (4, 10), (5, 3)])
        let m = try XCTUnwrap(CostForecast.month(dailyCostUSD: map,
                                                 asOf: date(2025, 6, 5),
                                                 calendar: calendar))
        XCTAssertEqual(m.spentSoFar, 43, accuracy: 0.001)
        XCTAssertEqual(m.dailyAverage, 10, accuracy: 0.001)
        XCTAssertEqual(m.daysMeasured, 4)
        XCTAssertEqual(m.daysRemaining, 25)
        XCTAssertEqual(m.projectedTotal, 43 + 250, accuracy: 0.001)
    }

    /// Today is a fraction of a day. Averaging it in makes the projection
    /// cheerful and wrong every morning.
    func testTodayIsNotAveragedIn() throws {
        let map = dayMap([(1, 10), (2, 10), (3, 0.5)])
        let m = try XCTUnwrap(CostForecast.month(dailyCostUSD: map,
                                                 asOf: date(2025, 6, 3, 9),
                                                 calendar: calendar))
        XCTAssertEqual(m.dailyAverage, 10, accuracy: 0.001)
        XCTAssertEqual(m.spentSoFar, 20.5, accuracy: 0.001)
    }

    /// A quiet day is real data and belongs in the average. Otherwise a week of
    /// working every other day projects as if you worked every day.
    func testAQuietDayCountsAsZeroNotAsMissing() throws {
        let map = dayMap([(1, 10), (3, 10), (4, 1)])
        let m = try XCTUnwrap(CostForecast.month(dailyCostUSD: map,
                                                 asOf: date(2025, 6, 4),
                                                 calendar: calendar))
        XCTAssertEqual(m.daysMeasured, 3)
        XCTAssertEqual(m.dailyAverage, 20.0 / 3, accuracy: 0.001)
    }

    /// The per-day map only reaches back four weeks. Days before that are
    /// absent, not free, and counting them as zero would halve the average.
    func testDaysOlderThanTheDataAreNotCountedAsZero() throws {
        // The 30th of a 31-day month: days 1 and 2 are outside the 28-day window.
        let map = dayMap([(29, 10), (30, 1)], month: 7)
        let m = try XCTUnwrap(CostForecast.month(dailyCostUSD: map,
                                                 asOf: date(2025, 7, 30),
                                                 calendar: calendar))
        XCTAssertEqual(m.daysMeasured, CostForecast.coveredDays)
        XCTAssertEqual(m.dailyAverage, 10.0 / Double(CostForecast.coveredDays), accuracy: 0.001)
    }

    func testTheFirstOfTheMonthHasNothingToProjectFrom() {
        let map = dayMap([(1, 5)])
        XCTAssertNil(CostForecast.month(dailyCostUSD: map, asOf: date(2025, 6, 1), calendar: calendar))
    }

    func testAMonthWithNoSpendSaysNothing() {
        XCTAssertNil(CostForecast.month(dailyCostUSD: [:], asOf: date(2025, 6, 15), calendar: calendar))
        XCTAssertNil(CostForecast.month(dailyCostUSD: dayMap([(1, 0), (2, 0)]),
                                        asOf: date(2025, 6, 3), calendar: calendar))
    }

    // MARK: - Today against the cap

    func testTodayProjectsTheWholeDayFromTheRateSoFar() throws {
        // $6 by 12:00 is half a day, so $12 by midnight.
        let f = try XCTUnwrap(CostForecast.today(spent: 6, cap: 20,
                                                 asOf: date(2025, 6, 5, 12),
                                                 calendar: calendar))
        XCTAssertEqual(f.projectedTotal, 12, accuracy: 0.01)
    }

    func testItSaysWhenTheCapWillBeCrossed() throws {
        // $6 by 12:00 is $0.50/hour; $4 to go is eight more hours, so 20:00.
        let f = try XCTUnwrap(CostForecast.today(spent: 6, cap: 10,
                                                 asOf: date(2025, 6, 5, 12),
                                                 calendar: calendar))
        let crossesAt = try XCTUnwrap(f.crossesAt)
        XCTAssertEqual(crossesAt.timeIntervalSince(date(2025, 6, 5, 20)), 0, accuracy: 60)
    }

    /// A cap the day's rate never reaches is not a crossing.
    func testNoCrossingWhenTheDayEndsFirst() throws {
        let f = try XCTUnwrap(CostForecast.today(spent: 6, cap: 100,
                                                 asOf: date(2025, 6, 5, 12),
                                                 calendar: calendar))
        XCTAssertNil(f.crossesAt)
    }

    /// $2 spent by 00:20 extrapolates to a fortune. A warning built on that is
    /// one people learn to dismiss.
    func testTheDayIsTooYoungToProjectFrom() {
        XCTAssertNil(CostForecast.today(spent: 2, cap: 10,
                                        asOf: date(2025, 6, 5, 0, 20),
                                        calendar: calendar))
    }

    func testNoCapAndNoSpendMeanNoForecast() {
        XCTAssertNil(CostForecast.today(spent: 5, cap: 0, asOf: date(2025, 6, 5, 12), calendar: calendar))
        XCTAssertNil(CostForecast.today(spent: 0, cap: 10, asOf: date(2025, 6, 5, 12), calendar: calendar))
    }

    /// Once the cap is crossed the 100% alert has already spoken; there is
    /// nothing left to forecast.
    func testAlreadyOverTheCapHasNoCrossing() throws {
        let f = try XCTUnwrap(CostForecast.today(spent: 12, cap: 10,
                                                 asOf: date(2025, 6, 5, 12),
                                                 calendar: calendar))
        XCTAssertNil(f.crossesAt)
    }

    // MARK: - The warning

    func testItWarnsAboutACrossingThatIsCloseEnoughToMatter() {
        let now = date(2025, 6, 5, 12)
        let soon = CostForecast.DayAgainstCap(projectedTotal: 30,
                                              crossesAt: now.addingTimeInterval(90 * 60))
        XCTAssertNotNil(CostForecast.warning(soon, cap: 10, asOf: now))
    }

    /// A crossing eight hours out will have moved several times before it
    /// arrives, so saying it now is noise.
    func testItStaysQuietAboutADistantCrossing() {
        let now = date(2025, 6, 5, 12)
        let far = CostForecast.DayAgainstCap(projectedTotal: 30,
                                             crossesAt: now.addingTimeInterval(8 * 3600))
        XCTAssertNil(CostForecast.warning(far, cap: 10, asOf: now))
    }

    func testNoCrossingMeansNoWarning() {
        let now = date(2025, 6, 5, 12)
        XCTAssertNil(CostForecast.warning(nil, cap: 10, asOf: now))
        XCTAssertNil(CostForecast.warning(.init(projectedTotal: 5, crossesAt: nil), cap: 10, asOf: now))
    }
}
