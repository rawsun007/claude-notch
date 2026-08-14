import XCTest
@testable import ClaudeNotch

/// The `PermissionDenied` hook (Claude Code 2.1.16x) fires when auto mode's
/// classifier blocks a tool call. The reason it carries is model-authored text
/// of unbounded length arriving from an untrusted payload, and it is rendered
/// in a card and written to the history file — so what the app extracts from
/// the payload is pinned here.
final class PermissionDeniedTests: XCTestCase {

    private func reason(_ payload: [String: Any]) -> String {
        EventServer.denialReason(from: payload)
    }

    func testTheDocumentedFieldIsUsed() {
        XCTAssertEqual(reason(["reason": "Writes outside the project are not allowed"]),
                       "Writes outside the project are not allowed")
    }

    /// The CLI ships faster than its reference. A renamed key should cost the
    /// reason line, not the card.
    func testAlternativeKeysAreAccepted() {
        XCTAssertEqual(reason(["denial_reason": "blocked by policy"]), "blocked by policy")
        XCTAssertEqual(reason(["permissionDecisionReason": "no"]), "no")
    }

    func testTheDocumentedFieldWinsOverFallbacks() {
        XCTAssertEqual(reason(["message": "second", "reason": "first"]), "first")
    }

    func testAMissingOrBlankReasonIsEmptyNotACrash() {
        XCTAssertEqual(reason([:]), "")
        XCTAssertEqual(reason(["reason": "   "]), "")
        XCTAssertEqual(reason(["reason": 42]), "")
        XCTAssertEqual(reason(["reason": ["nested": true]]), "")
    }

    /// The card is two lines tall and the history file keeps 500 entries.
    func testALongReasonIsTruncated() {
        let long = String(repeating: "x", count: 1000)
        XCTAssertEqual(reason(["reason": long]).count, 240)
    }

    /// Newlines would break the single-line card layout and the CSV export the
    /// history is dumped to.
    func testNewlinesAreFlattened() {
        XCTAssertEqual(reason(["reason": "line one\nline two"]), "line one line two")
    }

    /// A denial reason quotes the command it blocked, and commands carry
    /// tokens. This text goes to disk in the history file, so it is redacted on
    /// the way in, like every other payload string the app keeps.
    func testACredentialInTheReasonIsRedacted() {
        let text = reason(["reason": "blocked: curl -H 'Authorization: Bearer sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKKKLLLL'"])
        XCTAssertFalse(text.contains("sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKKKLLLL"), text)
        XCTAssertTrue(text.hasPrefix("blocked: curl"), text)
    }

    /// Golden: payload in, reason out. One line per shape the hook can send.
    func testGoldenReasonTable() {
        let cases: [(name: String, payload: [String: Any], expected: String)] = [
            ("documented", ["reason": "denied by auto mode"], "denied by auto mode"),
            ("trimmed", ["reason": "  spaced  "], "spaced"),
            ("empty payload", [:], ""),
            ("wrong type", ["reason": true], ""),
            ("fallback message", ["message": "nope"], "nope"),
            ("blank falls through to next key", ["reason": "", "message": "nope"], "nope"),
        ]
        for c in cases {
            XCTAssertEqual(reason(c.payload), c.expected, c.name)
        }
    }
}
