import XCTest
@testable import ClaudeNotch

/// An agent stops when the work looks done. Without a check that can fail,
/// looking done is the only signal it had, so a session that changed a lot and
/// ran nothing is unverified rather than finished.
final class VerificationNudgeTests: XCTestCase {

    // MARK: - Classifying a call

    func testEditToolsAreEdits() {
        for tool in ["Write", "Edit", "NotebookEdit"] {
            XCTAssertTrue(VerificationNudge.isEdit(tool: tool), tool)
        }
        for tool in ["Read", "Grep", "Bash", "Glob"] {
            XCTAssertFalse(VerificationNudge.isEdit(tool: tool), tool)
        }
    }

    func testTestCommandsCountAsVerification() {
        for c in ["swift test", "npm test", "pytest -q"] {
            XCTAssertTrue(VerificationNudge.isVerification(tool: "Bash", input: ["command": c]), c)
        }
    }

    /// A build is weaker evidence than a test suite and still counts: the
    /// property that matters is that it can say no.
    func testBuildsAndCheckersCountToo() {
        for c in ["swift build", "npm run build", "cargo check", "tsc --noEmit",
                  // A build reached after a directory change still counts.
                  "cd api && swift build",
                  "go vet ./...", "eslint src", "make all"] {
            XCTAssertTrue(VerificationNudge.isVerification(tool: "Bash", input: ["command": c]), c)
        }
    }

    /// The regression: a plain substring test counted this as a build, because
    /// "make " appears inside it.
    func testOrdinaryCommandsAreNotVerification() {
        for c in ["ls -la", "git status", "cat README.md", "echo make believe",
                  "grep tsc notes.txt", "cat eslint.config.mjs"] {
            XCTAssertFalse(VerificationNudge.isVerification(tool: "Bash", input: ["command": c]), c)
        }
    }

    /// Only Bash carries a command, and a missing or non-string one is not a check.
    func testNonBashAndMalformedInputAreNotVerification() {
        XCTAssertFalse(VerificationNudge.isVerification(tool: "Read", input: ["command": "swift test"]))
        XCTAssertFalse(VerificationNudge.isVerification(tool: "Bash", input: [:]))
        XCTAssertFalse(VerificationNudge.isVerification(tool: "Bash", input: ["command": 7]))
    }

    // MARK: - Whether it is worth saying

    func testSilenceAfterRealChangeIsWorthSaying() {
        XCTAssertTrue(VerificationNudge.worthAdvising(edits: VerificationNudge.editsBeforeAdvising,
                                                      verified: false))
    }

    /// The case a nudge would be wrong: a session that did check itself.
    func testAVerifiedSessionIsNeverAdvised() {
        XCTAssertFalse(VerificationNudge.worthAdvising(edits: 50, verified: true))
    }

    /// A one-file change with an obvious diff is exactly where running the
    /// suite is overkill, and nagging there teaches people to ignore nudges.
    func testSmallChangesAreLeftAlone() {
        for edits in 0..<VerificationNudge.editsBeforeAdvising {
            XCTAssertFalse(VerificationNudge.worthAdvising(edits: edits, verified: false), "\(edits)")
        }
    }

    func testTheCardCountsTheFiles() {
        XCTAssertTrue(VerificationNudge.cardTitle(edits: 9).contains("9"))
        XCTAssertFalse(VerificationNudge.cardDetail().isEmpty)
    }

    // MARK: - On a session

    @MainActor
    private func verifyCards(_ s: AppState) -> Int {
        s.permissionQueue.filter { $0.toolName == "Verify" }.count
    }

    @MainActor
    private func edit(_ s: AppState, times: Int) {
        for i in 0..<times {
            s.noteVerificationSignal(tool: "Edit", input: ["file_path": "/p/f\(i).swift"],
                                     sessionId: "s1", cwd: "/p")
        }
    }

    @MainActor
    private func state() -> AppState {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/p", create: true) { _ in }
        return s
    }

    @MainActor
    func testAnUncheckedSessionIsAdvisedOnce() {
        let s = state()
        edit(s, times: 5)
        s.adviseVerificationIfNeeded(sessionId: "s1", cwd: "/p")
        s.adviseVerificationIfNeeded(sessionId: "s1", cwd: "/p")
        XCTAssertEqual(verifyCards(s), 1, "the same session carrying on is not news again")
    }

    @MainActor
    func testRunningTheSuiteSilencesIt() {
        let s = state()
        edit(s, times: 5)
        s.noteVerificationSignal(tool: "Bash", input: ["command": "swift test"],
                                 sessionId: "s1", cwd: "/p")
        s.adviseVerificationIfNeeded(sessionId: "s1", cwd: "/p")
        XCTAssertEqual(verifyCards(s), 0)
    }

    /// Order must not matter: checking first and editing after is still a
    /// session that ran something.
    @MainActor
    func testCheckingBeforeEditingStillCounts() {
        let s = state()
        s.noteVerificationSignal(tool: "Bash", input: ["command": "swift build"],
                                 sessionId: "s1", cwd: "/p")
        edit(s, times: 9)
        s.adviseVerificationIfNeeded(sessionId: "s1", cwd: "/p")
        XCTAssertEqual(verifyCards(s), 0)
    }

    @MainActor
    func testAQuietSessionSaysNothing() {
        let s = state()
        edit(s, times: 1)
        s.adviseVerificationIfNeeded(sessionId: "s1", cwd: "/p")
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }

    @MainActor
    func testTheNudgeSettingSilencesIt() {
        let s = state()
        s.setCompactAdviceEnabled(false)
        edit(s, times: 9)
        s.adviseVerificationIfNeeded(sessionId: "s1", cwd: "/p")
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }

    /// Reads and searches are not changes, so a session that only explored has
    /// nothing to verify.
    @MainActor
    func testAReadOnlySessionIsNotAccused() {
        let s = state()
        for i in 0..<20 {
            s.noteVerificationSignal(tool: "Read", input: ["file_path": "/p/f\(i).swift"],
                                     sessionId: "s1", cwd: "/p")
        }
        s.adviseVerificationIfNeeded(sessionId: "s1", cwd: "/p")
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }
}
