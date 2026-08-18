import XCTest
import LocalAuthentication
@testable import ClaudeNotch

/// The Touch ID gate is the only way to allow a dangerous command when it is
/// switched on, so what happens when it fails decides whether the user is
/// stuck.
final class BiometricFailureTests: XCTestCase {

    private func error(_ code: LAError.Code) -> NSError {
        NSError(domain: LAErrorDomain, code: code.rawValue)
    }

    /// Cancelling is an answer, not a failure. The card says nothing, because
    /// the user just said no.
    func testCancellingSaysNothing() {
        XCTAssertNil(BiometricAuth.failureMessage(for: error(.userCancel)))
        XCTAssertNil(BiometricAuth.failureMessage(for: error(.appCancel)))
        XCTAssertNil(BiometricAuth.failureMessage(for: error(.systemCancel)))
        XCTAssertNil(BiometricAuth.failureMessage(for: nil))
    }

    /// Falling back to the password is the system taking over, not a failure to
    /// report: its own prompt is on screen.
    func testTheFallbackToPasswordSaysNothing() {
        XCTAssertNil(BiometricAuth.failureMessage(for: error(.userFallback)))
    }

    /// The one that stranded people: three unrecognised fingers locks biometry
    /// until the Mac is unlocked with a password, and the button just stopped
    /// working.
    func testLockoutExplainsItselfAndSaysWhatToDo() {
        let msg = BiometricAuth.failureMessage(for: error(.biometryLockout))
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg?.lowercased().contains("password") ?? false, msg ?? "")
    }

    /// Biometrics disappearing mid-session (lid closed, external keyboard)
    /// points at the button that still works.
    func testUnavailableBiometricsPointsAtHoldToConfirm() {
        for code in [LAError.Code.biometryNotAvailable, .biometryNotEnrolled] {
            let msg = BiometricAuth.failureMessage(for: error(code))
            XCTAssertNotNil(msg, "\(code)")
            XCTAssertTrue(msg?.lowercased().contains("hold") ?? false, msg ?? "")
        }
    }

    /// Anything else still says something rather than nothing, and says plainly
    /// that the command was not allowed.
    func testEveryOtherFailureStillSaysSomething() {
        for code in [LAError.Code.authenticationFailed, .invalidContext, .notInteractive] {
            let msg = BiometricAuth.failureMessage(for: error(code))
            XCTAssertNotNil(msg, "\(code)")
            XCTAssertFalse(msg?.isEmpty ?? true)
        }
    }

    /// No message is allowed to leak an error code at the user.
    func testTheMessagesAreInEnglish() {
        for code in [LAError.Code.biometryLockout, .biometryNotAvailable, .authenticationFailed] {
            let msg = BiometricAuth.failureMessage(for: error(code)) ?? ""
            XCTAssertFalse(msg.contains("LAError"), msg)
            // No bare error numbers. A hyphen on its own is fine: the messages
            // say things like "hold-to-confirm".
            XCTAssertNil(msg.range(of: #"-?\d{3,}"#, options: .regularExpression), msg)
        }
    }
}
