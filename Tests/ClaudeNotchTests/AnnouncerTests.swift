import XCTest
@testable import ClaudeNotch

/// What VoiceOver actually says when a card appears.
///
/// The notch never takes focus, so an announcement is the ONLY cue a blind user
/// gets that Claude is blocked. Two things have to hold: the ask itself must be
/// spoken, and the keys it quotes must match what `KeyboardMonitor` really does.
/// The second one is the reason these tests exist — telling someone "press
/// Return to allow" while a queue is waiting would approve every command in it.
final class AnnouncerTests: XCTestCase {

    private func ask(title: String = "Run command",
                     tool: String = "Bash",
                     detail: String = "ls",
                     kind: PermissionRequest.Kind = .toolUse,
                     dangerous: Bool = false,
                     budget: BudgetBlock? = nil) -> PermissionRequest {
        let r = PermissionRequest(kind: kind, title: title, detail: detail, toolName: tool,
                                  source: "Claude Code", cwd: "/x", originatorBundleID: nil,
                                  dangerReasons: dangerous ? ["rm -rf"] : [], resolver: { _, _ in })
        r.budgetBlock = budget
        return r
    }

    // MARK: - Permission asks

    func testASingleAskQuotesReturnAndEscape() {
        let s = Announcer.announcement(for: ask(), pending: 1)
        XCTAssertTrue(s.contains("Run command"))
        XCTAssertTrue(s.contains("Return allows"))
        XCTAssertTrue(s.contains("Escape denies"))
    }

    /// The one that matters. With a queue, Return resolves ALL of it, so the
    /// announcement must never say a bare "Return allows".
    func testAQueueSaysReturnAllowsEveryWaitingRequest() {
        let s = Announcer.announcement(for: ask(), pending: 4)
        XCTAssertTrue(s.contains("4 requests are waiting"))
        XCTAssertTrue(s.contains("allow all 4"))
        XCTAssertFalse(s.contains("Return allows. Escape denies."))
    }

    /// Enter is a no-op for a destructive command, so promising it would leave
    /// someone pressing a key that does nothing and assuming it worked.
    func testADestructiveAskNeverPromisesReturn() {
        let s = Announcer.announcement(for: ask(dangerous: true), pending: 1)
        XCTAssertTrue(s.hasPrefix("Dangerous."))
        XCTAssertTrue(s.contains("Escape denies"))
        XCTAssertFalse(s.contains("Return allows"))
    }

    func testAnOverBudgetAskNeverPromisesReturn() {
        let block = BudgetBlock(scope: "daily", cost: 12, cap: 10)
        let s = Announcer.announcement(for: ask(budget: block), pending: 1)
        XCTAssertTrue(s.contains("over budget"))
        XCTAssertFalse(s.contains("Return allows"))
    }

    /// A destructive ask in a queue is still destructive: the batch wording
    /// must not win over the "this needs confirmation" wording.
    func testDangerOutranksTheQueueWording() {
        let s = Announcer.announcement(for: ask(dangerous: true), pending: 5)
        XCTAssertFalse(s.contains("allow all"))
        XCTAssertTrue(s.contains("destructive"))
    }

    func testANotificationOnlyOffersDismiss() {
        let s = Announcer.announcement(for: ask(title: "Done", kind: .notification), pending: 1)
        XCTAssertTrue(s.contains("Escape dismisses"))
        XCTAssertFalse(s.contains("denies"))
    }

    // MARK: - Questions

    func testAQuestionSpeaksItsOptions() {
        let q = QuestionRequest(
            questions: [AskQuestion(header: "Approach", text: "Which way?", multiSelect: false,
                                    options: [AskOption(label: "Rewrite", description: "start over"),
                                              AskOption(label: "Patch", description: "minimal")])],
            source: "Claude Code", cwd: "/x", resolver: { _ in })
        let s = Announcer.announcement(for: q)
        XCTAssertTrue(s.contains("Approach"))
        XCTAssertTrue(s.contains("Which way?"))
        XCTAssertTrue(s.contains("Rewrite"))
        XCTAssertTrue(s.contains("Patch"))
        // There are no number keys for options, so it must not invent any.
        XCTAssertFalse(s.lowercased().contains("press the number"))
        XCTAssertTrue(s.contains("Escape"))
    }

    // MARK: - Diff previews

    /// Red and green carry the entire add/remove signal on screen and none of
    /// it out loud, so each side has to be named.
    func testADiffNamesWhatIsAddedAndRemoved() {
        let hunk = DiffHunk(oldLines: ["let a = 1"], newLines: ["let a = 2", "let b = 3"],
                            truncatedOld: false, truncatedNew: false)
        let s = DiffPreviewView.spoken(hunk)
        XCTAssertTrue(s.contains("Removing 1 line:"))
        XCTAssertTrue(s.contains("let a = 1"))
        XCTAssertTrue(s.contains("Adding 2 lines:"))
        XCTAssertTrue(s.contains("let b = 3"))
    }

    func testATruncatedDiffSaysThereIsMore() {
        let hunk = DiffHunk(oldLines: ["x"], newLines: ["y"],
                            truncatedOld: true, truncatedNew: false)
        XCTAssertTrue(DiffPreviewView.spoken(hunk).contains("and more"))
    }

    func testAnEmptyDiffDoesNotReadAsNothing() {
        let hunk = DiffHunk(oldLines: [], newLines: [], truncatedOld: false, truncatedNew: false)
        XCTAssertEqual(DiffPreviewView.spoken(hunk), "No changes")
    }
}
