import XCTest
@testable import ClaudeNotch

/// Claude runs `cd` and the session is somewhere else. Most of what the notch
/// shows self-heals, because every hook payload carries the cwd it fired in.
/// A session with no session_id does not: it is FILED UNDER its cwd, so the key
/// it lives at goes stale and the next hook opens a second row for the same
/// session.
final class CwdChangedTests: XCTestCase {

    @MainActor
    func testACwdKeyedSessionIsMovedRatherThanDuplicated() {
        let s = AppState()
        s.upsertSession(id: "", cwd: "/tmp/proj", create: true) { e in
            e.toolCallCount = 7
        }
        s.noteCwdChanged(sessionId: "", oldCwd: "/tmp/proj", newCwd: "/tmp/proj/backend")

        XCTAssertNil(s.sessions["/tmp/proj"], "the stale key must not linger")
        XCTAssertEqual(s.sessions.count, 1, "one cd must not become two sessions")
        let moved = s.sessions["/tmp/proj/backend"]
        XCTAssertEqual(moved?.id, "/tmp/proj/backend")
        XCTAssertEqual(moved?.cwd, "/tmp/proj/backend")
        XCTAssertEqual(moved?.project, "backend")
        XCTAssertEqual(moved?.toolCallCount, 7, "the session's history moves with it")
    }

    /// A session with a real session_id keeps its key; only its cwd changes.
    @MainActor
    func testAnIdKeyedSessionKeepsItsKey() {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        s.noteCwdChanged(sessionId: "s1", oldCwd: "/tmp/proj", newCwd: "/tmp/other")

        XCTAssertEqual(s.sessions.count, 1)
        XCTAssertEqual(s.sessions["s1"]?.cwd, "/tmp/other")
        XCTAssertEqual(s.sessions["s1"]?.project, "other")
    }

    /// The two spellings of one directory are one directory, so this is not a
    /// move at all.
    @MainActor
    func testATrailingSlashIsNotADirectoryChange() {
        let s = AppState()
        s.upsertSession(id: "", cwd: "/tmp/proj", create: true) { _ in }
        s.noteCwdChanged(sessionId: "", oldCwd: "/tmp/proj", newCwd: "/tmp/proj/")
        XCTAssertNotNil(s.sessions["/tmp/proj"])
        XCTAssertEqual(s.sessions.count, 1)
    }

    /// An empty destination is not somewhere to move to.
    @MainActor
    func testAnEmptyDestinationIsIgnored() {
        let s = AppState()
        s.upsertSession(id: "", cwd: "/tmp/proj", create: true) { _ in }
        s.noteCwdChanged(sessionId: "", oldCwd: "/tmp/proj", newCwd: "")
        XCTAssertNotNil(s.sessions["/tmp/proj"])
    }

    /// The header follows the session it was already tracking.
    @MainActor
    func testTheGlobalMirrorFollowsTheCurrentSession() {
        let s = AppState()
        s.currentSessionId = "s1"
        s.currentCwd = "/tmp/proj"
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        s.noteCwdChanged(sessionId: "s1", oldCwd: "/tmp/proj", newCwd: "/tmp/proj/backend")
        XCTAssertEqual(s.currentCwd, "/tmp/proj/backend")
        XCTAssertEqual(s.currentProject, "backend")
    }

    /// A cd in a background session must not drag the header off the session
    /// the user is actually watching.
    @MainActor
    func testAnotherSessionsCdDoesNotMoveTheHeader() {
        let s = AppState()
        s.currentSessionId = "watching"
        s.currentCwd = "/tmp/watching"
        s.upsertSession(id: "watching", cwd: "/tmp/watching", create: true) { _ in }
        s.upsertSession(id: "other", cwd: "/tmp/other", create: true) { _ in }
        s.noteCwdChanged(sessionId: "other", oldCwd: "/tmp/other", newCwd: "/tmp/elsewhere")
        XCTAssertEqual(s.currentCwd, "/tmp/watching")
    }

    /// Moving onto a directory another session already occupies must not
    /// silently delete that other session.
    @MainActor
    func testMovingOntoAnOccupiedKeyDoesNotDestroyTheOccupant() {
        let s = AppState()
        s.upsertSession(id: "", cwd: "/tmp/a", create: true) { e in e.toolCallCount = 1 }
        s.upsertSession(id: "", cwd: "/tmp/b", create: true) { e in e.toolCallCount = 2 }
        s.noteCwdChanged(sessionId: "", oldCwd: "/tmp/a", newCwd: "/tmp/b")
        XCTAssertEqual(s.sessions["/tmp/b"]?.toolCallCount, 2, "the occupant survives")
        XCTAssertEqual(s.sessions.count, 2)
    }

    /// cd into a different repo means a different branch, so the cached one
    /// must not survive the move.
    @MainActor
    func testTheBranchIsNotCarriedIntoTheNewDirectory() {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { e in
            e.gitBranch = "feature-x"
        }
        s.noteCwdChanged(sessionId: "s1", oldCwd: "/tmp/proj", newCwd: "/tmp/not-a-repo")
        XCTAssertEqual(s.sessions["s1"]?.gitBranch, "", "a stale branch is worse than none")
    }
}
