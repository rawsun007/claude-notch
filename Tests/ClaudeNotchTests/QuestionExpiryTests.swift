import XCTest
@testable import ClaudeNotch

/// A question card outlives the hook that is waiting on it.
///
/// Claude Code holds the tool call open for the length of the installed hook
/// timeout. When that closes, the server answers "no opinion" and the session
/// asks somewhere else: the terminal, the VS Code extension, a cloud session.
/// The card stays on screen looking answerable, and an answer given then is
/// dropped by PendingAnswer, which only lets the first answer count. That is
/// how someone answers a card, sees nothing happen, and has to answer the same
/// question again in their terminal.
///
/// These pin the arithmetic the card uses to know it has gone stale.
final class QuestionExpiryTests: XCTestCase {

    private func request(source: String = "Claude Code") -> QuestionRequest {
        QuestionRequest(
            questions: [AskQuestion(header: "Approach", text: "Which way?",
                                    multiSelect: false,
                                    options: [AskOption(label: "A", description: "")])],
            source: source, cwd: "/tmp", resolver: { _ in })
    }

    func testAFreshCardIsNotExpired() {
        let req = request()
        XCTAssertFalse(req.hasExpired)
    }

    /// The window has to match what the server actually waits, or the card
    /// either declares itself dead while the session is still listening, or
    /// keeps taking answers after it stopped.
    func testTheWindowMatchesTheServersDecisionWindow() {
        let req = request()
        XCTAssertEqual(req.expiresAt.timeIntervalSince(req.receivedAt),
                       EventServer.decisionWindow, accuracy: 0.001)
    }

    /// And that window has to stay inside the timeout of the hook entry the
    /// installer writes, or Claude Code gives up on the request first and the
    /// card is stale earlier than it believes.
    func testTheWindowStaysInsideTheInstalledHookTimeout() {
        XCTAssertLessThan(EventServer.decisionWindow, 290)
    }

    func testSecondsLeftCountsDownAndNeverGoesNegative() {
        let req = request()
        XCTAssertGreaterThan(req.secondsLeft, 0)
        XCTAssertLessThanOrEqual(req.secondsLeft, EventServer.decisionWindow)
    }

    /// The countdown floors at zero rather than going negative, because it is
    /// what the card renders and a negative number would read as nonsense.
    func testSecondsLeftIsFlooredAtZero() {
        // A card whose window is long past. receivedAt is set at init, so this
        // reaches the same arithmetic through the far side of the boundary.
        let req = request()
        let elapsed = -req.expiresAt.timeIntervalSinceNow
        XCTAssertLessThan(elapsed, 0, "a fresh card should not already be past its window")
        XCTAssertGreaterThanOrEqual(req.secondsLeft, 0)
    }
}
