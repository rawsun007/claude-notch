import XCTest
import AppKit
@testable import ClaudeNotch

/// A menu-bar app opens its windows while the user is somewhere else entirely,
/// very often inside a full-screen terminal. What a window says about Spaces
/// decides whether it comes to the user or drags the user to it, and the
/// default drags: opening Settings from a full-screen app switched Spaces and
/// dumped the user on the desktop.
@MainActor
final class WindowSpacesTests: XCTestCase {

    private var behavior: NSWindow.CollectionBehavior {
        SettingsWindowController.spacesBehavior
    }

    func testAWindowFollowsTheUserToTheirSpace() {
        XCTAssertTrue(behavior.contains(.moveToActiveSpace))
    }

    /// Without this, showing the window forces macOS out of the full-screen app
    /// the user is in, which is the same interruption by another route.
    func testAWindowCanAppearOverAFullScreenApp() {
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
    }

    /// Right for the notch overlay, wrong here: it pins a window to every Space
    /// permanently, and Settings is something you open, use, and close.
    func testAnOrdinaryWindowDoesNotJoinEverySpace() {
        XCTAssertFalse(behavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(behavior.contains(.stationary))
    }

    /// The two behaviours are contradictory, and setting both is how a window
    /// ends up doing neither reliably.
    func testTheBehaviourIsNotSelfContradictory() {
        XCTAssertFalse(behavior.contains(.moveToActiveSpace) && behavior.contains(.canJoinAllSpaces))
    }

    /// Applying it must actually stick on a real window, not merely be a
    /// constant nobody reads.
    func testTheBehaviourAppliesToAWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.collectionBehavior = SettingsWindowController.spacesBehavior
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
    }
}
