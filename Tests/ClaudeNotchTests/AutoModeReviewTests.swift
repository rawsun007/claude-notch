import XCTest
@testable import ClaudeNotch

/// Auto mode has been the default since 14 August 2026, and it is better at
/// spotting a dangerous command than the people it replaced. The part worth
/// surfacing is the remainder, because nothing else reports it.
final class AutoModeReviewTests: XCTestCase {

    func testTheNonAskingModesAreRecognised() {
        for mode in ["auto", "acceptEdits", "bypassPermissions", "plan"] {
            XCTAssertTrue(AutoModeReview.runsWithoutAsking(mode), mode)
        }
    }

    func testTheAskingModesAreNot() {
        for mode in AutoModeReview.askingModes {
            XCTAssertFalse(AutoModeReview.runsWithoutAsking(mode), mode)
        }
    }

    /// Spelling varies between payloads, so the comparison is normalised.
    func testSpellingVariantsStillMatch() {
        XCTAssertTrue(AutoModeReview.runsWithoutAsking("acceptedits"))
        XCTAssertTrue(AutoModeReview.runsWithoutAsking("accept_edits"))
        XCTAssertTrue(AutoModeReview.runsWithoutAsking("AUTO"))
    }

    /// A mode this app has not been taught might well prompt normally, and
    /// claiming nobody was asked when they were is the worse error.
    func testAnUnknownModeSaysNothing() {
        XCTAssertFalse(AutoModeReview.runsWithoutAsking("someNewMode"))
        XCTAssertFalse(AutoModeReview.runsWithoutAsking(""))
    }

    func testTheTwoListsDoNotOverlap() {
        XCTAssertTrue(AutoModeReview.nonAskingModes.isDisjoint(with: AutoModeReview.askingModes))
    }

    func testItWaitsForASubstantialSession() {
        XCTAssertFalse(AutoModeReview.worthReviewing(mode: "auto", toolCalls: 5, alreadySaid: false))
        XCTAssertTrue(AutoModeReview.worthReviewing(mode: "auto",
                                                    toolCalls: AutoModeReview.actionsBeforeReview,
                                                    alreadySaid: false))
    }

    func testAnAskingSessionIsNeverReviewed() {
        XCTAssertFalse(AutoModeReview.worthReviewing(mode: "default", toolCalls: 5000, alreadySaid: false))
    }

    func testItSaysItOnce() {
        XCTAssertFalse(AutoModeReview.worthReviewing(mode: "auto", toolCalls: 5000, alreadySaid: true))
    }

    /// The card has to make the case for auto mode as well as name the gap,
    /// or it is arguing against a setting that is safer than what it replaced.
    func testTheCardIsNotOneSided() {
        let d = AutoModeReview.cardDetail().lowercased()
        XCTAssertTrue(d.contains("catches far more"), d)
        XCTAssertTrue(d.contains("not everything"), d)
        XCTAssertTrue(AutoModeReview.cardTitle(actions: 60, project: "notch").contains("60"))
    }

    // MARK: - On a session

    @MainActor
    func testASessionIsReviewedOnce() {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/p", create: true) {
            $0.permissionMode = "auto"
            $0.toolCallCount = AutoModeReview.actionsBeforeReview
        }
        s.reviewAutoModeIfNeeded(sessionId: "s1", cwd: "/p")
        s.reviewAutoModeIfNeeded(sessionId: "s1", cwd: "/p")
        XCTAssertEqual(s.permissionQueue.filter { $0.toolName == "AutoMode" }.count, 1)
    }

    @MainActor
    func testASessionThatAsksIsLeftAlone() {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/p", create: true) {
            $0.permissionMode = "default"
            $0.toolCallCount = 500
        }
        s.reviewAutoModeIfNeeded(sessionId: "s1", cwd: "/p")
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }

    @MainActor
    func testTheNudgeSettingSilencesIt() {
        let s = AppState()
        s.setCompactAdviceEnabled(false)
        s.upsertSession(id: "s1", cwd: "/p", create: true) {
            $0.permissionMode = "auto"
            $0.toolCallCount = 5000
        }
        s.reviewAutoModeIfNeeded(sessionId: "s1", cwd: "/p")
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }
}
