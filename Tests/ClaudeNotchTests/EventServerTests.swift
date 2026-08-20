import XCTest
@testable import ClaudeNotch

/// `parseRequest` turns raw bytes off the loopback socket into a request. It is
/// the app's untrusted-input boundary, so it must:
///   • never read past Content-Length,
///   • return nil (keep waiting) on an incomplete buffer rather than acting on a
///     half-read request,
///   • reject malformed/garbage input without crashing.
final class EventServerParseTests: XCTestCase {

    private func req(_ s: String) -> EventServer.HTTPRequest? {
        EventServer.parseRequest(Data(s.utf8))
    }

    func testValidPostWithJSONBody() {
        let r = req("POST /permission HTTP/1.1\r\nContent-Length: 13\r\n\r\n{\"a\":\"hello\"}")
        XCTAssertEqual(r?.method, "POST")
        XCTAssertEqual(r?.path, "/permission")
        XCTAssertEqual(r.map { String(decoding: $0.body, as: UTF8.self) }, "{\"a\":\"hello\"}")
    }

    func testGetWithNoBody() {
        let r = req("GET /ping HTTP/1.1\r\n\r\n")
        XCTAssertEqual(r?.method, "GET")
        XCTAssertEqual(r?.path, "/ping")
        XCTAssertEqual(r?.body.count, 0)
    }

    func testMissingHeaderTerminatorReturnsNil() {
        // No CRLFCRLF yet — caller must keep reading, not parse a partial request.
        XCTAssertNil(req("POST /x HTTP/1.1\r\nContent-Length: 5\r\n"))
    }

    func testBodyShorterThanContentLengthReturnsNil() {
        // Declared 50 bytes, only 5 arrived — wait for the rest.
        XCTAssertNil(req("POST /x HTTP/1.1\r\nContent-Length: 50\r\n\r\nshort"))
    }

    func testNeverReadsPastContentLength() {
        // Security: extra bytes after the declared length must be ignored, not
        // folded into the body.
        let r = req("POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\nhelloEXTRA")
        XCTAssertEqual(r.map { String(decoding: $0.body, as: UTF8.self) }, "hello")
    }

    func testContentLengthIsByteAccurateForMultibyte() {
        // 😀 is 4 UTF-8 bytes; Content-Length is bytes, not characters.
        let r = EventServer.parseRequest(Data("POST /x HTTP/1.1\r\nContent-Length: 4\r\n\r\n😀".utf8))
        XCTAssertEqual(r.map { String(decoding: $0.body, as: UTF8.self) }, "😀")
    }

    func testHeaderNameIsCaseInsensitive() {
        let r = req("POST /x HTTP/1.1\r\nCONTENT-LENGTH: 2\r\n\r\nhi")
        XCTAssertEqual(r.map { String(decoding: $0.body, as: UTF8.self) }, "hi")
    }

    func testMalformedRequestLineReturnsNil() {
        XCTAssertNil(req("JUNK\r\n\r\n"))            // only one token
        XCTAssertNil(req("\r\n\r\n"))                // empty request line
    }

    /// The query is split off the path at parse time rather than later, because
    /// something now reads it: the hook token rides in it. The path a handler
    /// switches on is the path alone.
    func testTheQueryIsSplitFromThePath() {
        let r = req("POST /permission?session=abc HTTP/1.1\r\n\r\n")
        XCTAssertEqual(r?.path, "/permission")
        XCTAssertEqual(r?.query, "session=abc")
    }

    func testAPathWithNoQueryHasNone() {
        let r = req("POST /permission HTTP/1.1\r\n\r\n")
        XCTAssertEqual(r?.path, "/permission")
        XCTAssertNil(r?.query)
    }

    /// A bare "?" is not a query, and must not turn into one.
    func testAnEmptyQueryIsEmptyNotMissing() {
        let r = req("POST /permission? HTTP/1.1\r\n\r\n")
        XCTAssertEqual(r?.path, "/permission")
        XCTAssertEqual(r?.query, "")
    }

    func testEmptyBufferReturnsNil() {
        XCTAssertNil(EventServer.parseRequest(Data()))
    }

    func testNonUTF8HeaderReturnsNil() {
        // Garbage bytes before the terminator must be rejected, not crash.
        var data = Data([0xFF, 0xFE, 0xFD])
        data.append(Data([13, 10, 13, 10]))   // \r\n\r\n
        XCTAssertNil(EventServer.parseRequest(data))
    }

    func testNoContentLengthHeaderYieldsEmptyBody() {
        let r = req("POST /activity HTTP/1.1\r\nHost: x\r\n\r\n{\"ignored\":true}")
        // Without Content-Length the body is treated as empty (length 0).
        XCTAssertEqual(r?.body.count, 0)
        XCTAssertEqual(r?.path, "/activity")
    }
}

/// `extractTaskId` digs an id out of TaskCreate's undocumented, variably-shaped
/// `tool_response` (dict / nested dict / free-form string / array). It must
/// tolerate any shape without crashing and return nil when there's nothing.
final class EventServerExtractTaskIdTests: XCTestCase {

    func testDictWithTaskId() {
        XCTAssertEqual(EventServer.extractTaskId(from: ["taskId": "t-9"]), "t-9")
    }

    func testDictWithIntId() {
        XCTAssertEqual(EventServer.extractTaskId(from: ["id": 5]), "5")
    }

    func testUnderscoreKey() {
        XCTAssertEqual(EventServer.extractTaskId(from: ["task_id": "x"]), "x")
    }

    func testNestedTaskDict() {
        XCTAssertEqual(EventServer.extractTaskId(from: ["task": ["taskId": "inner"]]), "inner")
    }

    func testFreeFormStringFirstIntegerWins() {
        XCTAssertEqual(EventServer.extractTaskId(from: "Created task 42: do the thing"), "42")
    }

    func testArrayReturnsFirstMatch() {
        let arr: [Any] = [["foo": 1], ["id": 7]]
        XCTAssertEqual(EventServer.extractTaskId(from: arr), "7")
    }

    func testEmptyStringIdIsIgnored() {
        XCTAssertNil(EventServer.extractTaskId(from: ["taskId": ""]))
    }

    func testNoIdReturnsNil() {
        XCTAssertNil(EventServer.extractTaskId(from: 12345))
        XCTAssertNil(EventServer.extractTaskId(from: "no digits here"))
        XCTAssertNil(EventServer.extractTaskId(from: ["unrelated": "value"]))
    }
}

/// Formatting helpers that build the card's title/detail text from tool input.
/// Bugs here are cosmetic, but malformed input must degrade to "" and the
/// length caps must hold (the card truncates long text).
final class EventServerFormattingTests: XCTestCase {

    func testHumanTitleKnownTools() {
        XCTAssertEqual(humanTitle(for: "Bash"), "Run shell command")
        XCTAssertEqual(humanTitle(for: "Edit"), "Edit file")
        XCTAssertEqual(humanTitle(for: "WebSearch"), "Search the web")
    }

    func testHumanTitleUnknownToolFallsBack() {
        XCTAssertEqual(humanTitle(for: "Frobnicate"), "Run Frobnicate")
    }

    func testHumanDetailBashPrefersCommand() {
        XCTAssertEqual(humanDetail(for: "Bash", input: ["command": "ls -la"]), "ls -la")
        XCTAssertEqual(humanDetail(for: "Bash", input: ["description": "list files"]), "list files")
        XCTAssertEqual(humanDetail(for: "Bash", input: [:]), "")
    }

    func testHumanDetailFilePath() {
        XCTAssertEqual(humanDetail(for: "Write", input: ["file_path": "/a/b.swift"]), "/a/b.swift")
    }

    func testHumanDetailTodoWriteSummary() {
        let todos: [[String: Any]] = [
            ["status": "in_progress", "content": "x"],
            ["status": "pending", "content": "y"],
            ["status": "completed", "content": "z"],
        ]
        XCTAssertEqual(humanDetail(for: "TodoWrite", input: ["todos": todos]),
                       "3 todos  ·  1 in progress")
        XCTAssertEqual(humanDetail(for: "TodoWrite", input: ["todos": [[String: Any]]()]), "no todos")
    }

    func testHumanDetailTaskTypeAndDescription() {
        XCTAssertEqual(humanDetail(for: "Task",
                                   input: ["subagent_type": "Explore", "description": "find X"]),
                       "Explore: find X")
    }

    func testHumanDetailExitPlanModeTruncatesTo120() {
        let plan = String(repeating: "a", count: 200)
        XCTAssertEqual(humanDetail(for: "ExitPlanMode", input: ["plan": plan]).count, 120)
    }

    func testHumanDetailUnknownToolFallsThroughToCommonKeys() {
        XCTAssertEqual(humanDetail(for: "Mystery", input: ["command": "do it"]), "do it")
        XCTAssertEqual(humanDetail(for: "Mystery", input: [:]), "")
    }

    func testDetailFromHookPayload() {
        XCTAssertEqual(detailFromHookPayload(["cwd": "/Users/me/myproject"]), "myproject")
        XCTAssertEqual(detailFromHookPayload(["session_id": "abcdefgh12345"]), "Session abcdefgh")
        XCTAssertEqual(detailFromHookPayload([:]), "")
    }
}

extension EventServerParseTests {

    /// A local process must not be able to make the server buffer without end by
    /// declaring a giant body and dribbling bytes, or by never terminating.

    func testAbsurdContentLengthIsRefusedNotAwaited() {
        // Well over the ceiling: this must be rejected, not treated as "keep
        // waiting for a gigabyte of body".
        let r = req("POST /hook HTTP/1.1\r\nContent-Length: 999999999\r\n\r\nhi")
        XCTAssertNil(r)
    }

    func testNegativeContentLengthIsRejected() {
        let r = req("POST /hook HTTP/1.1\r\nContent-Length: -5\r\n\r\nhi")
        XCTAssertNil(r)
    }

    func testALengthRightAtTheCeilingIsStillParseable() {
        // The cap rejects *over* the ceiling; a body declared at exactly the
        // ceiling is legal (even if we never actually receive one that big).
        let header = "POST /x HTTP/1.1\r\nContent-Length: \(EventServer.maxRequestBytes)\r\n\r\n"
        let full = Data(header.utf8) + Data(count: EventServer.maxRequestBytes)
        let r = EventServer.parseRequest(full)
        XCTAssertEqual(r?.body.count, EventServer.maxRequestBytes)
    }
}

/// `isLocalHookRequest` gates the loopback server against browser-originated
/// requests (a page the user has open, incl. DNS-rebinding). Real hooks are
/// curl/bash to 127.0.0.1 with no Origin; those must pass, browsers must not.
final class EventServerOriginTests: XCTestCase {

    private func req(_ s: String) -> EventServer.HTTPRequest {
        EventServer.parseRequest(Data(s.utf8))!
    }

    func testLoopbackHookAllowed() {
        XCTAssertTrue(EventServer.isLocalHookRequest(
            req("POST /hook HTTP/1.1\r\nHost: 127.0.0.1:53127\r\nContent-Length: 2\r\n\r\n{}")))
    }

    func testLocalhostHostAllowed() {
        XCTAssertTrue(EventServer.isLocalHookRequest(
            req("POST /hook HTTP/1.1\r\nHost: localhost:53127\r\n\r\n")))
    }

    func testMissingHostAllowed() {
        XCTAssertTrue(EventServer.isLocalHookRequest(
            req("POST /hook HTTP/1.1\r\n\r\n")))
    }

    func testBrowserOriginRejected() {
        XCTAssertFalse(EventServer.isLocalHookRequest(
            req("POST /hook HTTP/1.1\r\nHost: 127.0.0.1:53127\r\nOrigin: http://evil.example\r\n\r\n")))
    }

    func testRebindingHostRejected() {
        // Domain rebound to 127.0.0.1: connection is loopback but Host is the
        // attacker's domain. Reject on the Host mismatch.
        XCTAssertFalse(EventServer.isLocalHookRequest(
            req("POST /hook HTTP/1.1\r\nHost: attacker.example\r\n\r\n")))
    }

    /// The drive-by the Origin check alone does not catch. A browser sends no
    /// Origin on a sub-resource GET, and Host is genuinely loopback, so
    /// `<img src="http://127.0.0.1:53127/permission">` on any page the user
    /// visits used to reach the handler and queue a blocking card.
    func testBrowserSubresourceGetRejected() {
        XCTAssertFalse(EventServer.isLocalHookRequest(
            req("GET /permission HTTP/1.1\r\nHost: 127.0.0.1:53127\r\n\r\n")))
    }

    func testNonPostMethodsRejected() {
        for method in ["GET", "HEAD", "PUT", "OPTIONS"] {
            XCTAssertFalse(EventServer.isLocalHookRequest(
                req("\(method) /hook HTTP/1.1\r\nHost: 127.0.0.1:53127\r\n\r\n")),
                "\(method) must not be accepted as a hook")
        }
    }

    /// Case is not significant in an HTTP method token in practice, and a hook
    /// forwarder that lowercased it should still work.
    func testLowercasePostAllowed() {
        XCTAssertTrue(EventServer.isLocalHookRequest(
            req("post /hook HTTP/1.1\r\nHost: 127.0.0.1:53127\r\n\r\n")))
    }
}

/// TaskCreate's INPUT carries no id: only subject, description and activeForm,
/// with the id buried in the reply text. So the meter depends entirely on
/// digging the id out of a response whose shape nobody documented, and on an
/// update being allowed to introduce a task the app never saw created.
final class TaskIdShapeTests: XCTestCase {

    /// The shape a tool reply actually arrives in most of the time. Before this
    /// was handled the dict branch found no id key, every other branch missed,
    /// and a whole task list could be worked through with the meter at zero.
    func testAnIdInsideAContentArray() {
        let response: [String: Any] = [
            "content": [["type": "text", "text": "Task #1 created successfully: Split the settings pages"]]
        ]
        XCTAssertEqual(EventServer.extractTaskId(from: response), "1")
    }

    func testAnIdInsideASingleTextBlock() {
        XCTAssertEqual(EventServer.extractTaskId(from: ["text": "Task #42 created successfully"]), "42")
    }

    func testABareStringStillWorks() {
        XCTAssertEqual(EventServer.extractTaskId(from: "Task #7 created successfully: x"), "7")
    }

    func testAnExplicitIdKeyStillWinsOverProseInTheSameReply() {
        let response: [String: Any] = [
            "taskId": "99",
            "content": [["type": "text", "text": "Task #1 created successfully"]],
        ]
        XCTAssertEqual(EventServer.extractTaskId(from: response), "99",
                       "a named field is a fact; a number in a sentence is a guess")
    }

    func testNothingUsableIsNotAnId() {
        XCTAssertNil(EventServer.extractTaskId(from: ["content": [["type": "text", "text": "done"]]]))
        XCTAssertNil(EventServer.extractTaskId(from: [String: Any]()))
    }
}

/// The meter reads created and completed ids off the session. These pin what
/// the notch will actually show for the sequence a real task list produces.
@MainActor
final class TaskMeterProgressTests: XCTestCase {

    /// The sequence a real list produces: three tasks announced up front, then
    /// worked one at a time. The meter has to climb 0/3, 1/3, 2/3.
    func testWorkingThroughAListClimbsRatherThanResetting() {
        let s = AppState()
        for id in ["1", "2", "3"] {
            s.noteTaskCreated(id: id, subject: "Task \(id)", sessionId: "sess")
        }
        XCTAssertEqual(s.sessions["sess"]?.taskTotal, 3)
        XCTAssertEqual(s.sessions["sess"]?.taskDone, 0)

        // Each status change re-announces its task's id, which is how a task
        // whose creation carried no id gets counted at all.
        s.noteTaskCreated(id: "1", sessionId: "sess", viaUpdate: true)
        s.noteTaskCompleted(id: "1", sessionId: "sess")
        s.noteTaskCreated(id: "2", sessionId: "sess", viaUpdate: true)

        XCTAssertEqual(s.sessions["sess"]?.taskTotal, 3,
                       "starting the second task must not throw away the other two")
        XCTAssertEqual(s.sessions["sess"]?.taskDone, 1)

        s.noteTaskCreated(id: "2", sessionId: "sess", viaUpdate: true)
        s.noteTaskCompleted(id: "2", sessionId: "sess")
        XCTAssertEqual(s.sessions["sess"]?.taskDone, 2, "1 of 3, then 2 of 3")
        XCTAssertEqual(s.sessions["sess"]?.taskTotal, 3)
    }

    /// The batch still resets, but only when a genuine creation says a new list
    /// has started, or a long session's denominator would grow forever.
    func testAFreshCreationAfterAFinishedBatchStartsANewList() {
        let s = AppState()
        s.noteTaskCreated(id: "1", subject: "First", sessionId: "sess")
        s.noteTaskCompleted(id: "1", sessionId: "sess")
        s.noteTaskCreated(id: "2", subject: "Second", sessionId: "sess")

        XCTAssertEqual(s.sessions["sess"]?.taskTotal, 1)
        XCTAssertEqual(s.sessions["sess"]?.taskDone, 0,
                       "everything before was finished, so this is a new list, not a fourth item")
    }

    /// A completion for a task that was never announced must not read as
    /// "2 of 1 done", which is what an unguarded counter would produce.
    func testDoneCanNeverExceedTotal() {
        let s = AppState()
        s.noteTaskCompleted(id: "ghost", sessionId: "sess")
        XCTAssertEqual(s.sessions["sess"]?.taskTotal, 1)
        XCTAssertEqual(s.sessions["sess"]?.taskDone, 1)
    }

    func testTodoWriteCountsWinWhenBothExist() {
        let s = AppState()
        s.noteTaskCreated(id: "1", subject: "x", sessionId: "sess")
        s.noteTodos(total: 6, done: 4, sessionId: "sess")
        XCTAssertEqual(s.sessions["sess"]?.taskTotal, 6, "the checklist snapshot is the fuller picture")
        XCTAssertEqual(s.sessions["sess"]?.taskDone, 4)
    }
}
