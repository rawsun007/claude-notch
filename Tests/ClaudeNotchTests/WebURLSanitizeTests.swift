import XCTest
@testable import ClaudeNotch

/// PR links arrive in hook payloads and get handed to NSWorkspace.open on click.
/// sanitizedWebURL is the gate that keeps a crafted pr_url from opening a
/// file:// or custom-scheme handler: only real http(s) URLs survive.
final class WebURLSanitizeTests: XCTestCase {

    func testHttpsKept() {
        let u = "https://github.com/o/r/pull/12"
        XCTAssertEqual(AppState.sanitizedWebURL(u), u)
    }

    func testHttpKept() {
        XCTAssertEqual(AppState.sanitizedWebURL("http://example.com/x"), "http://example.com/x")
    }

    func testFileSchemeRejected() {
        XCTAssertEqual(AppState.sanitizedWebURL("file:///etc/passwd"), "")
    }

    func testCustomSchemeRejected() {
        XCTAssertEqual(AppState.sanitizedWebURL("x-evil://run?cmd=rm"), "")
        XCTAssertEqual(AppState.sanitizedWebURL("javascript:alert(1)"), "")
    }

    func testSchemelessOrEmptyRejected() {
        XCTAssertEqual(AppState.sanitizedWebURL("github.com/o/r"), "")
        XCTAssertEqual(AppState.sanitizedWebURL(""), "")
        XCTAssertEqual(AppState.sanitizedWebURL("https://"), "")   // no host
    }
}
