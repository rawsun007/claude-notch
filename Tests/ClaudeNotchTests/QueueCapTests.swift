import XCTest
@testable import ClaudeNotch

/// The permission/completed/question queues are fed straight from hook payloads,
/// so their cap is a denial-of-service guard: a local process spraying blocking
/// hooks must not grow them without bound. capFront is the shared trim the three
/// didSets run. It has to keep the NEWEST entries (the cards a user would act on)
/// and drop the stalest off the front.
final class QueueCapTests: XCTestCase {

    func testUnderCapUntouched() {
        var a = Array(0..<10)
        AppState.capFront(&a, to: 64)
        XCTAssertEqual(a, Array(0..<10))
    }

    func testAtCapUntouched() {
        var a = Array(0..<64)
        AppState.capFront(&a, to: 64)
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(a.first, 0)
    }

    func testOverCapKeepsNewestDropsStalest() {
        var a = Array(0..<100)   // 0 is stalest, 99 is newest
        AppState.capFront(&a, to: 64)
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(a.first, 36) // dropped 0...35
        XCTAssertEqual(a.last, 99)
    }

    func testHostileBurstStillBounded() {
        var a = Array(0..<10_000)
        AppState.capFront(&a, to: 64)
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(a.last, 9_999)
    }
}
