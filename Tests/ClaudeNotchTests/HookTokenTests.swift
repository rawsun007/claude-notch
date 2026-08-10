import XCTest
@testable import ClaudeNotch

/// The loopback port is reachable by every process on the machine, so a hook
/// has to prove it came from a forwarder the app installed. A forged card is
/// not cosmetic: an "Always allow" click on one installs a rule that then
/// auto-approves that command in real sessions.
final class HookTokenTests: XCTestCase {

    private func request(token: String?) -> EventServer.HTTPRequest {
        EventServer.HTTPRequest(method: "POST", path: "/hook", body: Data(),
                                host: "127.0.0.1", origin: nil, token: token)
    }

    func testMatchingTokenIsAccepted() {
        XCTAssertTrue(EventServer.isAuthorizedHook(request(token: "abc123"), expected: "abc123"))
    }

    func testWrongTokenIsRejected() {
        XCTAssertFalse(EventServer.isAuthorizedHook(request(token: "nope"), expected: "abc123"))
    }

    /// The forged-request case: something on the machine posting straight at
    /// the port with no token at all.
    func testMissingTokenIsRejected() {
        XCTAssertFalse(EventServer.isAuthorizedHook(request(token: nil), expected: "abc123"))
        XCTAssertFalse(EventServer.isAuthorizedHook(request(token: ""), expected: "abc123"))
    }

    /// A near-miss must not pass. Length is checked before the comparison, so
    /// a prefix of the real token is still refused.
    func testPrefixOfTheTokenIsRejected() {
        XCTAssertFalse(EventServer.isAuthorizedHook(request(token: "abc"), expected: "abc123"))
        XCTAssertFalse(EventServer.isAuthorizedHook(request(token: "abc1234"), expected: "abc123"))
    }

    /// Before the app has written a token — a fresh install, or one upgrading
    /// from a build that had none — hooks must keep working. Refusing here
    /// would break every hook on the machine until something reinstalled them,
    /// which is a worse failure than the one being prevented.
    func testNoTokenYetAcceptsAnything() {
        XCTAssertTrue(EventServer.isAuthorizedHook(request(token: nil), expected: nil))
        XCTAssertTrue(EventServer.isAuthorizedHook(request(token: "whatever"), expected: nil))
        XCTAssertTrue(EventServer.isAuthorizedHook(request(token: nil), expected: ""))
    }

    /// The header is parsed off the wire case-insensitively, like every other
    /// header, so a forwarder's exact casing cannot lock it out.
    func testTokenHeaderIsParsedFromTheRequest() throws {
        let raw = "POST /hook HTTP/1.1\r\nHost: 127.0.0.1\r\nX-ClaudeNotch-Token: s3cret\r\nContent-Length: 2\r\n\r\n{}"
        let req = try XCTUnwrap(EventServer.parseRequest(Data(raw.utf8)))
        XCTAssertEqual(req.token, "s3cret")
        XCTAssertTrue(EventServer.isAuthorizedHook(req, expected: "s3cret"))
    }

    func testLowercaseHeaderNameAlsoParses() throws {
        let raw = "POST /hook HTTP/1.1\r\nhost: 127.0.0.1\r\nx-claudenotch-token: s3cret\r\nContent-Length: 2\r\n\r\n{}"
        let req = try XCTUnwrap(EventServer.parseRequest(Data(raw.utf8)))
        XCTAssertEqual(req.token, "s3cret")
    }

    /// A request with no token header at all parses fine and simply carries
    /// none, so the pre-token grace path can recognise it.
    func testAbsentHeaderLeavesTokenNil() throws {
        let raw = "POST /hook HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}"
        let req = try XCTUnwrap(EventServer.parseRequest(Data(raw.utf8)))
        XCTAssertNil(req.token)
    }
}
