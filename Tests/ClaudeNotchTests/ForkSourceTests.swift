import XCTest
@testable import ClaudeNotch

/// A fork and a resume look identical in the list, and they are not the same
/// thing: a fork is a second copy of a conversation you are still in.
final class ForkSourceTests: XCTestCase {

    @MainActor
    private func started(source: String, version: String = "2.1.229") -> LiveSession {
        let s = AppState()
        s.currentCwd = "/tmp/proj"
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { $0.cliVersion = version }
        s.noteSessionStart(sessionId: "s1", cwd: "/tmp/proj",
                           model: "claude-opus-4-8", title: "", source: source)
        return s.sessions["s1"]!
    }

    @MainActor
    func testTheSourceIsRecorded() {
        XCTAssertEqual(started(source: "fork").startSource, "fork")
        XCTAssertEqual(started(source: "resume").startSource, "resume")
        XCTAssertEqual(started(source: "startup").startSource, "startup")
    }

    /// SessionStart fires once. A later hook that carries no source must not
    /// erase what it said.
    @MainActor
    func testAnEmptySourceDoesNotEraseTheRecordedOne() {
        let s = AppState()
        s.currentCwd = "/tmp/proj"
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        s.noteSessionStart(sessionId: "s1", cwd: "/tmp/proj", model: "", title: "", source: "fork")
        s.noteSessionStart(sessionId: "s1", cwd: "/tmp/proj", model: "m", title: "t", source: "")
        XCTAssertEqual(s.sessions["s1"]?.startSource, "fork")
    }

    /// Before 2.1.214 a fork reported itself as a resume, so "resume" from an
    /// older build is not evidence of anything.
    @MainActor
    func testAnOlderBuildCannotTellAForkFromAResume() {
        XCTAssertFalse(started(source: "resume", version: "2.1.213").supports(.forkSource))
        XCTAssertTrue(started(source: "resume", version: "2.1.214").supports(.forkSource))
    }
}
