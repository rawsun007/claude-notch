import XCTest
@testable import ClaudeNotch

/// Claude Code resolves the open review for a branch and reports it through one
/// set of fields whatever the host is, parsing GitHub's /pull/42 and GitLab's
/// /-/merge_requests/42 into the same number. Only the wording differs, and a
/// GitLab user shown "#42" beside a pull-request icon is being told about
/// something their host does not have.
final class ReviewHostTests: XCTestCase {

    func testGitLabIsRecognisedByItsPath() {
        XCTAssertEqual(ReviewHost.infer(from: "https://gitlab.com/acme/web/-/merge_requests/42"), .gitlab)
        // Self-hosted, no "gitlab" in the domain at all.
        XCTAssertEqual(ReviewHost.infer(from: "https://git.acme.dev/team/api/-/merge_requests/7"), .gitlab)
    }

    func testGitHubIsRecognisedByItsPath() {
        XCTAssertEqual(ReviewHost.infer(from: "https://github.com/rawsun007/claude-notch/pull/12"), .github)
        XCTAssertEqual(ReviewHost.infer(from: "https://github.acme.dev/team/api/pull/3"), .github)
    }

    func testBitbucketIsRecognised() {
        XCTAssertEqual(ReviewHost.infer(from: "https://bitbucket.org/acme/web/pull-requests/9"), .bitbucket)
    }

    /// A URL shape this does not know still gets classified from the domain
    /// rather than falling all the way through to the wrong noun.
    func testTheDomainIsTheFallback() {
        XCTAssertEqual(ReviewHost.infer(from: "https://gitlab.acme.dev/something/odd"), .gitlab)
        XCTAssertEqual(ReviewHost.infer(from: "https://example.com/whatever"), .unknown)
        XCTAssertEqual(ReviewHost.infer(from: ""), .unknown)
    }

    /// The whole point: GitLab writes !42.
    func testTheSigilFollowsTheHost() {
        XCTAssertEqual(ReviewHost.chipLabel(url: "https://gitlab.com/a/b/-/merge_requests/42", number: 42), "!42")
        XCTAssertEqual(ReviewHost.chipLabel(url: "https://github.com/a/b/pull/42", number: 42), "#42")
        // An unknown host keeps the more common spelling rather than inventing one.
        XCTAssertEqual(ReviewHost.chipLabel(url: "", number: 42), "#42")
    }

    func testTheIconFollowsTheHost() {
        XCTAssertEqual(ReviewHost.gitlab.symbol, "arrow.triangle.merge")
        XCTAssertEqual(ReviewHost.github.symbol, "arrow.triangle.pull")
    }

    func testTheSpokenFormNamesTheRightThing() {
        XCTAssertEqual(ReviewHost.spoken(url: "https://gitlab.com/a/b/-/merge_requests/42", number: 42),
                       "Merge request !42")
        XCTAssertEqual(ReviewHost.spoken(url: "https://github.com/a/b/pull/7", number: 7),
                       "Pull request #7")
    }

    // MARK: - The tooltip

    @MainActor
    func testTheTooltipNamesTheHostAndTheState() {
        let mr = NotchView.prTooltip(number: 42, state: "approved",
                                     url: "https://gitlab.com/a/b/-/merge_requests/42")
        XCTAssertTrue(mr.contains("Merge request !42"), mr)
        XCTAssertTrue(mr.contains("approved"), mr)

        let pr = NotchView.prTooltip(number: 8, state: "changes_requested",
                                     url: "https://github.com/a/b/pull/8")
        XCTAssertTrue(pr.contains("Pull request #8"), pr)
        XCTAssertTrue(pr.contains("changes requested"), pr)
    }

    /// A state the app does not know about drops to just the identifier rather
    /// than inventing a description.
    @MainActor
    func testAnUnknownStateSaysNothingExtra() {
        XCTAssertEqual(NotchView.prTooltip(number: 3, state: "mergeable",
                                           url: "https://gitlab.com/a/b/-/merge_requests/3"),
                       "Merge request !3")
    }

    /// The old call shape still compiles and still reads as GitHub, so nothing
    /// that has not been updated regresses.
    @MainActor
    func testTheDefaultRemainsTheCommonCase() {
        XCTAssertTrue(NotchView.prTooltip(number: 5, state: "").contains("Pull request #5"))
    }
}
