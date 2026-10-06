import XCTest
@testable import ClaudeNotch

/// A message to a background agent goes out as `claude --resume <id> "msg"`.
/// Both values come from outside the app (the roster, the user's typing), so
/// both are quoted, and a message that looks like an option is not read as one.
final class BackgroundReplyTests: XCTestCase {

    func testCommandQuotesBothValues() {
        let cmd = TerminalAutomator.resumeWithMessageCommand(claude: "/opt/homebrew/bin/claude",
                                                             sessionId: "703d48dc-aaaa", message: "it's done; rm -rf /")
        XCTAssertEqual(cmd, "'/opt/homebrew/bin/claude' --resume '703d48dc-aaaa' 'it'\\''s done; rm -rf /'")
    }

    func testAMessageStartingWithADashIsNotAnOption() {
        let cmd = TerminalAutomator.resumeWithMessageCommand(claude: "claude", sessionId: "abc", message: "--dangerously-skip-permissions")
        XCTAssertTrue(cmd.hasSuffix("' --dangerously-skip-permissions'"), cmd)
    }
}
