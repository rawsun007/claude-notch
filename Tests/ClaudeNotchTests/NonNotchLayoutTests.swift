import XCTest
import AppKit
@testable import ClaudeNotch

/// On Macs without a hardware notch (Air, older MacBooks, external displays)
/// the app draws a floating pill and must keep cards clear of the menu bar
/// rather than assuming a notch. These cover the screen-independent paths.
@MainActor
final class NonNotchLayoutTests: XCTestCase {

    func testNoNotchWhenScreenNil() {
        XCTAssertFalse(NotchView.hasNotch(nil))
    }

    func testMenuBarHeightFallback() {
        // With no screen to measure, fall back to a sane menu-bar height.
        XCTAssertEqual(NotchView.menuBarHeight(on: nil), 24)
    }

    func testInsetIsMenuBarWhenNoNotch() {
        // Non-notch inset must be non-zero (the menu bar) so expanded cards
        // clear the bar instead of rendering under it.
        XCTAssertEqual(NotchView.notchInset(on: nil), NotchView.menuBarHeight(on: nil))
        XCTAssertGreaterThan(NotchView.notchInset(on: nil), 0)
    }

    func testCollapsedPillSizeWhenNoNotch() {
        let s = NotchView.collapsedSize(on: nil)
        XCTAssertEqual(s.width, 200)
        // Pill height tracks the inset band and is never a sliver.
        XCTAssertGreaterThanOrEqual(s.height, 28)
    }
}
