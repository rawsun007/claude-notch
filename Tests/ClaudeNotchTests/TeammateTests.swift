import XCTest
@testable import ClaudeNotch

/// Teammates sit in panes of their own, and a pane does not report that its
/// agent has stopped. The name in the card comes off a hook payload, so it is
/// untrusted text on the way to a title.
final class TeammateTests: XCTestCase {

    // MARK: - The name

    func testAnOrdinaryNameSurvives() {
        XCTAssertEqual(Teammate.displayName("reviewer"), "reviewer")
        XCTAssertEqual(Teammate.displayName("  api-migration  "), "api-migration")
    }

    func testAMissingNameIsEmpty() {
        XCTAssertEqual(Teammate.displayName(""), "")
        XCTAssertEqual(Teammate.displayName("   \n "), "")
    }

    /// A newline in a card title breaks the layout, and no real name has one.
    func testControlCharactersAreStripped() {
        XCTAssertEqual(Teammate.displayName("rev\niewer"), "reviewer")
        XCTAssertEqual(Teammate.displayName("rev\u{0}iewer"), "reviewer")
        XCTAssertEqual(Teammate.displayName("a\tb"), "ab")
    }

    /// Payload-supplied, so it cannot become the whole notch.
    func testALongNameIsBounded() {
        let name = Teammate.displayName(String(repeating: "n", count: 500))
        XCTAssertLessThanOrEqual(name.count, Teammate.nameLimit)
        XCTAssertFalse(name.isEmpty)
    }

    // MARK: - What it says

    func testTheCardNamesTheTeammate() {
        XCTAssertTrue(Teammate.cardTitle(name: "reviewer").contains("reviewer"))
    }

    /// An unnamed teammate still produces a sentence rather than a gap.
    func testAnUnnamedTeammateStillReads() {
        let title = Teammate.cardTitle(name: "")
        XCTAssertFalse(title.isEmpty)
        XCTAssertTrue(title.lowercased().contains("teammate"), title)
    }

    func testTheDetailNamesTheProjectWhenThereIsOne() {
        XCTAssertTrue(Teammate.cardDetail(project: "notch").contains("notch"))
        XCTAssertFalse(Teammate.cardDetail(project: "").isEmpty)
    }

    // MARK: - On a session

    @MainActor
    private func teammateCards(_ s: AppState) -> [PermissionRequest] {
        s.permissionQueue.filter { $0.toolName == "Teammate" }
    }

    @MainActor
    func testAnIdleTeammateRaisesACard() {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        s.noteTeammateIdle(name: "reviewer", sessionId: "s1", cwd: "/tmp/proj")
        let cards = teammateCards(s)
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards[0].title.contains("reviewer"), cards[0].title)
        XCTAssertTrue(cards[0].detail.contains("proj"), cards[0].detail)
    }

    /// Every idle is news, unlike the advice cards which say their piece once.
    /// A teammate finishing twice is two things worth knowing.
    @MainActor
    func testEachIdleIsItsOwnCard() {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        s.noteTeammateIdle(name: "reviewer", sessionId: "s1", cwd: "/tmp/proj")
        s.noteTeammateIdle(name: "reviewer", sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertEqual(teammateCards(s).count, 2)
    }

    /// A teammate on a session the app never saw is still worth showing: the
    /// point is that somebody is waiting, not that we have their session.
    @MainActor
    func testAnUnknownSessionStillRaisesTheCard() {
        let s = AppState()
        s.noteTeammateIdle(name: "builder", sessionId: "ghost", cwd: "/tmp/elsewhere")
        XCTAssertEqual(teammateCards(s).count, 1)
    }

    @MainActor
    func testAHostileNameCannotBreakTheCard() {
        let s = AppState()
        s.noteTeammateIdle(name: "evil\nName\u{0}", sessionId: "s1", cwd: "/tmp/proj")
        let title = teammateCards(s).first?.title ?? ""
        XCTAssertFalse(title.contains("\n"), title)
        XCTAssertFalse(title.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
    }
}
