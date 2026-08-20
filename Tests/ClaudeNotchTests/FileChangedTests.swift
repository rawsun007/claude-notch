import XCTest
@testable import ClaudeNotch

/// A file changing while an agent works is only interesting when the agent did
/// not change it. Its own edits already arrive as PostToolUse, and repeating
/// them would turn a signal into a commentary on the session's own work.
final class FileChangedTests: XCTestCase {

    @MainActor
    private func state() -> AppState {
        let s = AppState()
        s.currentCwd = "/tmp/proj"
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        return s
    }

    @MainActor
    func testAnOutsideChangeIsRecorded() {
        let s = state()
        s.noteFileChangedOutsideTheAgent(path: "/tmp/proj/README.md", event: "modified",
                                         sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertEqual(s.sessions["s1"]?.externallyChangedFiles, ["/tmp/proj/README.md"])
    }

    /// The agent's own edit is not an outside change. This is the whole point.
    @MainActor
    func testTheAgentsOwnEditIsIgnored() {
        let s = state()
        s.noteFileTouched("/tmp/proj/main.swift", sessionId: "s1", cwd: "/tmp/proj")
        s.noteFileChangedOutsideTheAgent(path: "/tmp/proj/main.swift", sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertTrue(s.sessions["s1"]?.externallyChangedFiles.isEmpty ?? false)
    }

    /// A file the agent has never touched still counts, even in a directory it
    /// is working in.
    @MainActor
    func testANeighbouringFileStillCounts() {
        let s = state()
        s.noteFileTouched("/tmp/proj/main.swift", sessionId: "s1", cwd: "/tmp/proj")
        s.noteFileChangedOutsideTheAgent(path: "/tmp/proj/other.swift", sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertEqual(s.sessions["s1"]?.externallyChangedFiles, ["/tmp/proj/other.swift"])
    }

    @MainActor
    func testTheSameFileIsCountedOnce() {
        let s = state()
        for _ in 0..<6 {
            s.noteFileChangedOutsideTheAgent(path: "/tmp/proj/a.txt", sessionId: "s1", cwd: "/tmp/proj")
        }
        XCTAssertEqual(s.sessions["s1"]?.externallyChangedFiles.count, 1)
    }

    /// A build touching a thousand files must not grow this without bound.
    @MainActor
    func testTheListIsCapped() {
        let s = state()
        for i in 0..<(AppState.externalChangesMax + 30) {
            s.noteFileChangedOutsideTheAgent(path: "/tmp/proj/f\(i).o", sessionId: "s1", cwd: "/tmp/proj")
        }
        XCTAssertEqual(s.sessions["s1"]?.externallyChangedFiles.count, AppState.externalChangesMax)
    }

    @MainActor
    func testAnEmptyPathIsIgnored() {
        let s = state()
        s.noteFileChangedOutsideTheAgent(path: "", sessionId: "s1", cwd: "/tmp/proj")
        s.noteFileChangedOutsideTheAgent(path: "  ", sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertTrue(s.sessions["s1"]?.externallyChangedFiles.isEmpty ?? false)
    }

    /// Nothing is announced. A card per file would be a commentary on an
    /// ordinary build; the count is what is worth looking at.
    @MainActor
    func testNothingIsAnnounced() {
        let s = state()
        s.noteFileChangedOutsideTheAgent(path: "/tmp/proj/a.txt", sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertTrue(s.permissionQueue.isEmpty)
        XCTAssertTrue(s.history.isEmpty)
    }

    func testTheHookIsInstalled() {
        var hooks: [String: Any] = [:]
        HookInstaller.appendHook(to: "FileChanged", in: &hooks, matcher: ".*")
        XCTAssertNotNil(hooks["FileChanged"])
    }
}
