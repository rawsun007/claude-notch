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
