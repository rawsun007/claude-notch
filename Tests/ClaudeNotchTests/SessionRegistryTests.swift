import XCTest
@testable import ClaudeNotch

/// Claude Code writes one file per running session to ~/.claude/sessions. The
/// notch reads it to see sessions that never fired a hook at it, and to know a
/// session is gone rather than merely quiet.
///
/// Both directions are dangerous if wrong: a bad parse invents sessions that
/// are not running, and a bad liveness rule deletes rows for sessions that
/// are. Everything here is the pure half, so both can be pinned exactly.
final class SessionRegistryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ name: String, _ json: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A real file, as Claude Code 2.1.227 writes it.
    private let realEntry = """
    {
      "pid": 23606,
      "sessionId": "e6a75f9b-04fb-4b97-9438-6a35dbf718ad",
      "cwd": "/Users/me/project",
      "startedAt": 1786588831795,
      "procStart": "Thu Aug 13 02:40:30 2026",
      "version": "2.1.227",
      "peerProtocol": 1,
      "kind": "interactive",
      "entrypoint": "cli",
      "messagingSocketPath": "/tmp/cc-socks/23606.sock",
      "name": "claude-mac-app-cc",
      "nameSource": "derived",
      "status": "busy",
      "updatedAt": 1786678060737,
      "statusUpdatedAt": 1786678060737
    }
    """

    // MARK: - Parsing

    func testARealEntryParses() throws {
        let e = try XCTUnwrap(SessionRegistry.parse(Data(realEntry.utf8)))
        XCTAssertEqual(e.pid, 23606)
        XCTAssertEqual(e.sessionId, "e6a75f9b-04fb-4b97-9438-6a35dbf718ad")
        XCTAssertEqual(e.cwd, "/Users/me/project")
        XCTAssertEqual(e.version, "2.1.227")
        XCTAssertEqual(e.kind, "interactive")
        XCTAssertEqual(e.name, "claude-mac-app-cc")
        XCTAssertTrue(e.isBusy)
        XCTAssertEqual(e.updatedAt?.timeIntervalSince1970 ?? 0, 1786678060.737, accuracy: 0.01)
    }

    /// An entry with no pid or no session id cannot be matched to anything and
    /// cannot be checked for liveness, so it is not a session — it is noise.
    func testEntriesThatCannotBeIdentifiedAreRejected() {
        XCTAssertNil(SessionRegistry.parse(Data(#"{"sessionId": "abc"}"#.utf8)))
        XCTAssertNil(SessionRegistry.parse(Data(#"{"pid": 1234}"#.utf8)))
        XCTAssertNil(SessionRegistry.parse(Data(#"{"pid": 0, "sessionId": "abc"}"#.utf8)))
        XCTAssertNil(SessionRegistry.parse(Data("not json".utf8)))
    }

    func testMissingOptionalFieldsAreEmptyNotFatal() throws {
        let e = try XCTUnwrap(SessionRegistry.parse(Data(#"{"pid": 42, "sessionId": "s1"}"#.utf8)))
        XCTAssertEqual(e.version, "")
        XCTAssertEqual(e.name, "")
        XCTAssertEqual(e.status, "")
        XCTAssertNil(e.updatedAt)
        XCTAssertFalse(e.isBusy)
    }

    func testTrailingSlashesAreStrippedFromCwd() throws {
        let e = try XCTUnwrap(SessionRegistry.parse(Data(#"{"pid": 42, "sessionId": "s1", "cwd": "/a/b/"}"#.utf8)))
        // The session list keys cwd-only sessions by this string; "/a/b/" and
        // "/a/b" would be two rows for one directory.
        XCTAssertEqual(e.cwd, "/a/b")
    }

    // MARK: - Liveness

    func testAnEntryWhoseProcessIsGoneIsNotCurrent() throws {
        let e = try XCTUnwrap(SessionRegistry.parse(Data(realEntry.utf8)))
        XCTAssertFalse(SessionRegistry.isCurrent(e, alive: { _ in false }))
        XCTAssertTrue(SessionRegistry.isCurrent(e, now: Date(timeIntervalSince1970: 1786678070),
                                                alive: { _ in true }))
    }

    /// Pids are reused. A file whose process is alive but which has not been
    /// touched in a day is far more likely to be a crash leftover sitting on a
    /// recycled pid than a session idle since yesterday.
    func testAVeryOldEntryIsNotCurrentEvenIfThePidExists() throws {
        let e = try XCTUnwrap(SessionRegistry.parse(Data(realEntry.utf8)))
        let muchLater = Date(timeIntervalSince1970: 1786678060 + SessionRegistry.maxAge + 60)
        XCTAssertFalse(SessionRegistry.isCurrent(e, now: muchLater, alive: { _ in true }))
    }

    /// No timestamp at all is not evidence of staleness.
    func testAnEntryWithNoTimestampRidesOnItsPid() throws {
        let e = try XCTUnwrap(SessionRegistry.parse(Data(#"{"pid": 42, "sessionId": "s1"}"#.utf8)))
        XCTAssertTrue(SessionRegistry.isCurrent(e, alive: { _ in true }))
        XCTAssertFalse(SessionRegistry.isCurrent(e, alive: { _ in false }))
    }

    /// The one liveness fact the app does not have to guess at.
    func testOurOwnProcessIsAliveAndAnImpossibleOneIsNot() {
        XCTAssertTrue(SessionRegistry.processExists(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(SessionRegistry.processExists(-1))
        XCTAssertFalse(SessionRegistry.processExists(0))
    }

    // MARK: - Reading the directory

    func testReadSkipsNonSessionFilesAndDeadEntries() throws {
        let alivePid = ProcessInfo.processInfo.processIdentifier
        try write("\(alivePid).json", """
        {"pid": \(alivePid), "sessionId": "live", "cwd": "/a", "status": "idle",
         "updatedAt": \(Int(Date().timeIntervalSince1970 * 1000))}
        """)
        // A pid that cannot exist: gone, whatever the file says.
        try write("999999.json", #"{"pid": 999999, "sessionId": "dead", "cwd": "/b"}"#)
        // The directory also holds key files and whatever a future release adds.
        try write("23929.key", "not json at all")
        try write("notes.txt", "ignore me")

        let entries = SessionRegistry.read(directory: root.path)
        XCTAssertEqual(entries.map(\.sessionId), ["live"])
    }

    func testAnEmptyOrMissingDirectoryIsNotAnError() {
        XCTAssertTrue(SessionRegistry.read(directory: root.path).isEmpty)
        XCTAssertTrue(SessionRegistry.read(directory: "/nope/not/here").isEmpty)
    }

    func testEntriesComeBackNewestFirst() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let now = Int(Date().timeIntervalSince1970 * 1000)
        try write("1.json", #"{"pid": \#(pid), "sessionId": "older", "updatedAt": \#(now - 5000)}"#)
        try write("2.json", #"{"pid": \#(pid), "sessionId": "newer", "updatedAt": \#(now)}"#)
        XCTAssertEqual(SessionRegistry.read(directory: root.path).map(\.sessionId),
                       ["newer", "older"])
    }

    // MARK: - Status vocabulary

    /// Golden: the registry's words in the notch's own.
    func testGoldenStatusMapping() {
        let cases = [("busy", "thinking"), ("idle", "ready"), ("", "ready"),
                     ("something_new", "something_new")]
        for (raw, expected) in cases {
            XCTAssertEqual(SessionRegistry.statusLabel(raw), expected, raw)
        }
    }
}
