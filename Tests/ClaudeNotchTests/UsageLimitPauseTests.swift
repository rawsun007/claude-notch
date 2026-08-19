import XCTest
@testable import ClaudeNotch

/// Running out of usage stopped being a failure in Claude Code 2.1.234: it
/// waits for the reset and carries on. The user is somewhere else by then, so
/// the restart is the thing worth telling them about.
final class UsageLimitPauseTests: XCTestCase {

    // MARK: - Which stops count

    func testTheUsageLimitReasonsAreRecognised() {
        XCTAssertTrue(UsageLimitPause.isLimitStop(reason: "rate_limit"))
        XCTAssertTrue(UsageLimitPause.isLimitStop(reason: "usage_limit"))
        XCTAssertTrue(UsageLimitPause.isLimitStop(reason: "RATE_LIMIT"))
    }

    /// Everything else is still a failure and still gets the red card.
    func testOtherFailuresAreNotPauses() {
        for reason in ["overloaded", "billing_error", "server_error",
                       "authentication_failed", "max_output_tokens", ""] {
            XCTAssertFalse(UsageLimitPause.isLimitStop(reason: reason), reason)
        }
    }

    // MARK: - Whether the CLI will continue on its own

    private func settingsFile(_ json: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-limit-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// Absent means on, which is the CLI's own default. Getting this backwards
    /// would tell the user to go away when the session is actually waiting for
    /// them.
    func testAbsentMeansItContinues() {
        XCTAssertTrue(UsageLimitPause.autoContinues(settingsPaths: []))
        XCTAssertTrue(UsageLimitPause.autoContinues(settingsPaths: ["/nonexistent.json"]))
    }

    func testTheSettingIsRead() throws {
        let off = try settingsFile(#"{"autoContinueAtUsageLimit": false}"#)
        let on = try settingsFile(#"{"autoContinueAtUsageLimit": true}"#)
        defer { try? FileManager.default.removeItem(atPath: off)
                try? FileManager.default.removeItem(atPath: on) }
        XCTAssertFalse(UsageLimitPause.autoContinues(settingsPaths: [off]))
        XCTAssertTrue(UsageLimitPause.autoContinues(settingsPaths: [on]))
    }

    func testTheSettingIsFoundWhenNested() throws {
        let path = try settingsFile(#"{"settings": {"autoContinueAtUsageLimit": false}}"#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertFalse(UsageLimitPause.autoContinues(settingsPaths: [path]))
    }

    func testABrokenSettingsFileFallsBackToTheDefault() throws {
        let path = try settingsFile("{ not json")
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(UsageLimitPause.autoContinues(settingsPaths: [path]))
    }

    // MARK: - What it says

    /// The two cases need opposite things from the user, so they must not read
    /// the same: one says go away, the other says come back.
    func testWaitingForTheResetAndWaitingForYouReadDifferently() {
        XCTAssertNotEqual(UsageLimitPause.pausedTitle(autoContinues: true),
                          UsageLimitPause.pausedTitle(autoContinues: false))
        let auto = UsageLimitPause.pausedDetail(autoContinues: true, resumesAt: nil)
        let manual = UsageLimitPause.pausedDetail(autoContinues: false, resumesAt: nil)
        XCTAssertTrue(auto.lowercased().contains("nothing for you to do"))
        XCTAssertTrue(manual.lowercased().contains("until you answer"))
    }

    func testTheResetTimeIsShownWhenKnown() {
        let at = Date().addingTimeInterval(3600)
        let detail = UsageLimitPause.pausedDetail(autoContinues: true, resumesAt: at)
        XCTAssertTrue(detail.contains(UsageLimitPause.clockTime(at)), detail)
    }

    func testTheResumedTitleNamesTheProject() {
        XCTAssertTrue(UsageLimitPause.resumedTitle(project: "notch").contains("notch"))
        XCTAssertFalse(UsageLimitPause.resumedTitle(project: "").isEmpty)
    }

    // MARK: - When a pause has ended

    /// Hooks that trail the stop itself are not the restart.
    func testTrailingHooksDoNotCountAsARestart() {
        let paused = Date()
        XCTAssertFalse(UsageLimitPause.isRestart(pausedAt: paused,
                                                 eventAt: paused.addingTimeInterval(1)))
        XCTAssertTrue(UsageLimitPause.isRestart(pausedAt: paused,
                                                eventAt: paused.addingTimeInterval(600)))
    }

    // MARK: - The session

    @MainActor
    private func pausedState() -> AppState {
        let s = AppState()
        s.currentCwd = "/tmp/proj"
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        s.fiveHourResetAt = Date().addingTimeInterval(3600)
        s.notePausedByUsageLimit(sessionId: "s1", cwd: "/tmp/proj")
        return s
    }

    @MainActor
    func testPausingRecordsTheSessionAndRaisesACard() {
        let s = pausedState()
        XCTAssertNotNil(s.sessions["s1"]?.limitPausedAt)
        XCTAssertNotNil(s.sessions["s1"]?.limitResumesAt)
        XCTAssertEqual(s.permissionQueue.count, 1)
        XCTAssertEqual(s.permissionQueue.first?.toolName, "UsageLimit")
        XCTAssertEqual(s.sessionsWaitingOnUsageLimit.map(\.id), ["s1"])
    }

    /// The reset time is the nearest window still ahead of us, not whichever
    /// field happened to be filled in.
    @MainActor
    func testThePauseUsesTheNearestFutureReset() {
        let s = AppState()
        s.currentCwd = "/tmp/proj"
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        let soon = Date().addingTimeInterval(1800)
        s.fiveHourResetAt = soon
        s.weeklyResetAt = Date().addingTimeInterval(86_400)
        s.notePausedByUsageLimit(sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertEqual(s.sessions["s1"]?.limitResumesAt, soon)
    }

    /// A reset time already in the past is not a resume time.
    @MainActor
    func testAPastResetIsIgnored() {
        let s = AppState()
        s.currentCwd = "/tmp/proj"
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        s.fiveHourResetAt = Date().addingTimeInterval(-60)
        s.notePausedByUsageLimit(sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertNil(s.sessions["s1"]?.limitResumesAt)
    }

    @MainActor
    func testActivityLaterClearsThePauseAndSaysSo() {
        let s = pausedState()
        s.noteUsageLimitMaybeResumed(sessionId: "s1", cwd: "/tmp/proj",
                                     at: Date().addingTimeInterval(3600))
        XCTAssertNil(s.sessions["s1"]?.limitPausedAt)
        XCTAssertEqual(s.permissionQueue.count, 2)
        XCTAssertTrue(s.permissionQueue.last?.title.contains("resumed") ?? false)
        XCTAssertTrue(s.sessionsWaitingOnUsageLimit.isEmpty)
    }

    /// A hook a second after the stop is the stop's own tail, not the restart.
    @MainActor
    func testAnImmediateHookDoesNotAnnounceAResume() {
        let s = pausedState()
        s.noteUsageLimitMaybeResumed(sessionId: "s1", cwd: "/tmp/proj", at: Date())
        XCTAssertNotNil(s.sessions["s1"]?.limitPausedAt)
        XCTAssertEqual(s.permissionQueue.count, 1)
    }

    /// And it only fires once: the session goes on firing hooks after it wakes.
    @MainActor
    func testTheResumeIsAnnouncedOnce() {
        let s = pausedState()
        let later = Date().addingTimeInterval(3600)
        s.noteUsageLimitMaybeResumed(sessionId: "s1", cwd: "/tmp/proj", at: later)
        s.noteUsageLimitMaybeResumed(sessionId: "s1", cwd: "/tmp/proj", at: later)
        s.noteUsageLimitMaybeResumed(sessionId: "s1", cwd: "/tmp/proj", at: later)
        XCTAssertEqual(s.permissionQueue.count, 2)
    }

    /// A session that never paused is not told it resumed.
    @MainActor
    func testAnUnpausedSessionIsUntouched() {
        let s = AppState()
        s.currentCwd = "/tmp/proj"
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        s.noteUsageLimitMaybeResumed(sessionId: "s1", cwd: "/tmp/proj")
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }
}
