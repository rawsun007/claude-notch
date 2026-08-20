import XCTest
@testable import ClaudeNotch

/// What is shaping an agent is as much a part of "what may this thing do" as
/// its permissions are. Instruction files scroll past at startup and are pulled
/// in mid-session by globs, and nothing showed either.
final class InstructionsLoadedTests: XCTestCase {

    @MainActor
    private func state() -> AppState {
        let s = AppState()
        s.currentCwd = "/tmp/proj"
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        return s
    }

    @MainActor
    func testAFileIsRecorded() {
        let s = state()
        s.noteInstructionsLoaded(path: "/tmp/proj/CLAUDE.md", memoryType: "project",
                                 sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertEqual(s.sessions["s1"]?.instructionFiles, ["/tmp/proj/CLAUDE.md"])
    }

    /// The same file loading twice is one file. Claude Code re-reads them.
    @MainActor
    func testTheSameFileIsNotListedTwice() {
        let s = state()
        for _ in 0..<5 {
            s.noteInstructionsLoaded(path: "/tmp/proj/CLAUDE.md", sessionId: "s1", cwd: "/tmp/proj")
        }
        XCTAssertEqual(s.sessions["s1"]?.instructionFiles.count, 1)
    }

    /// Order is load order, because a file pulled in later is the interesting
    /// one: by then nobody is watching the startup output.
    @MainActor
    func testOrderIsLoadOrder() {
        let s = state()
        for p in ["/a/CLAUDE.md", "/b/CLAUDE.md", "/c/AGENTS.md"] {
            s.noteInstructionsLoaded(path: p, sessionId: "s1", cwd: "/tmp/proj")
        }
        XCTAssertEqual(s.sessions["s1"]?.instructionFiles,
                       ["/a/CLAUDE.md", "/b/CLAUDE.md", "/c/AGENTS.md"])
    }

    /// The paths arrive on a hook payload, so the list is capped like every
    /// other payload-fed collection in this app.
    @MainActor
    func testTheListIsCapped() {
        let s = state()
        for i in 0..<(AppState.instructionFilesMax + 20) {
            s.noteInstructionsLoaded(path: "/f/\(i)/CLAUDE.md", sessionId: "s1", cwd: "/tmp/proj")
        }
        XCTAssertEqual(s.sessions["s1"]?.instructionFiles.count, AppState.instructionFilesMax)
        // The newest survive: a glob gone wide should not hide the file that
        // just arrived.
        XCTAssertTrue(s.sessions["s1"]?.instructionFiles.last?.contains("\(AppState.instructionFilesMax + 19)") ?? false)
    }

    @MainActor
    func testAnEmptyPathIsIgnored() {
        let s = state()
        s.noteInstructionsLoaded(path: "", sessionId: "s1", cwd: "/tmp/proj")
        s.noteInstructionsLoaded(path: "   \n", sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertTrue(s.sessions["s1"]?.instructionFiles.isEmpty ?? false)
    }

    /// A hook with no session id is filed under its directory, like every other
    /// hook that arrives that way.
    @MainActor
    func testASessionKeyedByCwdWorks() {
        let s = AppState()
        s.currentCwd = "/tmp/proj"
        s.noteInstructionsLoaded(path: "/tmp/proj/CLAUDE.md", cwd: "/tmp/proj")
        XCTAssertEqual(s.sessions["/tmp/proj"]?.instructionFiles.count, 1)
    }

    @MainActor
    func testTheHeaderReadsTheCurrentSession() {
        let s = state()
        s.currentSessionId = "s1"
        s.noteInstructionsLoaded(path: "/tmp/proj/CLAUDE.md", sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertEqual(s.currentInstructionFiles, ["/tmp/proj/CLAUDE.md"])
    }

    func testTheHookIsInstalled() {
        var hooks: [String: Any] = [:]
        HookInstaller.appendHook(to: "InstructionsLoaded", in: &hooks, matcher: ".*")
        XCTAssertNotNil(hooks["InstructionsLoaded"])
    }
}
