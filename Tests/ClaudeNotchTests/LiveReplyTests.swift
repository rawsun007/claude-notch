import XCTest
@testable import ClaudeNotch

/// The opt-in live reply (MessageDisplay hook): the row shows a one-line tail.
final class LiveReplyTests: XCTestCase {
    func testTailIsOneLineAndCapped() {
        let t = AppState.replyTail(String(repeating: "word ", count: 200) + "\n**done** with `code`\n")
        XCTAssertFalse(t.contains("\n"))
        XCTAssertFalse(t.contains("**"))
        XCTAssertFalse(t.contains("`"))
        XCTAssertLessThanOrEqual(t.count, 240)
        XCTAssertTrue(t.hasSuffix("done with code "), t)
    }
}
