import XCTest
@testable import ClaudeNotch

/// URL-mode elicitations (CLI 2.1.287+): an MCP server sends the user to a
/// browser to sign in. The link comes from a third party, so only a plain
/// http(s) address with a host becomes a card.
final class SignInElicitationTests: XCTestCase {

    private func payload(_ url: Any, message: String = "Please authenticate") -> [String: Any] {
        ["hook_event_name": "Elicitation", "mcp_server_name": "linear", "message": message,
         "mode": "url", "url": url, "elicitation_id": "e1"]
    }

    func testParsesASignInLink() throws {
        let s = try XCTUnwrap(ElicitationParser.signIn(from: payload("https://auth.example.com/login?x=1")))
        XCTAssertEqual(s.serverName, "linear")
        XCTAssertEqual(s.message, "Please authenticate")
        XCTAssertEqual(s.host, "auth.example.com")
    }

    func testRefusesLinksThatAreNotWebPages() {
        for bad: Any in ["file:///etc/passwd", "javascript:alert(1)", "vscode://x", "https://", "not a url", 42,
                         "https://a.com/" + String(repeating: "x", count: 3000)] {
            XCTAssertNil(ElicitationParser.signIn(from: payload(bad)), "\(bad)")
        }
    }

    func testOnlyURLMode() {
        var p = payload("https://auth.example.com")
        p["mode"] = "form"
        XCTAssertNil(ElicitationParser.signIn(from: p))
    }

    func testAnOverlongMessageIsRefused() {
        XCTAssertNil(ElicitationParser.signIn(from: payload("https://a.com", message: String(repeating: "m", count: 400))))
    }

    func testAnswersMapToActions() {
        XCTAssertEqual(ElicitationParser.signInAction(for: [[ElicitationParser.signedIn]]), "accept")
        XCTAssertEqual(ElicitationParser.signInAction(for: [[ElicitationParser.declineSignIn]]), "decline")
        XCTAssertNil(ElicitationParser.signInAction(for: nil))
        XCTAssertNil(ElicitationParser.signInAction(for: [[]]))
    }

    /// A URL-mode request is still not a form.
    func testFormIgnoresURLMode() {
        XCTAssertNil(ElicitationParser.form(from: payload("https://auth.example.com")))
    }
}
