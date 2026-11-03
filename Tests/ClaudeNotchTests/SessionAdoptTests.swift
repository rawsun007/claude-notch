import XCTest
@testable import ClaudeNotch

/// Folding Claude Code's session registry into the notch's list. The bug this
/// guards: the same session listed more than once.
final class SessionAdoptTests: XCTestCase {

    private func entry(pid: Int32, id: String, cwd: String = "/w/bench-16") -> SessionRegistry.Entry {
        SessionRegistry.Entry(pid: pid, sessionId: id, cwd: cwd, version: "2.1.317",
                              kind: "interactive", status: "idle", name: "",
                              updatedAt: Date())
    }

    @MainActor
    func testAdoptingTheSameEntryTwiceIsOneRow() {
        let s = AppState()
        s.adopt(entry(pid: 4242, id: "a"))
        s.adopt(entry(pid: 4242, id: "a"))
        XCTAssertEqual(s.sessions.count, 1)
    }

    /// A resume or clear in place gives the same process a new session id.
    /// The old row goes; it does not stay next to the new one.
    @MainActor
    func testAProcessWithANewSessionIdReplacesItsOldRow() {
        let s = AppState()
        s.adopt(entry(pid: 4242, id: "old"))
        s.adopt(entry(pid: 4242, id: "new"))
        XCTAssertEqual(Array(s.sessions.keys), ["new"])
    }

    /// Two processes in one project are two sessions, and stay that way.
    @MainActor
    func testTwoProcessesInOneProjectAreTwoRows() {
        let s = AppState()
        s.adopt(entry(pid: 4242, id: "a"))
        s.adopt(entry(pid: 4343, id: "b"))
        XCTAssertEqual(Set(s.sessions.keys), ["a", "b"])
    }

    /// A session a hook filed under its cwd (no session id) is the same
    /// session the registry then names: still one row.
    @MainActor
    func testACwdKeyedSessionAbsorbsItsRegistryEntry() {
        let s = AppState()
        s.upsertSession(id: "", cwd: "/w/bench-16", create: true) { _ in }
        s.adopt(entry(pid: 4242, id: "a"))
        XCTAssertEqual(Array(s.sessions.keys), ["/w/bench-16"])
    }
}
