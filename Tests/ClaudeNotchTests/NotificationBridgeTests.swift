import XCTest
import UserNotifications
@testable import ClaudeNotch

/// Notification buttons resolve a permission from outside the app, possibly
/// from the lock screen. The rule that matters is that a dangerous command can
/// never be allowed that way: it has to be answered on the card, behind Touch
/// ID. That rule had no test.
final class NotificationBridgeTests: XCTestCase {

    func testAllowResolvesAnOrdinaryCommand() {
        XCTAssertEqual(
            NotificationBridge.outcome(for: NotificationBridge.actAllow,
                                       isDangerous: false, reason: nil),
            .allow)
    }

    /// The button is not offered for dangerous commands, but a notification
    /// posted before a command was reclassified can still be sitting on a lock
    /// screen with Allow on it.
    func testAllowOnADangerousCommandNeverResolvesRemotely() {
        XCTAssertEqual(
            NotificationBridge.outcome(for: NotificationBridge.actAllow,
                                       isDangerous: true, reason: nil),
            .focusApp,
            "a stale Allow on a dangerous command must send the user to the card, not run it")
    }

    func testDenyWorksForDangerousCommandsToo() {
        XCTAssertEqual(
            NotificationBridge.outcome(for: NotificationBridge.actDeny,
                                       isDangerous: true, reason: nil),
            .deny(reason: nil),
            "saying no is always safe, so danger must not get in the way of it")
    }

    func testDenyWithReasonCarriesTheReason() {
        XCTAssertEqual(
            NotificationBridge.outcome(for: NotificationBridge.actDenyReason,
                                       isDangerous: false, reason: "not on main"),
            .deny(reason: "not on main"))
    }

    /// An empty text field is a deny with nothing to say, not a deny with an
    /// empty string, which would be handed to Claude Code as the reason.
    func testAnEmptyReasonIsNoReason() {
        XCTAssertEqual(
            NotificationBridge.outcome(for: NotificationBridge.actDenyReason,
                                       isDangerous: false, reason: ""),
            .deny(reason: nil))
        XCTAssertEqual(
            NotificationBridge.outcome(for: NotificationBridge.actDenyReason,
                                       isDangerous: false, reason: nil),
            .deny(reason: nil))
    }

    func testTappingTheBodyOpensTheApp() {
        XCTAssertEqual(
            NotificationBridge.outcome(for: UNNotificationDefaultActionIdentifier,
                                       isDangerous: false, reason: nil),
            .focusApp)
    }

    /// Anything unrecognised must fall through to opening the app. Silently
    /// treating an unknown identifier as an answer is how a permission gets
    /// resolved by something nobody wrote.
    func testAnUnknownActionResolvesNothing() {
        for action in ["", "CN_SOMETHING_ELSE", "com.apple.UNNotificationDismissActionIdentifier"] {
            XCTAssertEqual(
                NotificationBridge.outcome(for: action, isDangerous: false, reason: "x"),
                .focusApp,
                "unknown action \(action) must not answer the prompt")
        }
    }

    func testTheReplyActionIsNotAPermissionAnswer() {
        XCTAssertEqual(
            NotificationBridge.outcome(for: NotificationBridge.actReply,
                                       isDangerous: false, reason: "sure, carry on"),
            .focusApp,
            "Reply belongs to completion cards; routed here it must never allow anything")
    }
}
