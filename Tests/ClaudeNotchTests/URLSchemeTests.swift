import XCTest
@testable import ClaudeNotch

/// The `claudenotch://` parser, which is an untrusted-input boundary: a URL can
/// come from a web page the user only visited, so what it is allowed to say
/// matters more than what it usually says.
final class URLSchemeTests: XCTestCase {

    private func parse(_ s: String) -> NotchURLAction? {
        guard let url = URL(string: s) else { return nil }
        return NotchURL.parse(url)
    }

    // MARK: - Verbs

    func testTheBareVerbs() {
        XCTAssertEqual(parse("claudenotch://open"), .open)
        XCTAssertEqual(parse("claudenotch://settings"), .settings)
        XCTAssertEqual(parse("claudenotch://history"), .history)
        XCTAssertEqual(parse("claudenotch://standup"), .standup)
        XCTAssertEqual(parse("claudenotch://resume"), .resume(project: nil))
        XCTAssertEqual(parse("claudenotch://compose"), .compose(project: nil))
    }

    /// A URL scheme is case-insensitive, so a link typed by hand still works.
    func testTheSchemeAndVerbAreCaseInsensitive() {
        XCTAssertEqual(parse("ClaudeNotch://Settings"), .settings)
        XCTAssertEqual(parse("CLAUDENOTCH://RESUME"), .resume(project: nil))
    }

    func testAnotherSchemeIsNotOurs() {
        XCTAssertNil(parse("https://example.com/resume"))
        XCTAssertNil(parse("claudenotchx://resume"))
    }

    func testAnUnknownVerbIsDropped() {
        XCTAssertNil(parse("claudenotch://rm"))
        XCTAssertNil(parse("claudenotch://"))
    }

    // MARK: - The project argument

    func testTheProjectComesFromThePath() {
        XCTAssertEqual(parse("claudenotch://resume/myapp"), .resume(project: "myapp"))
        XCTAssertEqual(parse("claudenotch://compose/myapp"), .compose(project: "myapp"))
    }

    func testTheProjectComesFromTheQuery() {
        XCTAssertEqual(parse("claudenotch://resume?project=myapp"), .resume(project: "myapp"))
    }

    /// Both spellings of the verb-in-the-path form resolve the same way, so a
    /// caller does not have to know which one URLComponents produced.
    ///
    /// Only the empty-authority spelling is asserted. The scheme-relative one
    /// (`claudenotch:resume/myapp`) is up to Foundation's URL parser, which has
    /// changed its mind about it between releases, and nothing that opens a URL
    /// on macOS produces that form anyway.
    func testTheVerbMayLiveInThePath() {
        XCTAssertEqual(parse("claudenotch:///resume/myapp"), .resume(project: "myapp"))
    }

    func testAnEmptyProjectMeansNoProject() {
        XCTAssertEqual(parse("claudenotch://resume?project="), .resume(project: nil))
        XCTAssertEqual(parse("claudenotch://resume?project=%20%20"), .resume(project: nil))
    }

    // MARK: - What a link must not be able to say

    /// A project is the last component of a directory, never a path. If it were
    /// allowed to be one, a link on a web page could aim the agent at a folder
    /// of the page's choosing.
    func testAPathDressedUpAsAProjectIsRejected() {
        for bad in ["claudenotch://resume/../../etc",
                    "claudenotch://resume?project=/tmp/evil",
                    "claudenotch://resume?project=..%2F..%2Fetc",
                    "claudenotch://resume?project=~/Desktop",
                    "claudenotch://resume?project=.ssh"] {
            XCTAssertNil(parse(bad), "should have been rejected: \(bad)")
        }
    }

    /// Rejecting the argument must reject the whole URL. Falling back to "the
    /// most recent session anywhere" would quietly resume the wrong project.
    func testARejectedProjectDropsTheWholeURL() {
        XCTAssertNil(parse("claudenotch://resume?project=/tmp/evil"))
        XCTAssertNil(parse("claudenotch://compose/../other"))
    }

    func testControlCharactersAreRejected() {
        XCTAssertFalse(NotchURL.isSafeProjectName("my\napp"))
        XCTAssertFalse(NotchURL.isSafeProjectName("my\u{0}app"))
    }

    func testAnAbsurdlyLongNameIsRejected() {
        XCTAssertFalse(NotchURL.isSafeProjectName(String(repeating: "a", count: 129)))
        XCTAssertTrue(NotchURL.isSafeProjectName(String(repeating: "a", count: 128)))
    }

    func testOrdinaryProjectNamesArePermitted() {
        for good in ["myapp", "claude-notch", "my_app.2", "приложение", "notch (old)"] {
            XCTAssertTrue(NotchURL.isSafeProjectName(good), "should have been allowed: \(good)")
        }
    }
}
