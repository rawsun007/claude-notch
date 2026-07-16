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

    func testQueryStringStaysOnPath() {
        // parseRequest preserves the raw path; query stripping happens later.
        let r = req("POST /permission?session=abc HTTP/1.1\r\n\r\n")
        XCTAssertEqual(r?.path, "/permission?session=abc")
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
