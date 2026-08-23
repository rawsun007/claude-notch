import XCTest
@testable import ClaudeNotch

/// A session stuck retrying one call bills at full speed until somebody looks.
/// Counting is easy; the work is in not accusing an honest session of looping.
final class ToolRepeatTests: XCTestCase {

    // MARK: - What counts as the same call

    func testTheSameBashCommandIsOneSignature() {
        let a = ToolRepeat.signature(tool: "Bash", input: ["command": "npm test"])
        let b = ToolRepeat.signature(tool: "Bash", input: ["command": "npm test"])
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }

    func testDifferentCommandsAreDifferentSignatures() {
        XCTAssertNotEqual(ToolRepeat.signature(tool: "Bash", input: ["command": "npm test"]),
                          ToolRepeat.signature(tool: "Bash", input: ["command": "npm build"]))
    }

    /// The same command written two ways is one call, not two.
    func testWhitespaceIsCollapsed() {
        XCTAssertEqual(ToolRepeat.signature(tool: "Bash", input: ["command": "npm   test"]),
                       ToolRepeat.signature(tool: "Bash", input: ["command": " npm test "]))
        XCTAssertEqual(ToolRepeat.signature(tool: "Bash", input: ["command": "npm\ttest"]),
                       ToolRepeat.signature(tool: "Bash", input: ["command": "npm test"]))
    }

    /// The same input under a different tool is a different call.
    func testTheToolNameIsPartOfTheSignature() {
        XCTAssertNotEqual(ToolRepeat.signature(tool: "Read", input: ["file_path": "/a/b.swift"]),
                          ToolRepeat.signature(tool: "Write", input: ["file_path": "/a/b.swift"]))
    }

    func testFileToolsKeyOnTheirPath() {
        for tool in ["Read", "Write", "Edit"] {
            let s = ToolRepeat.signature(tool: tool, input: ["file_path": "/a/b.swift", "content": "x"])
            XCTAssertTrue(s.contains("/a/b.swift"), s)
            // Content differing must not make it a different call: editing one
            // file forty times is the thing worth noticing.
            let t = ToolRepeat.signature(tool: tool, input: ["file_path": "/a/b.swift", "content": "y"])
            XCTAssertEqual(s, t)
        }
    }

    func testGrepKeysOnPatternAndPath() {
        let s = ToolRepeat.signature(tool: "Grep", input: ["pattern": "foo", "path": "/src"])
        XCTAssertTrue(s.contains("foo"), s)
        XCTAssertTrue(s.contains("/src"), s)
    }

    /// A tool this app has never seen still produces a stable signature, and
    /// key order in the dictionary must not change it.
    func testAnUnknownToolIsStillStable() {
        let a = ToolRepeat.signature(tool: "SomeNewTool", input: ["b": "2", "a": "1"])
        let b = ToolRepeat.signature(tool: "SomeNewTool", input: ["a": "1", "b": "2"])
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }

    /// Nothing identifying means no signature, and no signature is never
    /// counted. Two featureless calls must not be called the same call.
    func testACallWithNothingIdentifyingHasNoSignature() {
        XCTAssertTrue(ToolRepeat.signature(tool: "Bash", input: [:]).isEmpty)
        XCTAssertTrue(ToolRepeat.signature(tool: "Bash", input: ["command": "   "]).isEmpty)
        XCTAssertTrue(ToolRepeat.signature(tool: "", input: ["command": "ls"]).isEmpty)
        // Non-string inputs are not identifying either.
        XCTAssertTrue(ToolRepeat.signature(tool: "Odd", input: ["n": 3]).isEmpty)
    }

    /// Signatures are dictionary keys fed from payloads, so they stay bounded.
    func testSignaturesAreBounded() {
        let huge = String(repeating: "x", count: 5000)
        let s = ToolRepeat.signature(tool: "Bash", input: ["command": huge])
        XCTAssertLessThanOrEqual(s.count, ToolRepeat.signatureLimit)
    }

    // MARK: - When it speaks

    func testItSpeaksAtExactlyTheTwoThresholds() {
        XCTAssertTrue(ToolRepeat.worthAnnouncing(count: ToolRepeat.warnAt))
        XCTAssertTrue(ToolRepeat.worthAnnouncing(count: ToolRepeat.urgentAt))
    }

    /// The regression this guards: a session past the threshold must not raise
    /// a card on every subsequent call.
    func testItDoesNotSpeakOnEveryCallPastTheThreshold() {
        for n in (ToolRepeat.warnAt + 1)...(ToolRepeat.warnAt + 20) {
            XCTAssertFalse(ToolRepeat.worthAnnouncing(count: n), "spoke again at \(n)")
        }
    }

    /// The bar sits above honest iteration. Re-running one test command while
    /// chasing a fix reaches double digits legitimately.
    func testTheBarIsAboveHonestIteration() {
        XCTAssertGreaterThanOrEqual(ToolRepeat.warnAt, 25)
        XCTAssertGreaterThan(ToolRepeat.urgentAt, ToolRepeat.warnAt)
        for n in 1..<ToolRepeat.warnAt {
            XCTAssertFalse(ToolRepeat.worthAnnouncing(count: n), "spoke too early at \(n)")
        }
    }

    // MARK: - What it says

    func testTheCardNamesTheToolAndTheCount() {
        let title = ToolRepeat.cardTitle(count: 40, tool: "Bash")
        XCTAssertTrue(title.contains("Bash"), title)
        XCTAssertTrue(title.contains("40"), title)
    }

    func testThePreviewDropsTheToolNameAndIsShort() {
        let sig = ToolRepeat.signature(tool: "Bash", input: ["command": String(repeating: "ab", count: 90)])
        let preview = ToolRepeat.preview(sig)
        XCTAssertFalse(preview.hasPrefix("Bash"), preview)
        XCTAssertLessThanOrEqual(preview.count, 60)
    }

    func testTheDetailSurvivesAnEmptyPreview() {
        XCTAssertFalse(ToolRepeat.cardDetail(count: 40, preview: "").isEmpty)
    }

    // MARK: - On a session

    @MainActor
    private func loopCards(_ s: AppState) -> Int {
        s.permissionQueue.filter { $0.toolName == "Loop" }.count
    }

    @MainActor
    private func run(_ s: AppState, times: Int, command: String = "npm test") {
        for _ in 0..<times {
            s.noteToolRepeat(tool: "Bash", input: ["command": command],
                             sessionId: "s1", cwd: "/tmp/proj")
        }
    }

    @MainActor
    func testALoopIsAnnouncedOnceAtTheThreshold() {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        run(s, times: ToolRepeat.warnAt - 1)
        XCTAssertEqual(loopCards(s), 0, "must stay quiet below the bar")
        run(s, times: 1)
        XCTAssertEqual(loopCards(s), 1)
        run(s, times: 30)
        XCTAssertEqual(loopCards(s), 1, "must not repeat itself past the bar")
    }

    @MainActor
    func testAVariedSessionIsNeverAccused() {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        for i in 0..<(ToolRepeat.warnAt * 3) {
            s.noteToolRepeat(tool: "Read", input: ["file_path": "/src/file\(i).swift"],
                             sessionId: "s1", cwd: "/tmp/proj")
        }
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }

    /// Two sessions each doing their own thing must not add up into one loop.
    @MainActor
    func testCountsDoNotLeakBetweenSessions() {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        s.upsertSession(id: "s2", cwd: "/tmp/other", create: true) { _ in }
        for _ in 0..<(ToolRepeat.warnAt - 1) {
            s.noteToolRepeat(tool: "Bash", input: ["command": "npm test"], sessionId: "s1", cwd: "/tmp/proj")
            s.noteToolRepeat(tool: "Bash", input: ["command": "npm test"], sessionId: "s2", cwd: "/tmp/other")
        }
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }

    @MainActor
    func testTheSettingSilencesIt() {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        s.setRunawayAlertsEnabled(false)
        run(s, times: ToolRepeat.warnAt + 5)
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }

    @MainActor
    func testEndingASessionForgetsItsCounts() {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        run(s, times: ToolRepeat.warnAt - 1)
        s.clearToolRepeats(sessionId: "s1", cwd: "/tmp/proj")
        run(s, times: 1)
        XCTAssertEqual(loopCards(s), 0, "the count restarted, so one more call is not forty")
    }

    /// The table is payload-fed, so it must stay bounded however many distinct
    /// calls a session makes.
    @MainActor
    func testTheCountTableStaysBounded() {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        for i in 0..<(AppState.toolRepeatCountsCap * 2) {
            s.noteToolRepeat(tool: "Bash", input: ["command": "echo \(i)"],
                             sessionId: "s1", cwd: "/tmp/proj")
        }
        XCTAssertLessThanOrEqual(s.toolRepeatCounts.count, AppState.toolRepeatCountsCap)
    }
}
