import XCTest
@testable import ClaudeNotch

/// Skipping confirmation for destructive commands drops the gesture and
/// nothing else, and switching it on always takes the owner's authentication.
final class DestructiveGateTests: XCTestCase {

    func testDefaultGates() {
        XCTAssertEqual(DestructiveGate.gate(requireTouchID: true, biometricsAvailable: true, skipConfirmation: false), .biometric)
        XCTAssertEqual(DestructiveGate.gate(requireTouchID: true, biometricsAvailable: false, skipConfirmation: false), .hold)
        XCTAssertEqual(DestructiveGate.gate(requireTouchID: false, biometricsAvailable: true, skipConfirmation: false), .hold)
        XCTAssertEqual(DestructiveGate.gate(requireTouchID: false, biometricsAvailable: false, skipConfirmation: false), .hold)
    }

    func testSkippingWinsOverTouchID() {
        for touch in [true, false] {
            for bio in [true, false] {
                XCTAssertEqual(DestructiveGate.gate(requireTouchID: touch, biometricsAvailable: bio, skipConfirmation: true), .none)
            }
        }
    }

    func testReturnKey() {
        XCTAssertTrue(DestructiveGate.returnAllows(isDangerous: false, budgetBlocked: false, skipConfirmation: false))
        XCTAssertFalse(DestructiveGate.returnAllows(isDangerous: true, budgetBlocked: false, skipConfirmation: false))
        XCTAssertTrue(DestructiveGate.returnAllows(isDangerous: true, budgetBlocked: false, skipConfirmation: true))
    }

    func testBudgetBlockNeverTakesReturn() {
        for dangerous in [true, false] {
            for skip in [true, false] {
                XCTAssertFalse(DestructiveGate.returnAllows(isDangerous: dangerous, budgetBlocked: true, skipConfirmation: skip))
            }
        }
    }

    func testOnlySwitchingOnNeedsAuthentication() {
        XCTAssertTrue(DestructiveGate.needsAuthentication(from: false, to: true))
        XCTAssertFalse(DestructiveGate.needsAuthentication(from: true, to: false))
        XCTAssertFalse(DestructiveGate.needsAuthentication(from: true, to: true))
        XCTAssertFalse(DestructiveGate.needsAuthentication(from: false, to: false))
    }
}
