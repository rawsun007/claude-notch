import XCTest
@testable import ClaudeNotch

/// A claudenotch:// link can be opened by any page the user visits, and the
/// browser's "open this app?" prompt is a habit, not a decision. Resuming
/// starts an agent, so from a link it has to be asked about.
@MainActor
final class ScriptedResumeTests: XCTestCase {

    private func delegate() -> AppDelegate {
        let d = AppDelegate()
        d.state.currentProject = "notch"
        return d
    }

    func testALinkedResumeRaisesACardInsteadOfLaunching() {
        let d = delegate()
        d.confirmScriptedResume(project: "notch")

        XCTAssertEqual(d.state.permissionQueue.count, 1)
        let card = d.state.permissionQueue.first
        XCTAssertEqual(card?.kind, .toolUse)
        XCTAssertEqual(card?.toolName, "Resume")
        XCTAssertTrue(card?.detail.contains("notch") ?? false)
    }

    /// Dangerous is not a claim about the session. It is what stops an
    /// always-allow rule or auto-approve mode from answering a card whose whole
    /// purpose is that a person answers it.
    func testTheCardCannotBeAutoApproved() {
        let d = delegate()
        d.state.setAutoApprove(true)
        d.confirmScriptedResume(project: "notch")

        XCTAssertEqual(d.state.permissionQueue.count, 1)
        XCTAssertTrue(d.state.permissionQueue.first?.isDangerous ?? false)
    }

    /// With no project named, the card still says what is about to happen
    /// rather than showing an empty phrase.
    func testTheCardReadsWithoutAProject() {
        let d = delegate()
        d.state.currentProject = ""
        d.confirmScriptedResume(project: nil)
        let detail = d.state.permissionQueue.first?.detail ?? ""
        XCTAssertFalse(detail.isEmpty)
        XCTAssertTrue(detail.contains("most recent session"))
    }

    /// The card names where the request came from, because that is the whole
    /// question: did you click something, or did a page.
    func testTheCardSaysItCameFromALink() {
        let d = delegate()
        d.confirmScriptedResume(project: "notch")
        XCTAssertEqual(d.state.permissionQueue.first?.source, "claudenotch:// link")
    }

    /// Everything else a link can do only opens a window this app already owns,
    /// so those stay immediate: the point is not to make the scheme annoying.
    func testTheOtherVerbsAreNotGated() {
        let d = delegate()
        d.run(.history, from: .url)
        d.run(.settings, from: .url)
        d.run(.open, from: .url)
        XCTAssertTrue(d.state.permissionQueue.isEmpty)
    }

    /// Off means off: nothing a link asks for happens, not even a card.
    func testTheSchemeCanBeSwitchedOff() {
        let d = delegate()
        d.state.setURLSchemeEnabled(false)
        d.application(NSApplication.shared, open: [URL(string: "claudenotch://resume/notch")!])
        XCTAssertTrue(d.state.permissionQueue.isEmpty)

        d.state.setURLSchemeEnabled(true)
        d.application(NSApplication.shared, open: [URL(string: "claudenotch://resume/notch")!])
        XCTAssertEqual(d.state.permissionQueue.count, 1)
    }

    func testTheSchemeIsOnByDefault() {
        XCTAssertTrue(AppState().urlSchemeEnabled)
    }

    /// The parser still rejects a path dressed as a project name, which is the
    /// other half of this: a link cannot choose the directory either.
    func testAProjectNameIsStillAName() {
        XCTAssertNil(NotchURL.parse(URL(string: "claudenotch://resume/../../etc")!))
        XCTAssertNil(NotchURL.parse(URL(string: "claudenotch://resume/~root")!))
        XCTAssertEqual(NotchURL.parse(URL(string: "claudenotch://resume/notch")!),
                       .resume(project: "notch"))
    }
}
