import XCTest
@testable import ClaudeNotch

/// `/add-dir` widens what a running session may touch, after you decided what
/// it could touch. The hook fires after the fact and cannot block it, so this
/// is a record rather than a gate — but a record that silently missed the path
/// would be worse than none.
final class DirectoryAddedTests: XCTestCase {

    /// The documented payload, verbatim from the hooks reference.
    func testReadsTheDocumentedPayload() {
        let payload: [String: Any] = [
            "session_id": "abc123",
            "cwd": "/home/user/my-project",
            "hook_event_name": "DirectoryAdded",
            "directory_path": "/home/user/another-project",
            "how_added": "slash_command",
        ]
        XCTAssertEqual(EventServer.addedDirectory(from: payload), "/home/user/another-project")
        XCTAssertEqual(EventServer.addedDirectoryHow(from: payload), "/add-dir")
    }

    /// The SDK grants directories too, and that is a different thing from
    /// someone typing /add-dir.
    func testTheSDKRepoRootIsDistinguished() {
        XCTAssertEqual(EventServer.addedDirectoryHow(from: ["how_added": "register_repo_root"]),
                       "SDK repo root")
        XCTAssertEqual(EventServer.addedDirectoryHow(from: [:]), "")
        // A value the CLI adds later is passed through rather than dropped.
        XCTAssertEqual(EventServer.addedDirectoryHow(from: ["how_added": "future_thing"]),
                       "future_thing")
    }

    /// The fallback keys stay because this arrives from a CLI that ships faster
    /// than its reference.
    func testReadsThePathFromAnyPlausibleKey() {
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

    /// The documented key wins over any fallback.
    func testTheDocumentedKeyWins() {
        let payload: [String: Any] = ["directory": "/a", "directory_path": "/b"]
        XCTAssertEqual(EventServer.addedDirectory(from: payload), "/b")
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

    /// The header draws the primary session, and for anyone running a single
    /// session the header is the ONLY place that session is ever drawn. The
    /// chip lived on the secondary-row list alone, so /add-dir showed nothing
    /// at all in the common case. Guards the data the header reads.
    @MainActor
    func testTheDirectoriesReachThePrimarySession() {
        let s = AppState()
        s.upsertSession(id: "only", cwd: "/tmp/proj", create: true) { _ in }
        s.noteDirectoryAdded(sessionId: "only", cwd: "/tmp/proj", directory: "/tmp/extra")
        XCTAssertEqual(s.primarySession?.id, "only", "one session is the primary one")
        XCTAssertEqual(s.primarySession?.addedDirectories, ["/tmp/extra"])
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
