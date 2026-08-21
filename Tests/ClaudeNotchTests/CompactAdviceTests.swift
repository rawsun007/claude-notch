import XCTest
@testable import ClaudeNotch

/// Compacting deliberately is the habit that keeps a long session good. The app
/// sees the number before the user does, so the only hard part is saying it
/// without becoming the thing they switch off.
final class CompactAdviceTests: XCTestCase {

    // MARK: - When to speak

    func testNothingIsSaidEarly() {
        XCTAssertEqual(CompactAdvice.urgency(percent: 0.10, alreadySaid: .none), .none)
        XCTAssertEqual(CompactAdvice.urgency(percent: CompactAdvice.suggestAt - 0.01,
                                             alreadySaid: .none), .none)
    }

    func testHalfAWindowIsWorthMentioning() {
        XCTAssertEqual(CompactAdvice.urgency(percent: CompactAdvice.suggestAt, alreadySaid: .none),
                       .suggested)
    }

    func testNearTheEndItBecomesUrgent() {
        XCTAssertEqual(CompactAdvice.urgency(percent: CompactAdvice.urgentAt, alreadySaid: .none),
                       .urgent)
    }

    /// Said once. The meter updates constantly, so anything else is a machine
    /// gun.
    func testCrossingTheSameLineTwiceSaysNothing() {
        XCTAssertEqual(CompactAdvice.urgency(percent: 0.60, alreadySaid: .suggested), .none)
        XCTAssertEqual(CompactAdvice.urgency(percent: 0.70, alreadySaid: .suggested), .none)
    }

    /// But the next line still counts, because it means something different.
    func testTheSecondLineStillCounts() {
        XCTAssertEqual(CompactAdvice.urgency(percent: 0.85, alreadySaid: .suggested), .urgent)
    }

    /// Nothing more after the urgent one: at that point the user has been told
    /// and it is their session.
    func testUrgentIsTheLastWord() {
        XCTAssertEqual(CompactAdvice.urgency(percent: 0.95, alreadySaid: .urgent), .none)
    }

    /// A dropping percentage is compaction working. Re-announcing on the way
    /// down would be the app talking about its own advice being taken.
    func testFallingBackSaysNothing() {
        XCTAssertEqual(CompactAdvice.urgency(percent: 0.20, alreadySaid: .suggested), .none)
        XCTAssertEqual(CompactAdvice.urgency(percent: 0.20, alreadySaid: .urgent), .none)
    }

    // MARK: - When to stay quiet regardless

    /// Mid-answer is the worst moment: the advice is to interrupt, and it would
    /// arrive as one.
    func testASessionMidAnswerIsLeftAlone() {
        XCTAssertFalse(CompactAdvice.worthAdvising(hasMeter: true, isWorking: true, isCompacting: false))
    }

    func testASessionAlreadyCompactingIsLeftAlone() {
        XCTAssertFalse(CompactAdvice.worthAdvising(hasMeter: true, isWorking: false, isCompacting: true))
    }

    func testASessionWithNoMeterIsLeftAlone() {
        XCTAssertFalse(CompactAdvice.worthAdvising(hasMeter: false, isWorking: false, isCompacting: false))
    }

    func testAnIdleSessionWithAMeterIsFairGame() {
        XCTAssertTrue(CompactAdvice.worthAdvising(hasMeter: true, isWorking: false, isCompacting: false))
    }

    // MARK: - What it says

    func testTheTextCarriesTheNumberAndTheTwoCasesDiffer() {
        let suggested = CompactAdvice.title(.suggested, percent: 0.57)
        XCTAssertTrue(suggested.contains("57"), suggested)
        let urgent = CompactAdvice.title(.urgent, percent: 0.84)
        XCTAssertTrue(urgent.contains("84"), urgent)
        XCTAssertNotEqual(suggested, urgent)
        XCTAssertFalse(CompactAdvice.detail(.suggested).isEmpty)
        XCTAssertFalse(CompactAdvice.detail(.urgent).isEmpty)
        XCTAssertEqual(CompactAdvice.title(.none, percent: 0.9), "")
    }

    // MARK: - On a real session

    @MainActor
    private func session(percent: Double, status: String = "ready") -> AppState {
        let s = AppState()
        s.currentCwd = "/tmp/proj"
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) {
            $0.contextPercent = percent
            $0.contextTokens = 100_000
            $0.status = status
        }
        return s
    }

    @MainActor
    func testTheCardIsRaisedOnceAndThenEscalates() {
        let s = session(percent: 0.60)
        s.adviseCompactionIfNeeded(sessionId: "s1", cwd: "/tmp/proj")
        s.adviseCompactionIfNeeded(sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertEqual(s.permissionQueue.filter { $0.toolName == "Compact" }.count, 1)

        s.upsertSession(id: "s1", cwd: "/tmp/proj") { $0.contextPercent = 0.9 }
        s.adviseCompactionIfNeeded(sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertEqual(s.permissionQueue.filter { $0.toolName == "Compact" }.count, 2)
    }

    @MainActor
    func testNothingIsSaidWhileTheSessionIsWorking() {
        let s = session(percent: 0.90, status: "thinking")
        s.adviseCompactionIfNeeded(sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }

    /// Off means off.
    @MainActor
    func testTheSettingSilencesIt() {
        let s = session(percent: 0.90)
        s.setCompactAdviceEnabled(false)
        s.adviseCompactionIfNeeded(sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }

    /// After a compaction the window is new, so the advice starts over.
    @MainActor
    func testCompactingResetsTheAdvice() {
        let s = session(percent: 0.60)
        s.adviseCompactionIfNeeded(sessionId: "s1", cwd: "/tmp/proj")
        s.noteCompacted(sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertEqual(s.sessions["s1"]?.compactAdviceGiven, "")
    }
}
