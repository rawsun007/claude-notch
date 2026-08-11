import XCTest
@testable import ClaudeNotch

/// A failed turn is worth interrupting someone for. A turn paused by
/// compaction is not: nothing is wrong, nothing is asked of them, and Claude
/// Code carries on by itself.
final class StopFailureTests: XCTestCase {

    // MARK: - The message the user actually reads

    /// Claude Code frequently sends the reason code back as the message, so the
    /// card said "invalid_request" where a sentence should have been.
    func testABareReasonCodeIsReplacedWithAnExplanation() {
        let detail = EventServer.failureDetail(reason: "invalid_request",
                                               message: "invalid_request")
        XCTAssertFalse(detail.contains("invalid_request"))
        XCTAssertTrue(detail.contains("context window"))
    }

    /// Any lone snake_case token is a code, not a message, whichever code it is.
    func testAnyBareCodeIsTreatedAsNoMessage() {
        let detail = EventServer.failureDetail(reason: "server_error",
                                               message: "overloaded")
        XCTAssertEqual(detail, EventServer.failureDetail(reason: "server_error", message: ""))
    }

    /// A real sentence from the hook is more specific than anything guessable
    /// here, so it wins.
    func testARealMessageIsKept() {
        let msg = "Credit balance is too low to continue."
        XCTAssertEqual(EventServer.failureDetail(reason: "billing_error", message: msg), msg)
    }

    /// Every reason the dispatcher knows about explains itself, and never by
    /// echoing the code.
    func testEveryKnownReasonHasAPlainExplanation() {
        for reason in ["rate_limit", "overloaded", "authentication_failed",
                       "oauth_org_not_allowed", "billing_error", "invalid_request",
                       "model_not_found", "server_error", "max_output_tokens",
                       "something_new"] {
            let detail = EventServer.failureDetail(reason: reason, message: "")
            XCTAssertFalse(detail.isEmpty, "\(reason) explained")
            XCTAssertFalse(detail.contains("_"), "\(reason) should not echo a code")
            XCTAssertTrue(detail.hasSuffix("."), "\(reason) should read as a sentence")
        }
    }

    /// Whitespace is not a message.
    func testWhitespaceMessageFallsBack() {
        XCTAssertEqual(EventServer.failureDetail(reason: "rate_limit", message: "   \n"),
                       EventServer.failureDetail(reason: "rate_limit", message: ""))
    }

    // MARK: - Compaction is not a failure

    @MainActor
    private func session(compacting: Bool) -> AppState {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { e in
            e.isCompacting = compacting
        }
        return s
    }

    @MainActor
    func testAFailureDuringCompactionReadsAsCompaction() {
        let s = session(compacting: true)
        s.noteStopFailure(reason: "invalid_request",
                          title: "Invalid request, session stopped",
                          detail: "whatever", cwd: "/tmp/proj", sessionId: "s1")
        let card = s.permissionQueue.last
        XCTAssertEqual(card?.toolName, "Compacting")
        XCTAssertFalse(card?.title.contains("⚠️") ?? true)
        XCTAssertFalse(card?.title.contains("stopped") ?? true)
    }

    /// The session has not ended, so it must not be marked as errored — the row
    /// would go red for something that is working as designed.
    @MainActor
    func testCompactionDoesNotMarkTheSessionErrored() {
        let s = session(compacting: true)
        s.noteStopFailure(reason: "invalid_request", title: "t", detail: "d",
                          cwd: "/tmp/proj", sessionId: "s1")
        XCTAssertNotEqual(s.sessions["s1"]?.status, "error")
        XCTAssertTrue(s.sessions["s1"]?.isCompacting ?? false)
    }

    /// The same failure outside compaction still has to be loud.
    @MainActor
    func testARealFailureIsStillReportedAsOne() {
        let s = session(compacting: false)
        s.noteStopFailure(reason: "invalid_request",
                          title: "Invalid request, session stopped",
                          detail: "d", cwd: "/tmp/proj", sessionId: "s1")
        let card = s.permissionQueue.last
        XCTAssertTrue(card?.title.contains("⚠️") ?? false)
        XCTAssertEqual(s.sessions["s1"]?.status, "error")
    }

    /// Sessions tracked by cwd (no session_id was ever carried) must resolve too,
    /// or a compacting session would still be reported as a failure.
    @MainActor
    func testCompactionIsFoundWhenTheSessionIsKeyedByCwd() {
        let s = AppState()
        s.upsertSession(id: "", cwd: "/tmp/proj", create: true) { e in
            e.isCompacting = true
        }
        XCTAssertTrue(s.isCompacting(sessionId: "", cwd: "/tmp/proj/"))
        XCTAssertTrue(s.isCompacting(sessionId: "unknown-id", cwd: "/tmp/proj"))
    }

    @MainActor
    func testUnknownSessionIsNotTreatedAsCompacting() {
        let s = AppState()
        XCTAssertFalse(s.isCompacting(sessionId: "nope", cwd: "/tmp/nothing"))
    }
}
