import XCTest
@testable import ClaudeNotch

/// Two sessions in one checkout edit the same files underneath each other, and
/// neither reports an error when it happens. The advice is only useful if it
/// fires on that and stays quiet on everything else.
final class WorktreeAdviceTests: XCTestCase {

    func testTwoSessionsInOneDirectoryCollide() {
        XCTAssertEqual(
            WorktreeAdvice.collidingDirectories([("/p", ""), ("/p", "")]),
            ["/p"])
    }

    func testOneSessionIsNotACollision() {
        XCTAssertTrue(WorktreeAdvice.collidingDirectories([("/p", "")]).isEmpty)
    }

    func testDifferentDirectoriesDoNotCollide() {
        XCTAssertTrue(WorktreeAdvice.collidingDirectories([("/a", ""), ("/b", "")]).isEmpty)
    }

    /// The case that must stay silent: somebody already took this advice.
    func testSessionsInWorktreesAreExcluded() {
        XCTAssertTrue(WorktreeAdvice.collidingDirectories(
            [("/p", "feature-a"), ("/p", "feature-b")]).isEmpty)
        // Even one of them being in a worktree leaves a single plain session.
        XCTAssertTrue(WorktreeAdvice.collidingDirectories(
            [("/p", ""), ("/p", "feature-a")]).isEmpty)
    }

    /// Unknown is not a collision.
    func testBlankDirectoriesAreIgnored() {
        XCTAssertTrue(WorktreeAdvice.collidingDirectories([("", ""), ("", "")]).isEmpty)
        XCTAssertTrue(WorktreeAdvice.collidingDirectories([("  ", ""), ("  ", "")]).isEmpty)
    }

    func testSeveralCollisionsComeBackSorted() {
        XCTAssertEqual(
            WorktreeAdvice.collidingDirectories(
                [("/z", ""), ("/z", ""), ("/a", ""), ("/a", ""), ("/solo", "")]),
            ["/a", "/z"])
    }

    /// The honest limit belongs on the card: people who find out about ports by
    /// running two dev servers stop trusting the advice.
    func testTheCardNamesWhatAWorktreeDoesNotSeparate() {
        let detail = WorktreeAdvice.cardDetail().lowercased()
        XCTAssertTrue(detail.contains("port"), detail)
        XCTAssertTrue(WorktreeAdvice.cardTitle(project: "notch").contains("notch"))
    }

    // MARK: - On live sessions

    @MainActor
    private func cards(_ s: AppState) -> Int {
        s.permissionQueue.filter { $0.toolName == "Worktree" }.count
    }

    @MainActor
    func testACollisionIsAnnouncedOncePerDirectory() {
        let s = AppState()
        s.upsertSession(id: "a", cwd: "/p", create: true) { _ in }
        s.upsertSession(id: "b", cwd: "/p", create: true) { _ in }
        s.adviseWorktreeIfNeeded()
        s.adviseWorktreeIfNeeded()
        XCTAssertEqual(cards(s), 1)
    }

    @MainActor
    func testOneSessionSaysNothing() {
        let s = AppState()
        s.upsertSession(id: "a", cwd: "/p", create: true) { _ in }
        s.adviseWorktreeIfNeeded()
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }

    @MainActor
    func testSessionsInWorktreesSayNothing() {
        let s = AppState()
        s.upsertSession(id: "a", cwd: "/p", create: true) { $0.worktree = "feature-a" }
        s.upsertSession(id: "b", cwd: "/p", create: true) { $0.worktree = "feature-b" }
        s.adviseWorktreeIfNeeded()
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }

    @MainActor
    func testTheNudgeSettingSilencesIt() {
        let s = AppState()
        s.setCompactAdviceEnabled(false)
        s.upsertSession(id: "a", cwd: "/p", create: true) { _ in }
        s.upsertSession(id: "b", cwd: "/p", create: true) { _ in }
        s.adviseWorktreeIfNeeded()
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }
}
