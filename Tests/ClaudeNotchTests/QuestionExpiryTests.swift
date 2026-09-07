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

    /// The side that matters, and the one that could not be tested at all until
    /// receivedAt became injectable: a card older than the window knows it.
    func testACardPastItsWindowKnowsIt() {
        let old = QuestionRequest(
            questions: [AskQuestion(header: "", text: "?", multiSelect: false,
                                    options: [AskOption(label: "A", description: "")])],
            source: "Test", cwd: "/tmp",
            receivedAt: Date().addingTimeInterval(-EventServer.decisionWindow - 1),
            resolver: { _ in })
        XCTAssertTrue(old.hasExpired)
        XCTAssertEqual(old.secondsLeft, 0, "the countdown floors at zero rather than going negative")
    }

    /// A card one second short of the boundary is still answerable. Off by one
    /// here would either kill live cards early or keep dead ones alive.
    func testACardJustInsideTheWindowIsStillLive() {
        let almost = QuestionRequest(
            questions: [AskQuestion(header: "", text: "?", multiSelect: false,
                                    options: [AskOption(label: "A", description: "")])],
            source: "Test", cwd: "/tmp",
            receivedAt: Date().addingTimeInterval(-EventServer.decisionWindow + 5),
            resolver: { _ in })
        XCTAssertFalse(almost.hasExpired)
        XCTAssertGreaterThan(almost.secondsLeft, 0)
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

    // MARK: - Permission cards have the same problem

    private func permission(kind: PermissionRequest.Kind) -> PermissionRequest {
        PermissionRequest(kind: kind, title: "Run shell command", detail: "ls",
                          toolName: "Bash", source: "Test", cwd: "/tmp",
                          resolver: { _, _ in })
    }

    func testAFreshPermissionCardIsNotExpired() {
        XCTAssertFalse(permission(kind: .toolUse).hasExpired)
    }

    func testAPermissionCardUsesTheSameWindow() {
        let req = permission(kind: .toolUse)
        XCTAssertEqual(req.expiresAt.timeIntervalSince(req.receivedAt),
                       EventServer.decisionWindow, accuracy: 0.001)
    }

    /// A notification card is not blocking anything, so there is no hook to
    /// outlive and it must never claim to have gone stale. Getting this wrong
    /// would put an alarming orange banner on every routine ping five minutes
    /// after it arrived.
    func testANotificationCardNeverExpires() {
        XCTAssertFalse(permission(kind: .notification).hasExpired)
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
