import XCTest
@testable import ClaudeNotch

/// The permission/completed/question queues are fed straight from hook payloads,
/// so their cap is a denial-of-service guard: a local process spraying blocking
/// hooks must not grow them without bound. capFront is the shared trim the three
/// didSets run. It has to keep the NEWEST entries (the cards a user would act on)
/// and drop the stalest off the front.
final class QueueCapTests: XCTestCase {

    func testUnderCapUntouched() {
        XCTAssertEqual(AppState.capFront(Array(0..<10), to: 64), Array(0..<10))
    }

    func testAtCapUntouched() {
        let a = AppState.capFront(Array(0..<64), to: 64)
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(a.first, 0)
    }

    func testOverCapKeepsNewestDropsStalest() {
        let a = AppState.capFront(Array(0..<100), to: 64) // 0 stalest, 99 newest
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(a.first, 36) // dropped 0...35
        XCTAssertEqual(a.last, 99)
    }

    func testHostileBurstStillBounded() {
        let a = AppState.capFront(Array(0..<10_000), to: 64)
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(a.last, 9_999)
    }
}
