import XCTest
@testable import ClaudeNotch

/// `claude --desktop --resume <id>` gets a session id from a transcript name
/// or a hook payload, so only a real-looking id is passed on.
final class ClaudeDesktopTests: XCTestCase {

    func testArgumentsForARealId() {
        XCTAssertEqual(ClaudeDesktop.arguments(sessionId: "db832360-51e1-4ecd-b38c-cadf537714bd"),
                       ["--desktop", "--resume", "db832360-51e1-4ecd-b38c-cadf537714bd"])
    }

    func testRefusesIdsThatCouldBeFlagsOrPaths() {
        for bad in ["", "--dangerously-skip-permissions", "-p", "../x", "a b", "id;rm", "ﬁ"] {
            XCTAssertNil(ClaudeDesktop.arguments(sessionId: bad), bad)
        }
    }
}
