import XCTest
@testable import ClaudeNotch

/// The status line is the only source for several things the notch shows. These
/// pin the ones the transcript and the hooks cannot tell us.
@MainActor
final class StatusLineTests: XCTestCase {

    /// A session has to exist before the status line can annotate it — the
    /// status line never creates one (a stale line must not resurrect a session
    /// that ended).
    private func stateWithSession(id: String, cwd: String = "/Users/me/repo") -> AppState {
        let s = AppState()
        s.noteSession(cwd: cwd, sessionId: id)
        return s
    }

    func testRenameShowsUpAsTheSessionTitle() {
        let s = stateWithSession(id: "abc")
        s.noteStatusLine(sessionId: "abc", model: "claude-opus-4-8",
                         sessionName: "rope physics", worktree: "",
                         contextPct: 5, fiveHourPct: nil, sevenDayPct: nil)
        XCTAssertEqual(s.sessions["abc"]?.title, "rope physics",
                       "a session renamed with /rename must show that name, not its folder")
    }

    func testWorktreeIsCaptured() {
        let s = stateWithSession(id: "abc")
        s.noteStatusLine(sessionId: "abc", model: "claude-opus-4-8",
                         sessionName: "", worktree: "pet-wt",
                         contextPct: 5, fiveHourPct: nil, sevenDayPct: nil)
        XCTAssertEqual(s.sessions["abc"]?.worktree, "pet-wt",
                       "two sessions in one repo are told apart by their worktree")
    }

    func testResetInstantsAreCaptured() {
        let s = stateWithSession(id: "abc")
        let inAnHour = Date().addingTimeInterval(3600)
        s.noteStatusLine(sessionId: "abc", model: "claude-opus-4-8",
                         contextPct: nil, fiveHourPct: 82, sevenDayPct: 40,
                         fiveHourResetsAt: inAnHour, sevenDayResetsAt: nil)
        XCTAssertEqual(s.fiveHourResetAt, inAnHour)
        XCTAssertEqual(s.fiveHourLimitPercent, 0.82, accuracy: 0.001)
        XCTAssertNil(s.weeklyResetAt, "an absent reset must stay absent, not become the epoch")
    }

    func testTheRealWindowBeatsTheGuess() {
        let s = stateWithSession(id: "abc")
        s.noteStatusLine(sessionId: "abc", model: "claude-opus-4-8",
                         contextPct: 16, contextWindow: 1_000_000, contextTokens: 161_000,
                         fiveHourPct: nil, sevenDayPct: nil)
        XCTAssertEqual(s.sessions["abc"]?.contextWindow, 1_000_000)
        XCTAssertEqual(s.learnedContextWindows["claude-opus-4-8"], 1_000_000)
    }
}

/// The PR badge. Claude Code resolves the open PR for the branch, so the notch
/// links to it without shelling out to `gh`.
@MainActor
final class PullRequestBadgeTests: XCTestCase {

    func testPRIsCapturedFromTheStatusLine() {
        let s = AppState()
        s.noteSession(cwd: "/Users/me/repo", sessionId: "abc")
        s.noteStatusLine(sessionId: "abc", model: "claude-opus-4-8",
                         prNumber: 42, prURL: "https://github.com/o/r/pull/42", prState: "approved",
                         contextPct: nil, fiveHourPct: nil, sevenDayPct: nil)
        XCTAssertEqual(s.sessions["abc"]?.prNumber, 42)
        XCTAssertEqual(s.sessions["abc"]?.prState, "approved")
    }

    func testNoPRLeavesTheBadgeOff() {
        let s = AppState()
        s.noteSession(cwd: "/Users/me/repo", sessionId: "abc")
        s.noteStatusLine(sessionId: "abc", model: "claude-opus-4-8",
                         contextPct: 5, fiveHourPct: nil, sevenDayPct: nil)
        XCTAssertEqual(s.sessions["abc"]?.prNumber, 0, "no PR means no badge, not #0")
    }

    func testTooltipNamesTheReviewState() {
        XCTAssertEqual(NotchView.prTooltip(number: 7, state: "changes_requested"),
                       "Pull request #7 · changes requested")
        XCTAssertEqual(NotchView.prTooltip(number: 7, state: ""), "Pull request #7")
    }
}

/// Effort. The settings file says what a NEW session would start at; the status
/// line says what the running one is actually on.
@MainActor
final class LiveEffortTests: XCTestCase {

    func testLiveEffortReplacesTheSettingsValue() {
        let s = AppState()
        s.noteSession(cwd: "/Users/me/repo", sessionId: "abc")
        s.noteEffort("Medium")                  // from settings.json
        s.noteStatusLine(sessionId: "abc", model: "claude-opus-4-8", effort: "xhigh",
                         contextPct: nil, fiveHourPct: nil, sevenDayPct: nil)
        XCTAssertEqual(s.currentEffort, "Xhigh")
    }

    func testTheSettingsPollCannotStompTheLiveValue() {
        // The settings poll runs every minute. Once Claude Code has told us what
        // the running session is on, that poll must not drag it back to stale.
        let s = AppState()
        s.noteSession(cwd: "/Users/me/repo", sessionId: "abc")
        s.noteStatusLine(sessionId: "abc", model: "claude-opus-4-8", effort: "max",
                         contextPct: nil, fiveHourPct: nil, sevenDayPct: nil)
        s.noteEffort("Medium")                  // the poll, a minute later
        XCTAssertEqual(s.currentEffort, "Max", "the live effort must win over the settings file")
    }

    func testAnEmptyEffortChangesNothing() {
        let s = AppState()
        s.noteSession(cwd: "/Users/me/repo", sessionId: "abc")
        s.noteEffort("Medium")
        s.noteStatusLine(sessionId: "abc", model: "claude-opus-4-8", effort: "",
                         contextPct: 5, fiveHourPct: nil, sevenDayPct: nil)
        XCTAssertEqual(s.currentEffort, "Medium", "no effort reported means no change")
    }
}

/// A limit reading is only true while the window it was measured in is running.
/// Claude Code pushes a status line when it redraws, so a reading can sit in the
/// notch long after it stopped being true.
final class StaleLimitTests: XCTestCase {

    func testALiveWindowKeepsItsNumber() {
        let inAnHour = Date().addingTimeInterval(3600)
        XCTAssertEqual(StatusBarRow.livePercent(0.82, resetAt: inAnHour), 0.82)
    }

    func testAWindowThatHasResetHasNoNumber() {
        // "0% · now" is a confident-looking lie about a window that no longer
        // exists. Say nothing until a real reading replaces it.
        let anHourAgo = Date().addingTimeInterval(-3600)
        XCTAssertNil(StatusBarRow.livePercent(0.82, resetAt: anHourAgo))
    }

    func testNoReadingAtAllStaysNoReading() {
        XCTAssertNil(StatusBarRow.livePercent(-1, resetAt: nil))
    }

    func testAReadingWithNoResetInstantIsStillShown() {
        // Not every plan reports a reset. A percentage with no reset is all we
        // have, and it is better than nothing.
        XCTAssertEqual(StatusBarRow.livePercent(0.4, resetAt: nil), 0.4)
    }
}

/// The notch title. "Project name" resolves from whichever session is running,
/// which is why its menu label has to be rebuilt when the menu opens rather than
/// only when you click it.
@MainActor
final class NotchTitleTests: XCTestCase {

    func testProjectModeUsesTheRunningProject() {
        let s = AppState()
        s.setNotchTitleMode(.project)
        s.noteSession(cwd: "/Users/me/claude mac app", sessionId: "abc")
        XCTAssertEqual(s.entityName, "claude mac app")
    }

    func testProjectModeFallsBackWhenNothingIsRunning() {
        let s = AppState()
        s.setNotchTitleMode(.project)
        XCTAssertEqual(s.entityName, "Claude", "with no session there is no project to show")
    }

    func testClaudeAndCustomDoNotDependOnTheSession() {
        let s = AppState()
        s.setNotchTitleMode(.claude)
        XCTAssertEqual(s.entityName, "Claude")
        s.setCustomNotchTitle("Roshan bot")
        XCTAssertEqual(s.entityName, "Roshan bot")
        s.noteSession(cwd: "/Users/me/other", sessionId: "abc")
        XCTAssertEqual(s.entityName, "Roshan bot", "a session must not override a custom title")
    }
}

/// A limit reading has an age. Claude Code only reports usage while a session is
/// redrawing its status line, so between sessions the newest reading we have goes
/// quietly out of date, and showing it as current is how the notch ended up
/// disagreeing with /usage.
@MainActor
final class LimitFreshnessTests: XCTestCase {

    func testAFreshReadingHasNoAgeToShow() {
        XCTAssertNil(StatusBarRow.readingAge(Date()))
        XCTAssertNil(StatusBarRow.readingAge(Date().addingTimeInterval(-60)))
    }

    func testAnOldReadingSaysHowOldItIs() {
        let age = StatusBarRow.readingAge(Date().addingTimeInterval(-3600))
        XCTAssertEqual(age, "1h")
    }

    func testNoReadingHasNoAge() {
        XCTAssertNil(StatusBarRow.readingAge(nil))
    }

    func testTheStatusLineStampsTheReading() {
        let s = AppState()
        s.noteSession(cwd: "/Users/me/repo", sessionId: "abc")
        XCTAssertNil(s.limitsUpdatedAt)
        s.noteStatusLine(sessionId: "abc", model: "claude-opus-4-8",
                         contextPct: nil, fiveHourPct: 34, sevenDayPct: 52)
        XCTAssertNotNil(s.limitsUpdatedAt, "a reading has to know when it arrived")
        XCTAssertEqual(s.weeklyLimitPercent, 0.52, accuracy: 0.001)
    }

    func testAPayloadWithNoLimitsDoesNotRestampTheReading() {
        // A status line that carries only context must not make an hours-old limit
        // reading look like it just arrived.
        let s = AppState()
        s.noteSession(cwd: "/Users/me/repo", sessionId: "abc")
        s.noteStatusLine(sessionId: "abc", model: "claude-opus-4-8",
                         contextPct: nil, fiveHourPct: 34, sevenDayPct: 52)
        let stamped = s.limitsUpdatedAt
        s.noteStatusLine(sessionId: "abc", model: "claude-opus-4-8",
                         contextPct: 40, fiveHourPct: nil, sevenDayPct: nil)
        XCTAssertEqual(s.limitsUpdatedAt, stamped)
    }
}
