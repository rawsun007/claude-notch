import XCTest
@testable import ClaudeNotch

/// A held mouse button means two different things depending on whether the
/// card is already open: over a closed notch it is a file being dragged in,
/// over the open card it is a click on one of its buttons.
final class HoverDecisionTests: XCTestCase {

    func testAClickOnTheOpenCardKeepsItOpen() {
        // The history button case: open card, cursor on it, button held.
        XCTAssertTrue(MouseTracker.shouldHover(isHovering: true, buttonDown: true, suppressed: false,
                                               inKeepRegion: true, inTriggerZone: true))
    }

    func testADragDoesNotOpenAClosedNotch() {
        XCTAssertFalse(MouseTracker.shouldHover(isHovering: false, buttonDown: true, suppressed: false,
                                                inKeepRegion: false, inTriggerZone: true))
    }

    func testTheOpenCardStillClosesWhenTheCursorLeaves() {
        XCTAssertFalse(MouseTracker.shouldHover(isHovering: true, buttonDown: true, suppressed: false,
                                                inKeepRegion: false, inTriggerZone: false))
        XCTAssertFalse(MouseTracker.shouldHover(isHovering: true, buttonDown: false, suppressed: false,
                                                inKeepRegion: false, inTriggerZone: false))
    }

    func testTheTriggerZoneOpensTheNotch() {
        XCTAssertTrue(MouseTracker.shouldHover(isHovering: false, buttonDown: false, suppressed: false,
                                               inKeepRegion: false, inTriggerZone: true))
    }

    func testSuppressionWinsOverEverything() {
        XCTAssertFalse(MouseTracker.shouldHover(isHovering: true, buttonDown: false, suppressed: true,
                                                inKeepRegion: true, inTriggerZone: true))
    }
}
