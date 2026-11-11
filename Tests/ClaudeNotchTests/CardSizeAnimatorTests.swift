import XCTest
@testable import ClaudeNotch

/// When a card's measured height lands while it is still opening, the animator
/// moves the end of the curve instead of starting a new one. That only looks
/// right if the size drawn on the next frame is the size already on screen,
/// which is what rebasedStart solves for.
final class CardSizeAnimatorTests: XCTestCase {

    private func value(start: CGFloat, target: CGFloat, eased: Double) -> CGFloat {
        start + (target - start) * CGFloat(eased)
    }

    func testRebasedCurvePassesThroughTheCurrentSize() {
        // Opening from a 32pt notch toward a 164pt formula height, 30% of the
        // way in, when the measurement says 210pt.
        let eased = 0.3
        let onScreen = value(start: 32, target: 164, eased: eased)
        let start = CardSizeAnimator.rebasedStart(current: onScreen, target: 210, eased: eased)
        XCTAssertEqual(value(start: start, target: 210, eased: eased), onScreen, accuracy: 0.0001)
        // And it still ends where the measurement says.
        XCTAssertEqual(value(start: start, target: 210, eased: 1), 210, accuracy: 0.0001)
    }

    func testRebaseAtTheVeryStartIsTheCurrentSize() {
        XCTAssertEqual(CardSizeAnimator.rebasedStart(current: 32, target: 210, eased: 0), 32, accuracy: 0.0001)
    }

    func testRebaseTowardASmallerTargetStaysContinuous() {
        let eased = 0.5
        let onScreen = value(start: 400, target: 120, eased: eased)
        let start = CardSizeAnimator.rebasedStart(current: onScreen, target: 100, eased: eased)
        XCTAssertEqual(value(start: start, target: 100, eased: eased), onScreen, accuracy: 0.0001)
    }
}
