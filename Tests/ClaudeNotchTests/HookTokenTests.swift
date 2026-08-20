import XCTest
@testable import ClaudeNotch

/// The hook port accepts anything that can reach loopback, which is every
/// process on the Mac. A token narrows that, and the first thing it must never
/// do is make the app deaf.
final class HookTokenTests: XCTestCase {

    private func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-token-\(UUID().uuidString)/hook-token").path
    }

    // MARK: - The rule that matters most

    /// An install with no token accepts everything, exactly as before. Every
    /// existing install is in this state until its hooks are rewritten, and an
    /// app that refuses hooks because a migration is half done is an app that
    /// shows nothing.
    func testNoTokenMeansAcceptEverything() {
        XCTAssertTrue(HookToken.allows(query: nil, expected: nil))
        XCTAssertTrue(HookToken.allows(query: "t=whatever", expected: nil))
        XCTAssertTrue(HookToken.allows(query: "", expected: ""))
    }

    /// Once there is one, a request without it is refused.
    func testAMissingTokenIsRefusedOnceOneExists() {
        XCTAssertFalse(HookToken.allows(query: nil, expected: "abc123"))
        XCTAssertFalse(HookToken.allows(query: "", expected: "abc123"))
        XCTAssertFalse(HookToken.allows(query: "other=1", expected: "abc123"))
        XCTAssertFalse(HookToken.allows(query: "t=", expected: "abc123"))
    }

    func testTheRightTokenIsAccepted() {
        XCTAssertTrue(HookToken.allows(query: "t=abc123", expected: "abc123"))
        XCTAssertTrue(HookToken.allows(query: "foo=1&t=abc123", expected: "abc123"))
        XCTAssertTrue(HookToken.allows(query: "t=abc123&foo=1", expected: "abc123"))
    }

    func testAWrongTokenIsRefused() {
        XCTAssertFalse(HookToken.allows(query: "t=abc124", expected: "abc123"))
        XCTAssertFalse(HookToken.allows(query: "t=abc12", expected: "abc123"))
        XCTAssertFalse(HookToken.allows(query: "t=abc1234", expected: "abc123"))
        // A parameter that merely ends in t must not be mistaken for it.
        XCTAssertFalse(HookToken.allows(query: "at=abc123", expected: "abc123"))
    }

    // MARK: - Reading it out of a query

    func testTheTokenIsFoundWhereverItSits() {
        XCTAssertEqual(HookToken.inQuery("t=xyz"), "xyz")
        XCTAssertEqual(HookToken.inQuery("a=1&t=xyz&b=2"), "xyz")
        XCTAssertNil(HookToken.inQuery(nil))
        XCTAssertNil(HookToken.inQuery(""))
        XCTAssertNil(HookToken.inQuery("a=1"))
        XCTAssertNil(HookToken.inQuery("t"))
    }

    // MARK: - Making and keeping one

    func testATokenIsGeneratedOnceAndReused() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        let first = try XCTUnwrap(HookToken.ensure(at: path))
        XCTAssertEqual(first.count, 64, "32 bytes of hex")
        XCTAssertEqual(HookToken.ensure(at: path), first, "a second call must not rotate it")
        XCTAssertEqual(HookToken.read(from: path), first)
    }

    /// It is a credential, so it is not readable by anyone else on the Mac.
    func testTheTokenFileIsPrivate() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        _ = HookToken.ensure(at: path)

        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600)
    }

    func testTwoInstallsDoNotShareAToken() throws {
        let a = tempPath(), b = tempPath()
        defer {
            try? FileManager.default.removeItem(atPath: (a as NSString).deletingLastPathComponent)
            try? FileManager.default.removeItem(atPath: (b as NSString).deletingLastPathComponent)
        }
        XCTAssertNotEqual(HookToken.ensure(at: a), HookToken.ensure(at: b))
    }

    func testReadingAMissingTokenIsNotAnError() {
        XCTAssertNil(HookToken.read(from: "/nonexistent/hook-token"))
    }

    // MARK: - Comparison

    func testComparisonIsExact() {
        XCTAssertTrue(HookToken.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(HookToken.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(HookToken.constantTimeEquals("abc", "ab"))
        XCTAssertFalse(HookToken.constantTimeEquals("", "a"))
        XCTAssertTrue(HookToken.constantTimeEquals("", ""))
    }

    // MARK: - The request path

    /// The query has to survive parsing, or the token can never be seen.
    func testTheQueryIsParsedOffTheRequestLine() throws {
        let raw = "POST /hook?t=abc123 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}"
        let req = try XCTUnwrap(EventServer.parseRequest(Data(raw.utf8)))
        XCTAssertEqual(req.path, "/hook")
        XCTAssertEqual(req.query, "t=abc123")
        XCTAssertTrue(HookToken.allows(query: req.query, expected: "abc123"))
    }

    func testARequestWithoutAQueryStillParses() throws {
        let raw = "POST /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}"
        let req = try XCTUnwrap(EventServer.parseRequest(Data(raw.utf8)))
        XCTAssertEqual(req.path, "/ping")
        XCTAssertNil(req.query)
    }
}
