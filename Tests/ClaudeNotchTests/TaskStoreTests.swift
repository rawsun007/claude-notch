import XCTest
@testable import ClaudeNotch

/// The hooks describe what happened while this app was listening. The task
/// directory describes what is true, which is what a resumed session needs.
final class TaskStoreTests: XCTestCase {

    private var root = ""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-tasks-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    private func write(_ session: String, _ n: Int, _ json: String) throws {
        let dir = (root as NSString).appendingPathComponent(session)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try json.write(toFile: (dir as NSString).appendingPathComponent("\(n).json"),
                       atomically: true, encoding: .utf8)
    }

    /// The real shape, taken off this machine.
    func testTheRealShapeIsRead() throws {
        try write("s1", 29, #"{"id":"29","subject":"Fix spend cap parsing","description":"...","status":"completed","blocks":[],"blockedBy":[]}"#)
        try write("s1", 30, #"{"id":"30","subject":"Add DirectoryAdded hook support","description":"...","status":"pending","blocks":[],"blockedBy":[]}"#)

        let tasks = TaskStore.tasks(sessionId: "s1", directory: root)
        XCTAssertEqual(tasks.map(\.id), ["29", "30"])
        XCTAssertEqual(tasks[0].subject, "Fix spend cap parsing")
        XCTAssertTrue(tasks[0].isDone)
        XCTAssertFalse(tasks[1].isDone)

        let (done, total) = TaskStore.progress(tasks)
        XCTAssertEqual(done, 1)
        XCTAssertEqual(total, 2)
    }

    /// File order is creation order, and "10.json" comes after "9.json", which
    /// a plain string sort gets backwards.
    func testFilesAreOrderedNumerically() throws {
        for n in [1, 2, 9, 10, 11] {
            try write("s1", n, #"{"id":"\#(n)","subject":"t\#(n)","status":"pending","blockedBy":[]}"#)
        }
        XCTAssertEqual(TaskStore.tasks(sessionId: "s1", directory: root).map(\.id),
                       ["1", "2", "9", "10", "11"])
    }

    /// A task waiting on another is queued, not stalled.
    func testBlockedTasksAreIdentified() throws {
        try write("s1", 1, #"{"id":"1","subject":"first","status":"completed","blockedBy":[]}"#)
        try write("s1", 2, #"{"id":"2","subject":"second","status":"pending","blockedBy":["1"]}"#)
        let tasks = TaskStore.tasks(sessionId: "s1", directory: root)
        XCTAssertFalse(tasks[0].isBlocked)
        XCTAssertTrue(tasks[1].isBlocked)
    }

    /// A completed task is not blocked, whatever its edges say.
    func testACompletedTaskIsNotBlocked() throws {
        try write("s1", 1, #"{"id":"1","subject":"x","status":"completed","blockedBy":["9"]}"#)
        XCTAssertFalse(TaskStore.tasks(sessionId: "s1", directory: root)[0].isBlocked)
    }

    func testJunkFilesAndBadJSONAreSkipped() throws {
        try write("s1", 1, #"{"id":"1","subject":"good","status":"pending","blockedBy":[]}"#)
        try write("s1", 2, "{ not json")
        try write("s1", 3, #"{"subject":"no id","status":"pending"}"#)
        let dir = (root as NSString).appendingPathComponent("s1")
        try "".write(toFile: (dir as NSString).appendingPathComponent(".lock"),
                     atomically: true, encoding: .utf8)
        try "".write(toFile: (dir as NSString).appendingPathComponent("notes.txt"),
                     atomically: true, encoding: .utf8)

        XCTAssertEqual(TaskStore.tasks(sessionId: "s1", directory: root).map(\.id), ["1"])
    }

    func testAMissingSessionIsEmptyNotAnError() {
        XCTAssertTrue(TaskStore.tasks(sessionId: "nope", directory: root).isEmpty)
        XCTAssertTrue(TaskStore.tasks(sessionId: "", directory: root).isEmpty)
        XCTAssertTrue(TaskStore.tasks(sessionId: "s1", directory: "/nonexistent").isEmpty)
    }

    func testSessionsWithTasksAreListedNewestFirst() throws {
        try write("older", 1, #"{"id":"1","subject":"a","status":"pending","blockedBy":[]}"#)
        try write("newer", 1, #"{"id":"1","subject":"b","status":"pending","blockedBy":[]}"#)
        let dir = (root as NSString).appendingPathComponent("newer")
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dir)
        let older = (root as NSString).appendingPathComponent("older")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                                              ofItemAtPath: older)

        XCTAssertEqual(TaskStore.sessionsWithTasks(directory: root).first, "newer")
    }

    // MARK: - What the meter shows

    /// Disk wins, because it survives a restart and cannot count a task that
    /// was deleted.
    @MainActor
    func testTheDiskNumbersWinOverTheHookNumbers() {
        var session = LiveSession(id: "s1", cwd: "/tmp/p", project: "p", status: "ready",
                                  activity: "", lastResponse: "", fullResponse: "",
                                  lastHookAt: Date(), createdAt: Date())
        session.todoTotal = 9
        session.todoDone = 1
        XCTAssertEqual(session.taskTotal, 9)

        session.storeTaskTotal = 4
        session.storeTaskDone = 3
        XCTAssertEqual(session.taskTotal, 4)
        XCTAssertEqual(session.taskDone, 3)
    }

    /// With nothing on disk the hook numbers still drive the meter, so a session
    /// whose directory has not been written yet is unaffected.
    @MainActor
    func testTheHookNumbersRemainTheFallback() {
        var session = LiveSession(id: "s1", cwd: "/tmp/p", project: "p", status: "ready",
                                  activity: "", lastResponse: "", fullResponse: "",
                                  lastHookAt: Date(), createdAt: Date())
        session.createdTaskIds = ["a", "b"]
        session.completedTaskIds = ["a"]
        XCTAssertEqual(session.taskTotal, 2)
        XCTAssertEqual(session.taskDone, 1)
    }
}
