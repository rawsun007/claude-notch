import XCTest
@testable import ClaudeNotch

/// How long a history row says a session took. Wall-clock since the first hook
/// counted every idle hour a terminal sat open, so a session resumed now and
/// then over two weeks read as "280h 50m". Active time skips idle gaps.
final class ActiveDurationTests: XCTestCase {

    func testShortGapsCountAsActive() {
        XCTAssertEqual(SessionRecord.activeIncrement(gap: 1), 1)
        XCTAssertEqual(SessionRecord.activeIncrement(gap: 90), 90)
        XCTAssertEqual(SessionRecord.activeIncrement(gap: SessionRecord.idleGap), SessionRecord.idleGap)
    }

    func testIdleGapsDoNotCount() {
        XCTAssertEqual(SessionRecord.activeIncrement(gap: SessionRecord.idleGap + 1), 0)
        XCTAssertEqual(SessionRecord.activeIncrement(gap: 8 * 3600), 0)
        // A clock that went backwards is not time worked.
        XCTAssertEqual(SessionRecord.activeIncrement(gap: -30), 0)
    }

    private func record(start: Date, end: Date?, active: Double?) -> SessionRecord {
        var r = SessionRecord(sessionKey: "k", project: "p", cwd: "/Users/me/p",
                              startedAt: start, endedAt: end)
        r.activeSeconds = active
        return r
    }

    func testActiveTimeWinsOverWallClock() {
        let start = Date(timeIntervalSince1970: 0)
        let r = record(start: start, end: start.addingTimeInterval(280 * 3600), active: 2 * 3600)
        XCTAssertEqual(r.displayDuration, 2 * 3600)
    }

    func testLegacyRecordFallsBackOnlyWhenBelievable() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(record(start: start, end: start.addingTimeInterval(3 * 3600), active: nil).displayDuration,
                       3 * 3600)
        XCTAssertNil(record(start: start, end: start.addingTimeInterval(280 * 3600), active: nil).displayDuration)
        XCTAssertNil(record(start: start, end: nil, active: nil).displayDuration)
    }

    func testZeroActiveShowsNothing() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertNil(record(start: start, end: start.addingTimeInterval(60), active: 0).displayDuration)
    }

    func testLongDurationsRollIntoDays() {
        XCTAssertEqual(AppState.runningDuration(seconds: 82 * 3600 + 32 * 60), "3d 10h")
        XCTAssertEqual(AppState.runningDuration(seconds: 3600 + 22 * 60), "1h 22m")
    }

    func testOldSnapshotWithoutActiveSecondsDecodes() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","sessionKey":"k","project":"p","cwd":"/x","startedAt":0,"endedAt":60,"contextTokens":0,"costUSD":0,"toolCallCount":0,"model":""}"#
        let r = try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
        XCTAssertNil(r.activeSeconds)
        XCTAssertEqual(r.displayDuration, 60)
    }
}
