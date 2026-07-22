import XCTest
@testable import ClaudeNotch

/// The day-bucket labels drive how the resume list is grouped, so an off-by-one
/// at a day boundary would put a session under the wrong header.
final class SessionResumerTests: XCTestCase {

    private func utcCal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func at(_ s: String, _ cal: Calendar) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func testDayBuckets() {
        let cal = utcCal()
        let now = at("2026-07-22 10:00", cal)
        XCTAssertEqual(SessionResumer.dayBucket(at("2026-07-22 01:00", cal), asOf: now, calendar: cal), "Today")
        XCTAssertEqual(SessionResumer.dayBucket(at("2026-07-21 23:00", cal), asOf: now, calendar: cal), "Yesterday")
        XCTAssertEqual(SessionResumer.dayBucket(at("2026-07-18 12:00", cal), asOf: now, calendar: cal), "Earlier this week")
        XCTAssertEqual(SessionResumer.dayBucket(at("2026-07-10 12:00", cal), asOf: now, calendar: cal), "Older")
    }
}
