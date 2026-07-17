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

/// Permission-mode badges. The riskiest modes are the ones worth seeing on a
/// session you are NOT looking at.
final class PermissionModeBadgeTests: XCTestCase {

    func testRiskyModesAreBadged() {
        XCTAssertEqual(permissionModeBadge("bypassPermissions")?.label, "BYPASS")
        XCTAssertEqual(permissionModeBadge("dontAsk")?.label, "DON'T ASK")
        XCTAssertEqual(permissionModeBadge("auto")?.label, "AUTO")
        XCTAssertEqual(permissionModeBadge("plan")?.label, "PLAN")
    }

    func testTheOrdinaryModesAreNotBadged() {
        // A badge for the normal case is just noise on every row.
        XCTAssertNil(permissionModeBadge("default"))
        XCTAssertNil(permissionModeBadge(""))
        // acceptEdits is a normal way to work, and badging it permanently was
        // removed on purpose.
        XCTAssertNil(permissionModeBadge("acceptEdits"))
    }

    @MainActor
    func testASessionCarriesItsOwnMode() {
        // Not just the current one: a session in another project running with
        // permissions bypassed is exactly the one you need to see.
        let s = AppState()
        s.noteSession(cwd: "/Users/me/repo", sessionId: "abc")
        s.notePermissionMode("bypassPermissions", sessionId: "abc", cwd: "/Users/me/repo")
        XCTAssertEqual(s.sessions["abc"]?.permissionMode, "bypassPermissions")
    }
}

/// Cost. Everything the app computes itself is an estimate from public per-token
/// prices. Claude Code reports the figure it actually bills against, and where
/// that exists it wins.
@MainActor
final class ReportedCostTests: XCTestCase {

    func testTheReportedCostBeatsOurEstimate() {
        let s = AppState()
        s.noteSession(cwd: "/Users/me/repo", sessionId: "abc")
        s.noteSessionMeter(sessionId: "abc", contextTokens: 100, costUSD: 226, model: "claude-opus-4-8")
        XCTAssertEqual(s.currentCostUSD, 226, accuracy: 0.01, "with no reported cost, the estimate is all we have")

        s.noteStatusLine(sessionId: "abc", model: "claude-opus-4-8",
                         reportedCostUSD: 217.87,
                         contextPct: nil, fiveHourPct: nil, sevenDayPct: nil)
        XCTAssertEqual(s.currentCostUSD, 217.87, accuracy: 0.01)
        XCTAssertEqual(s.sessions["abc"]?.displayCostUSD ?? 0, 217.87, accuracy: 0.01)
    }

    func testTheEstimateCannotStompTheReportedCost() {
        // The transcript meter polls constantly. Without a guard it would replace
        // the real figure with the estimate seconds after every status line.
        let s = AppState()
        s.noteSession(cwd: "/Users/me/repo", sessionId: "abc")
        s.noteStatusLine(sessionId: "abc", model: "claude-opus-4-8",
                         reportedCostUSD: 217.87,
                         contextPct: nil, fiveHourPct: nil, sevenDayPct: nil)
        s.noteSessionMeter(sessionId: "abc", contextTokens: 100, costUSD: 226, model: "claude-opus-4-8")
        XCTAssertEqual(s.currentCostUSD, 217.87, accuracy: 0.01, "the real cost must survive the poll")
    }

    func testLinesChangedAreCaptured() {
        let s = AppState()
        s.noteSession(cwd: "/Users/me/repo", sessionId: "abc")
        s.noteStatusLine(sessionId: "abc", model: "claude-opus-4-8",
                         linesAdded: 3593, linesRemoved: 340,
                         contextPct: nil, fiveHourPct: nil, sevenDayPct: nil)
        XCTAssertEqual(s.sessions["abc"]?.linesAdded, 3593)
        XCTAssertEqual(s.sessions["abc"]?.linesRemoved, 340)
    }
}

/// What a session row is called. Claude Code names sessions itself, so the name
/// cannot be trusted to be the thing you would recognise the session by.
@MainActor
final class SessionLabelTests: XCTestCase {

    func testTheProjectIsWhatYouRecogniseASessionBy() {
        // Claude Code auto-titled this session "Caveman speech pattern
        // implementation". Nobody typed that, and it is not a folder. Showing it
        // where the project should be replaced the one label the user knows.
        let s = AppState()
        s.noteSession(cwd: "/Users/me/claude mac app", sessionId: "abc")
        s.noteStatusLine(sessionId: "abc", model: "claude-opus-4-8",
                         sessionName: "Caveman speech pattern implementation",
                         contextPct: nil, fiveHourPct: nil, sevenDayPct: nil)
        let session = s.sessions["abc"]
        XCTAssertEqual(session?.project, "claude mac app", "the project stays the project")
        XCTAssertEqual(session?.title, "Caveman speech pattern implementation",
                       "the name is kept, to be shown as a subtitle")
    }

    func testABackgroundAgentIsStillNamedByItsTask() {
        // The exception: an agent runs wherever it was dispatched, so its folder
        // says nothing, and the task it was given is genuinely its only name.
        let s = AppState()
        s.noteSession(cwd: "/Users/me/repo", sessionId: "abc")
        s.noteAgentNotice(.needsInput, sessionId: "abc")
        XCTAssertTrue(s.sessions["abc"]?.agentNeedsInput == true)
    }
}

/// One Claude session must be one row. A hook can arrive before the session_id is
/// known, which creates a fallback entry keyed by the cwd; the real id-keyed entry
/// arrives later. Both describe the same session.
@MainActor
final class SessionDedupTests: XCTestCase {

    func testAPlaceholderAndItsRealSessionCollapseToOneRow() {
        let s = AppState()
        // A hook with no session_id: keyed by the cwd (id starts with "/").
        s.noteSession(cwd: "/Users/me/app", sessionId: "")
        // The same session, now with its real id.
        s.noteSession(cwd: "/Users/me/app", sessionId: "real-uuid")
        let cwds = s.activeSessions.map(\.cwd)
        XCTAssertEqual(s.activeSessions.count, 1, "same session, one row: \\(s.activeSessions.map(\\.id))")
        XCTAssertEqual(cwds, ["/Users/me/app"])
        XCTAssertFalse(s.activeSessions.contains { $0.id.hasPrefix("/") }, "the placeholder is the duplicate")
    }

    func testTwoRealSessionsInOneProjectStayTwoRows() {
        // Genuinely two sessions in the same folder must both show.
        let s = AppState()
        s.noteSession(cwd: "/Users/me/app", sessionId: "uuid-a")
        s.noteSession(cwd: "/Users/me/app", sessionId: "uuid-b")
        XCTAssertEqual(s.activeSessions.count, 2)
    }

    func testAPlaceholderAloneStillShows() {
        // If nothing real covers the cwd, the placeholder is all we have.
        let s = AppState()
        s.noteSession(cwd: "/Users/me/app", sessionId: "")
        XCTAssertEqual(s.activeSessions.count, 1)
    }
}

/// One folder, one row unless there are genuinely two sessions in it. A single
/// physical Claude session can leave phantom entries behind (a hook before the id
/// is known, an id that changed after a compact or resume), and they show as bare
/// rows beside the real one.
@MainActor
final class SessionPhantomTests: XCTestCase {

    func testABarePhantomIsDroppedBesideTheRealSession() {
        let s = AppState()
        // The phantom arrives first and goes stale (a changed id lingering).
        s.noteSession(cwd: "/Users/me/app", sessionId: "phantom")
        // The real session is the one in front of you now: it has a name + meter.
        s.noteSession(cwd: "/Users/me/app", sessionId: "real")
        s.noteStatusLine(sessionId: "real", model: "claude-opus-4-8",
                         sessionName: "Fix the parser",
                         contextPct: 40, fiveHourPct: nil, sevenDayPct: nil)
        XCTAssertEqual(s.activeSessions.map(\.id), ["real"],
                       "the nameless, meterless phantom is dropped")
    }

    func testTwoRealSessionsInOneFolderBothShow() {
        // Each has its own identity, so both are genuine.
        let s = AppState()
        s.noteSession(cwd: "/Users/me/app", sessionId: "a")
        s.noteStatusLine(sessionId: "a", model: "claude-opus-4-8", sessionName: "Task A",
                         contextPct: 10, fiveHourPct: nil, sevenDayPct: nil)
        s.noteSession(cwd: "/Users/me/app", sessionId: "b")
        s.noteStatusLine(sessionId: "b", model: "claude-opus-4-8", sessionName: "Task B",
                         contextPct: 20, fiveHourPct: nil, sevenDayPct: nil)
        XCTAssertEqual(s.activeSessions.count, 2)
    }

    func testALoneBareSessionStillShows() {
        // If nothing richer covers the folder, the bare row is all there is.
        let s = AppState()
        s.noteSession(cwd: "/Users/me/app", sessionId: "only")
        XCTAssertEqual(s.activeSessions.count, 1)
    }
}

/// The run timer. A ticking count is the answer to "is this long tool call stuck
/// or still working", which is the most-asked question about a long agent run.
final class RunningDurationTests: XCTestCase {

    func testSecondsUnderAMinute() {
        XCTAssertEqual(AppState.runningDuration(seconds: 0), "0s")
        XCTAssertEqual(AppState.runningDuration(seconds: 42), "42s")
        XCTAssertEqual(AppState.runningDuration(seconds: 59.9), "59s")
    }

    func testMinutesAndSecondsAreZeroPadded() {
        // "3m 5s" reads worse at a glance than "3m 05s" when it is ticking.
        XCTAssertEqual(AppState.runningDuration(seconds: 65), "1m 05s")
        XCTAssertEqual(AppState.runningDuration(seconds: 185), "3m 05s")
        XCTAssertEqual(AppState.runningDuration(seconds: 600), "10m 00s")
    }

    func testNegativeClampsToZero() {
        // A clock skew must not print a negative timer.
        XCTAssertEqual(AppState.runningDuration(seconds: -5), "0s")
    }
}

/// The long-run alert. One nudge when a single tool call passes the threshold,
/// the answer to "is this agent stuck" without watching the notch.
final class LongRunAlertTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let threshold: TimeInterval = 300

    private func should(_ enabled: Bool = true, working: Bool = true,
                        started: Date?, alerted: Date? = nil, at seconds: Double) -> Bool {
        AppState.shouldAlertLongRun(enabled: enabled, working: working, startedAt: started,
                                    alertedFor: alerted, now: t0.addingTimeInterval(seconds),
                                    threshold: threshold)
    }

    func testFiresOncePastTheThreshold() {
        XCTAssertFalse(should(started: t0, at: 299))
        XCTAssertTrue(should(started: t0, at: 300))
    }

    func testDoesNotFireAgainForTheSameRun() {
        // Once we have alerted for this run's start, no more.
        XCTAssertFalse(should(started: t0, alerted: t0, at: 600))
    }

    func testANewRunCanAlertAgain() {
        // A fresh tool call resets startedAt, so it earns its own alert.
        let newRun = t0.addingTimeInterval(700)
        XCTAssertTrue(should(started: newRun, alerted: t0, at: 700 + 300))
    }

    func testOffAndIdleNeverFire() {
        XCTAssertFalse(should(false, started: t0, at: 999))
        XCTAssertFalse(should(working: false, started: t0, at: 999))
        XCTAssertFalse(should(started: nil, at: 999))
    }
}

/// VoiceOver phrasing for a permission ask. Blind users get one clear sentence,
/// with the danger flagged first.
final class SpokenAskTests: XCTestCase {

    private func ask(title: String, tool: String, detail: String, dangerous: Bool) -> PermissionRequest {
        PermissionRequest(kind: .toolUse, title: title, detail: detail, toolName: tool,
                          source: "Claude Code", cwd: "/x", originatorBundleID: nil,
                          dangerReasons: dangerous ? ["rm -rf"] : [], resolver: { _, _ in })
    }

    func testDangerIsSpokenFirst() {
        let s = PermissionCard.spokenAsk(for: ask(title: "Run command", tool: "Bash",
                                                  detail: "rm -rf build", dangerous: true))
        XCTAssertTrue(s.hasPrefix("Dangerous."))
        XCTAssertTrue(s.contains("Bash"))
        XCTAssertTrue(s.contains("rm -rf build"))
    }

    func testAnOrdinaryAskReadsCleanly() {
        let s = PermissionCard.spokenAsk(for: ask(title: "Edit main.swift", tool: "Edit",
                                                  detail: "", dangerous: false))
        XCTAssertEqual(s, "Edit main.swift Tool: Edit.")
    }

    func testNotificationToolIsNotAnnouncedAsATool() {
        let s = PermissionCard.spokenAsk(for: ask(title: "Task finished", tool: "Notification",
                                                  detail: "", dangerous: false))
        XCTAssertEqual(s, "Task finished")
    }
}

/// Warning before a plan limit runs out. Fires at 80% then 95%, once each per
/// window, so a lockout mid-task is not a surprise and you are not nagged.
final class RateLimitWarningTests: XCTestCase {

    func testWarnsAtEachThresholdOnce() {
        // Below the first threshold: nothing.
        XCTAssertNil(AppState.rateLimitWarning(pct: 0.5, alreadyWarned: 0))
        // Crossing 80%: warn at 80.
        XCTAssertEqual(AppState.rateLimitWarning(pct: 0.82, alreadyWarned: 0), 0.80)
        // Already warned at 80, still under 95: nothing.
        XCTAssertNil(AppState.rateLimitWarning(pct: 0.90, alreadyWarned: 0.80))
        // Crossing 95: warn at 95.
        XCTAssertEqual(AppState.rateLimitWarning(pct: 0.96, alreadyWarned: 0.80), 0.95)
        // Both fired: nothing more.
        XCTAssertNil(AppState.rateLimitWarning(pct: 0.99, alreadyWarned: 0.95))
    }

    func testAJumpStraightToTheTopWarnsAtTheHighestCrossed() {
        // Going from nothing to 97% in one reading fires the 95, not the 80.
        XCTAssertEqual(AppState.rateLimitWarning(pct: 0.97, alreadyWarned: 0), 0.95)
    }
}
