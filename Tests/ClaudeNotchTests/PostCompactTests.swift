import XCTest
@testable import ClaudeNotch

/// Compaction has two ends. PreCompact raises the cue; PostCompact is the only
/// thing that should be allowed to lower it.
final class PostCompactTests: XCTestCase {

    @MainActor
    private func compactingSession() -> AppState {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { _ in }
        s.currentCwd = "/tmp/proj"
        s.noteCompacting(sessionId: "s1")
        return s
    }

    @MainActor
    func testCompactingIsSetByPreCompact() {
        let s = compactingSession()
        XCTAssertTrue(s.sessions["s1"]?.isCompacting ?? false)
        // The occupancy shown during compaction would be the pre-compaction
        // one, which is about to be wrong.
        XCTAssertEqual(s.sessions["s1"]?.contextPercent, 0)
    }

    @MainActor
    func testPostCompactClearsTheCue() {
        let s = compactingSession()
        s.noteCompacted(sessionId: "s1", cwd: "/tmp/proj", trigger: "auto", summary: "kept the plan")
        XCTAssertFalse(s.sessions["s1"]?.isCompacting ?? true)
    }

    @MainActor
    func testTheSummaryIsRecorded() {
        let s = compactingSession()
        s.noteCompacted(sessionId: "s1", cwd: "/tmp/proj", trigger: "manual", summary: "kept the plan")
        let entry = s.history.first
        XCTAssertEqual(entry?.toolName, "Compact")
        XCTAssertEqual(entry?.detail, "kept the plan")
        XCTAssertEqual(entry?.project, "proj")
    }

    /// Manual and automatic compaction are not the same event to the person
    /// reading the row: one of them they asked for.
    @MainActor
    func testManualAndAutomaticReadDifferently() {
        let a = compactingSession()
        a.noteCompacted(sessionId: "s1", cwd: "/tmp/proj", trigger: "manual")
        let b = compactingSession()
        b.noteCompacted(sessionId: "s1", cwd: "/tmp/proj", trigger: "auto")
        XCTAssertNotEqual(a.history.first?.title, b.history.first?.title)
    }

    /// A summary can be the whole compacted conversation. The history file is
    /// not the place to keep it.
    @MainActor
    func testALongSummaryIsCapped() {
        let s = compactingSession()
        s.noteCompacted(sessionId: "s1", cwd: "/tmp/proj", summary: String(repeating: "x", count: 5000))
        XCTAssertEqual(s.history.first?.detail.count, 500)
    }

    /// A session keyed by cwd (no session_id in the payload) still resolves.
    @MainActor
    func testASessionKeyedByCwdIsFound() {
        let s = AppState()
        s.currentCwd = "/tmp/proj"
        s.upsertSession(id: "", cwd: "/tmp/proj", create: true) { $0.isCompacting = true }
        s.noteCompacted(sessionId: "", cwd: "/tmp/proj")
        XCTAssertFalse(s.sessions["/tmp/proj"]?.isCompacting ?? true)
    }

    /// The hook is registered, or none of the above ever runs.
    func testPostCompactIsInstalled() {
        var hooks: [String: Any] = [:]
        HookInstaller.appendHook(to: "PostCompact", in: &hooks, matcher: nil)
        XCTAssertNotNil(hooks["PostCompact"])
    }
}
