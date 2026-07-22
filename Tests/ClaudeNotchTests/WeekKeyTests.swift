import XCTest
@testable import ClaudeNotch

/// weekKey gates the weekly digest to once per calendar week, so dates in the
/// same ISO week must share a key and a week boundary must change it.
final class WeekKeyTests: XCTestCase {

    private func utcCal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2   // Monday, matching ISO
        c.minimumDaysInFirstWeek = 4
        return c
    }
    private func date(_ s: String, _ cal: Calendar) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    func testSameWeekSharesKey() {
        let cal = utcCal()
        let mon = AppState.weekKey(date("2026-07-20", cal), calendar: cal)
        let wed = AppState.weekKey(date("2026-07-22", cal), calendar: cal)
        let sun = AppState.weekKey(date("2026-07-26", cal), calendar: cal)
        XCTAssertEqual(mon, wed)
        XCTAssertEqual(mon, sun)
    }

    func testNextWeekChangesKey() {
        let cal = utcCal()
        let thisWeek = AppState.weekKey(date("2026-07-22", cal), calendar: cal)
        let nextWeek = AppState.weekKey(date("2026-07-27", cal), calendar: cal)
        XCTAssertNotEqual(thisWeek, nextWeek)
    }
}
