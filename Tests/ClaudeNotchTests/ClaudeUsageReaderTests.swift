import XCTest
@testable import ClaudeNotch

/// Pure helpers from the usage/cost meter. Cost is an estimate, but the window
/// inference and percentage math drive the "you're about to compact" warning,
/// so off-by-one or wrong-denominator bugs are user-visible and worth pinning.
final class ClaudeUsageReaderTests: XCTestCase {

    // MARK: - context window inference

    func testExplicitModesIgnoreModel() {
        XCTAssertEqual(ClaudeUsageReader.contextWindow(forModel: "claude-opus-4-7", tokens: 10, mode: .w200k),
                       ClaudeUsageReader.contextWindow)
        XCTAssertEqual(ClaudeUsageReader.contextWindow(forModel: "claude-haiku-4-5", tokens: 10, mode: .w1M),
                       ClaudeUsageReader.contextWindow1M)
    }

    func testAutoModeInfersFromModel() {
        XCTAssertEqual(ClaudeUsageReader.contextWindow(forModel: "claude-opus-4-7", tokens: 10, mode: .auto),
                       ClaudeUsageReader.contextWindow1M)
        XCTAssertEqual(ClaudeUsageReader.contextWindow(forModel: "claude-haiku-4-5", tokens: 10, mode: .auto),
                       ClaudeUsageReader.contextWindow)
    }

    func testAutoModeEscalatesWhenTokensExceedStandardWindow() {
        // Even a 200k-default model gets the 1M denominator once occupancy proves
        // the session is actually on the big window.
        let w = ClaudeUsageReader.contextWindow(
            forModel: "claude-haiku-4-5", tokens: 250_000, mode: .auto)
        XCTAssertEqual(w, ClaudeUsageReader.contextWindow1M)
    }

    func testModelHas1MWindow() {
        XCTAssertTrue(ClaudeUsageReader.modelHas1MWindow("claude-sonnet-4-6"))
        XCTAssertTrue(ClaudeUsageReader.modelHas1MWindow("claude-opus-4-6"))
        XCTAssertTrue(ClaudeUsageReader.modelHas1MWindow("claude-opus-4-7"))
        XCTAssertFalse(ClaudeUsageReader.modelHas1MWindow("claude-haiku-4-5"))
        XCTAssertFalse(ClaudeUsageReader.modelHas1MWindow("claude-sonnet-4-5"))
    }

    func testContextPercentClampsToOne() {
        let p = ClaudeUsageReader.contextPercent(tokens: 500_000, model: "claude-haiku-4-5", mode: .w200k)
        XCTAssertEqual(p, 1.0, accuracy: 0.0001)
    }

    func testContextPercentMidRange() {
        let p = ClaudeUsageReader.contextPercent(tokens: 100_000, model: "claude-haiku-4-5", mode: .w200k)
        XCTAssertEqual(p, 0.5, accuracy: 0.0001)
    }

    // MARK: - model id parsing

    func testModelNameVersion() {
        XCTAssertEqual(ClaudeUsageReader.modelNameVersion("claude-sonnet-4-6").name, "Sonnet")
        XCTAssertEqual(ClaudeUsageReader.modelNameVersion("claude-sonnet-4-6").version, "4.6")
        XCTAssertEqual(ClaudeUsageReader.modelNameVersion("claude-opus-4-7").name, "Opus")
        XCTAssertEqual(ClaudeUsageReader.modelNameVersion("claude-opus-4-7").version, "4.7")
    }

    func testModelNameVersionUnknownIsEmpty() {
        let r = ClaudeUsageReader.modelNameVersion("")
        XCTAssertEqual(r.name, "")
        XCTAssertEqual(r.version, "")
    }

    func testShortModel() {
        XCTAssertEqual(ClaudeUsageReader.shortModel("claude-opus-4-7"), "opus")
        XCTAssertEqual(ClaudeUsageReader.shortModel("claude-sonnet-4-6"), "sonnet")
        XCTAssertEqual(ClaudeUsageReader.shortModel("claude-haiku-4-5"), "haiku")
        XCTAssertEqual(ClaudeUsageReader.shortModel("gpt-4"), "gpt-4")
    }

    // MARK: - formatting

    func testFmtTokens() {
        XCTAssertEqual(ClaudeUsageReader.fmtTokens(500), "500")
        XCTAssertEqual(ClaudeUsageReader.fmtTokens(1_500), "2K")      // rounds
        XCTAssertEqual(ClaudeUsageReader.fmtTokens(2_300_000), "2.3M")
        XCTAssertEqual(ClaudeUsageReader.fmtTokens(3_000_000_000), "3.0B")
    }

    func testFmtMoney() {
        XCTAssertEqual(ClaudeUsageReader.fmtMoney(0.5), "$0.50")
        XCTAssertEqual(ClaudeUsageReader.fmtMoney(12.34), "$12.34")
        XCTAssertEqual(ClaudeUsageReader.fmtMoney(150), "$150")       // drops cents past $100
    }

    func testProjectName() {
        XCTAssertEqual(ClaudeUsageReader.projectName("/Users/me/claude mac app"), "claude mac app")
        XCTAssertEqual(ClaudeUsageReader.projectName("/Users/me/repo/"), "repo")
    }

    func testHourLabel() {
        XCTAssertEqual(ClaudeUsageReader.hourLabel(0), "12 AM")
        XCTAssertEqual(ClaudeUsageReader.hourLabel(9), "9 AM")
        XCTAssertEqual(ClaudeUsageReader.hourLabel(12), "12 PM")
        XCTAssertEqual(ClaudeUsageReader.hourLabel(16), "4 PM")
    }

    // MARK: - sparkline

    func testSparklineHasSevenBars() {
        let (bars, labels) = ClaudeUsageReader.sparkline(daily: [:])
        XCTAssertEqual(bars.split(separator: " ").count, 7)
        XCTAssertEqual(labels.split(separator: " ").count, 7)
    }

    // MARK: - Tokens arithmetic

    func testTokensAddAndTotal() {
        let a = ClaudeUsageReader.Tokens(input: 10, output: 20, cacheRead: 30, cacheCreation: 40, costUSD: 1)
        let b = ClaudeUsageReader.Tokens(input: 1, output: 2, cacheRead: 3, cacheCreation: 4, costUSD: 0.5)
        let s = a + b
        XCTAssertEqual(s.input, 11)
        XCTAssertEqual(s.output, 22)
        XCTAssertEqual(s.total, 11 + 22 + 33 + 44)
        XCTAssertEqual(s.costUSD, 1.5, accuracy: 0.0001)
    }

    func testCacheHitRate() {
        var u = ClaudeUsageReader.Usage()
        u.week = ClaudeUsageReader.Tokens(input: 100, output: 0, cacheRead: 300, cacheCreation: 0, costUSD: 0)
        // cacheRead / (input + cacheCreation + cacheRead) = 300 / 400
        XCTAssertEqual(u.cacheHitRate, 0.75, accuracy: 0.0001)
    }

    func testCacheHitRateZeroWhenNoInput() {
        XCTAssertEqual(ClaudeUsageReader.Usage().cacheHitRate, 0)
    }

    // MARK: - session meter on a real-shaped transcript

    func testSessionMeterParsesTranscript() throws {
        // Two assistant turns; the latest turn's input-side tokens win for context.
        let lines = [
            #"{"timestamp":"2026-06-01T10:00:00Z","message":{"role":"assistant","model":"claude-opus-4-7","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0}}}"#,
            #"{"timestamp":"2026-06-01T10:01:00Z","message":{"role":"assistant","model":"claude-opus-4-7","usage":{"input_tokens":1500,"output_tokens":600,"cache_read_input_tokens":5000,"cache_creation_input_tokens":100}}}"#,
        ].joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-meter-test.jsonl")
        try lines.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let meter = try XCTUnwrap(ClaudeUsageReader.sessionMeter(transcriptPath: url.path))
        XCTAssertEqual(meter.model, "claude-opus-4-7")
        XCTAssertEqual(meter.contextTokens, 1500 + 5000 + 100) // latest turn input-side
        XCTAssertGreaterThan(meter.costUSD, 0)
    }

    func testSessionMeterSkipsSidechainTurns() throws {
        // A sub-agent (Task) turn must not become the live context reading.
        let lines = [
            #"{"timestamp":"2026-06-01T10:00:00Z","message":{"role":"assistant","model":"claude-opus-4-7","usage":{"input_tokens":9000,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
            #"{"isSidechain":true,"timestamp":"2026-06-01T10:00:30Z","message":{"role":"assistant","model":"claude-haiku-4-5","usage":{"input_tokens":50,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
        ].joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-meter-sidechain.jsonl")
        try lines.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let meter = try XCTUnwrap(ClaudeUsageReader.sessionMeter(transcriptPath: url.path))
        XCTAssertEqual(meter.contextTokens, 9000, "sidechain turn must not override the main context reading")
        XCTAssertEqual(meter.model, "claude-opus-4-7")
    }

    func testSessionMeterMissingFileReturnsNil() {
        XCTAssertNil(ClaudeUsageReader.sessionMeter(transcriptPath: "/nonexistent/path.jsonl"))
        XCTAssertNil(ClaudeUsageReader.sessionMeter(transcriptPath: ""))
    }
}
