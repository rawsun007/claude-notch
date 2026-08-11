import XCTest
@testable import ClaudeNotch

/// `/add-dir` widens what a running session may touch, after you decided what
/// it could touch. The hook fires after the fact and cannot block it, so this
/// is a record rather than a gate — but a record that silently missed the path
/// would be worse than none.
final class DirectoryAddedTests: XCTestCase {

    /// The hook contract documents the common fields but does not pin down this
    /// event's own, so the path is read from whichever key carries it.
    func testReadsThePathFromAnyDocumentedKey() {
        for key in ["directory", "path", "added_directory", "dir",
                    "directory_path", "addedDirectory", "directoryPath"] {
            XCTAssertEqual(EventServer.addedDirectory(from: [key: "/tmp/extra"]),
                           "/tmp/extra", "key \(key) should be read")
        }
    }

    /// An empty result is the signal to log the payload rather than record a
    /// blank directory, so it must not be produced by a present-but-empty value.
    func testMissingOrEmptyPathReadsAsEmpty() {
        XCTAssertEqual(EventServer.addedDirectory(from: [:]), "")
        XCTAssertEqual(EventServer.addedDirectory(from: ["directory": ""]), "")
        XCTAssertEqual(EventServer.addedDirectory(from: ["directory": 42]), "")
        XCTAssertEqual(EventServer.addedDirectory(from: ["session_id": "abc"]), "")
    }

    /// The first key present wins, so a payload carrying both never records twice.
    func testFirstMatchingKeyWins() {
        let payload: [String: Any] = ["directory": "/a", "path": "/b"]
        XCTAssertEqual(EventServer.addedDirectory(from: payload), "/a")
    }

    @MainActor
    func testRecordsTheDirectoryAgainstTheSession() {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        s.noteDirectoryAdded(sessionId: "s1", cwd: "/tmp/proj", directory: "/tmp/extra")
        XCTAssertEqual(s.sessions["s1"]?.addedDirectories, ["/tmp/extra"])
    }

    /// Running /add-dir on a directory already added is an ordinary thing to do.
    @MainActor
    func testTheSameDirectoryIsNotRecordedTwice() {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        s.noteDirectoryAdded(sessionId: "s1", cwd: "/tmp/proj", directory: "/tmp/extra")
        s.noteDirectoryAdded(sessionId: "s1", cwd: "/tmp/proj", directory: "/tmp/extra")
        XCTAssertEqual(s.sessions["s1"]?.addedDirectories.count, 1)
    }

    /// The paths arrive on a hook payload, so the list is capped like every
    /// other payload-fed collection.
    @MainActor
    func testTheListIsCapped() {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        for i in 0...(AppState.addedDirectoriesMax + 5) {
            s.noteDirectoryAdded(sessionId: "s1", cwd: "/tmp/proj", directory: "/tmp/d\(i)")
        }
        XCTAssertEqual(s.sessions["s1"]?.addedDirectories.count, AppState.addedDirectoriesMax)
        // Oldest dropped, newest kept.
        XCTAssertFalse(s.sessions["s1"]?.addedDirectories.contains("/tmp/d0") ?? true)
    }

    /// A blank path records nothing rather than an empty row.
    @MainActor
    func testBlankDirectoryIsIgnored() {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        s.noteDirectoryAdded(sessionId: "s1", cwd: "/tmp/proj", directory: "   ")
        XCTAssertTrue(s.sessions["s1"]?.addedDirectories.isEmpty ?? false)
    }

    /// Two sessions in the same project can be granted different directories.
    @MainActor
    func testRecordedPerSessionNotGlobally() {
        let s = AppState()
        s.upsertSession(id: "a", cwd: "/tmp/proj", create: true) { _ in }
        s.upsertSession(id: "b", cwd: "/tmp/proj", create: true) { _ in }
        s.noteDirectoryAdded(sessionId: "a", cwd: "/tmp/proj", directory: "/tmp/only-a")
        XCTAssertEqual(s.sessions["a"]?.addedDirectories, ["/tmp/only-a"])
        XCTAssertTrue(s.sessions["b"]?.addedDirectories.isEmpty ?? false)
    }
}
