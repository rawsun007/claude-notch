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

    // MARK: - The reading after the boundary

    private func writeLines(_ lines: [String], name: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-postcompact-\(name).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// The turn before a compaction is the fullest the window ever gets, and it
    /// is the reading that used to survive the compaction that emptied it.
    func testTokensBeforeTheBoundaryAreNotTheLiveReading() throws {
        let path = try writeLines([
            #"{"message":{"role":"assistant","model":"claude-opus-4-7","usage":{"input_tokens":180000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
            #"{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued…"}}"#,
        ], name: "boundary")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let meter = try XCTUnwrap(ClaudeUsageReader.sessionMeter(transcriptPath: path))
        XCTAssertEqual(meter.contextTokens, 0)
        // Spend is spend: compaction does not refund the turns that led to it.
        XCTAssertGreaterThan(meter.costUSD, 0)
    }

    /// The first turn after the boundary is the real post-compaction reading.
    func testTheFirstTurnAfterTheBoundaryWins() throws {
        let path = try writeLines([
            #"{"message":{"role":"assistant","model":"claude-opus-4-7","usage":{"input_tokens":180000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
            #"{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"continued"}}"#,
            #"{"message":{"role":"assistant","model":"claude-opus-4-7","usage":{"input_tokens":9000,"output_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0}}}"#,
        ], name: "after")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let meter = try XCTUnwrap(ClaudeUsageReader.sessionMeter(transcriptPath: path))
        XCTAssertEqual(meter.contextTokens, 10000)
    }

    /// A zero reading is "not known yet", not "compaction finished".
    @MainActor
    func testAZeroMeterDoesNotEndTheCue() {
        let s = compactingSession()
        s.noteSessionMeter(sessionId: "s1", contextTokens: 0, costUSD: 1.5, model: "claude-opus-4-7")
        XCTAssertTrue(s.sessions["s1"]?.isCompacting ?? false)
        s.noteSessionMeter(sessionId: "s1", contextTokens: 9000, costUSD: 1.6, model: "claude-opus-4-7")
        XCTAssertFalse(s.sessions["s1"]?.isCompacting ?? true)
    }

    /// The hook is registered, or none of the above ever runs.
    func testPostCompactIsInstalled() {
        var hooks: [String: Any] = [:]
        HookInstaller.appendHook(to: "PostCompact", in: &hooks, matcher: nil)
        XCTAssertNotNil(hooks["PostCompact"])
    }
}
