import XCTest
@testable import ClaudeNotch

/// Worktrees are how people run several agents without them colliding, and the
/// cost is losing track of which checkout is which. The two payloads are not
/// symmetric, which is the detail most likely to be got wrong.
final class WorktreeTests: XCTestCase {

    // MARK: - The label

    func testANameIsUsedAsGiven() {
        XCTAssertEqual(Worktree.label(name: "oauth-migration"), "oauth-migration")
    }

    /// A path shows its last component. The parent is a long shared prefix
    /// that says nothing about which worktree this is.
    func testAPathShowsItsLastComponent() {
        XCTAssertEqual(Worktree.label(path: "/Users/x/code/wt/oauth-migration"), "oauth-migration")
    }

    /// WorktreeCreate sends a name and WorktreeRemove sends a path, so both
    /// have to work through one function.
    func testANamePreferredOverAPath() {
        XCTAssertEqual(Worktree.label(name: "chosen", path: "/tmp/other"), "chosen")
    }

    func testNothingIsEmpty() {
        XCTAssertEqual(Worktree.label(), "")
        XCTAssertEqual(Worktree.label(name: "  ", path: ""), "")
    }

    func testItIsSanitizedAndBounded() {
        XCTAssertEqual(Worktree.label(name: "oauth\nmigration"), "oauthmigration")
        let long = Worktree.label(name: String(repeating: "w", count: 400))
        XCTAssertLessThanOrEqual(long.count, Worktree.labelLimit)
    }

    // MARK: - What it says

    func testTheCardsNameTheWorktree() {
        XCTAssertTrue(Worktree.createdTitle(label: "oauth").contains("oauth"))
        XCTAssertTrue(Worktree.removedTitle(label: "oauth").contains("oauth"))
        XCTAssertFalse(Worktree.createdTitle(label: "").isEmpty)
        XCTAssertFalse(Worktree.removedTitle(label: "").isEmpty)
    }

    /// The honest caveat about worktrees, which every account of them mentions
    /// only after somebody has hit it.
    func testTheDetailSaysWhatIsNotIsolated() {
        let detail = Worktree.createdDetail().lowercased()
        XCTAssertTrue(detail.contains("port"), detail)
    }

    // MARK: - On a session

    @MainActor
    func testACreatedWorktreeRaisesACard() {
        let s = AppState()
        s.noteWorktreeCreated(name: "oauth-migration", sessionId: "s1", cwd: "/tmp/proj")
        let cards = s.permissionQueue.filter { $0.toolName == "Worktree" }
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards[0].title.contains("oauth-migration"), cards[0].title)
    }

    /// Removal is logged, not carded. It happens right after the work in it was
    /// merged, which is the least welcome moment for an interruption, and there
    /// is nothing to act on.
    @MainActor
    func testARemovedWorktreeIsLoggedRatherThanCarded() {
        let s = AppState()
        s.noteWorktreeRemoved(path: "/Users/x/wt/oauth-migration", sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertTrue(s.permissionQueue.isEmpty, "removal must not interrupt")
        XCTAssertTrue(s.history.contains { $0.toolName == "Worktree" },
                      "but it must still be findable later")
    }
}
