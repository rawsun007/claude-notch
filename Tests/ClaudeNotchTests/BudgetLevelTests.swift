import XCTest
@testable import ClaudeNotch

/// budgetLevel is the single threshold rule behind every spend alert (session,
/// daily, 5-hour, weekly): 100 at/over cap, 80 at the warn line, 0 otherwise. A
/// disabled cap (0) must never fire, or a user with no budget set gets spammed.
final class BudgetLevelTests: XCTestCase {

    func testDisabledCapNeverFires() {
        XCTAssertEqual(AppState.budgetLevel(cost: 999, cap: 0), 0)
        XCTAssertEqual(AppState.budgetLevel(cost: 0, cap: 0), 0)
    }

    func testBelowWarnLine() {
        // 0.79 of a $10 cap is under the 80% line.
        XCTAssertEqual(AppState.budgetLevel(cost: 7.9, cap: 10), 0)
    }

    func testAtWarnLine() {
        XCTAssertEqual(AppState.budgetLevel(cost: 8.0, cap: 10), 80)
    }

    func testBetweenWarnAndCap() {
        XCTAssertEqual(AppState.budgetLevel(cost: 9.5, cap: 10), 80)
    }

    func testExactlyAtCap() {
        XCTAssertEqual(AppState.budgetLevel(cost: 10, cap: 10), 100)
    }

    func testOverCap() {
        XCTAssertEqual(AppState.budgetLevel(cost: 25, cap: 10), 100)
    }
}
