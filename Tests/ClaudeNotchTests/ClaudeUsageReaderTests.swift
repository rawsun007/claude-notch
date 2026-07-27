import XCTest
@testable import ClaudeNotch

/// Pure helpers from the usage/cost meter. Cost is an estimate, but the window
/// inference and percentage math drive the "you're about to compact" warning,
/// so off-by-one or wrong-denominator bugs are user-visible and worth pinning.
final class ClaudeUsageReaderTests: XCTestCase {

    // MARK: - weekly cost bucketing (trend chart)

    /// A fixed calendar + anchor date so the buckets are deterministic.
    private func utcCal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ s: String, _ cal: Calendar) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    func testWeeklyBucketsCountAndOrder() {
        let cal = utcCal()
        let buckets = ClaudeUsageReader.weeklyCostBuckets(
            daily: [:], weeks: 4, asOf: date("2026-07-22", cal), calendar: cal)
        XCTAssertEqual(buckets.count, 4)
        XCTAssertEqual(buckets.map(\.label), ["3w ago", "2w ago", "1w ago", "This wk"])
        XCTAssertEqual(buckets.map(\.cost), [0, 0, 0, 0])
    }

    func testWeeklyBucketsSumIntoCorrectWeek() {
        let cal = utcCal()
        let asOf = date("2026-07-22", cal)   // a Wednesday
        // Today and 6 days back land in "This wk"; day 7 back lands in "1w ago".
        let daily: [String: Double] = [
            "2026-07-22": 1.0,   // today  -> this wk
            "2026-07-16": 2.0,   // 6 days -> this wk
            "2026-07-15": 4.0,   // 7 days -> 1w ago
            "2026-07-09": 8.0,   // 13 days -> 1w ago
            "2026-07-08": 16.0,  // 14 days -> 2w ago
            "2026-06-01": 99.0,  // outside 4 weeks -> dropped
        ]
        let b = ClaudeUsageReader.weeklyCostBuckets(daily: daily, weeks: 4, asOf: asOf, calendar: cal)
        let byLabel = Dictionary(uniqueKeysWithValues: b.map { ($0.label, $0.cost) })
        XCTAssertEqual(byLabel["This wk"] ?? -1, 3.0, accuracy: 0.0001)
        XCTAssertEqual(byLabel["1w ago"] ?? -1, 12.0, accuracy: 0.0001)
        XCTAssertEqual(byLabel["2w ago"] ?? -1, 16.0, accuracy: 0.0001)
        XCTAssertEqual(byLabel["3w ago"] ?? -1, 0.0, accuracy: 0.0001)
    }

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

    func testNewerFrontierModelsInheritTheBigWindow() {
        // The bug this replaces: Opus 4.8 shipped with a 1M window, was missing
        // from a hardcoded list, and so a 161k context (16% of the window) was
        // drawn as 161k/200k with the bar in the red.
        XCTAssertTrue(ClaudeUsageReader.modelHas1MWindow("claude-opus-4-8"))
        // And the ones after it, without anyone having to remember to come back here.
        XCTAssertTrue(ClaudeUsageReader.modelHas1MWindow("claude-opus-4-9"))
        XCTAssertTrue(ClaudeUsageReader.modelHas1MWindow("claude-sonnet-5"))
        // Including families that did not exist when the rule was written.
        XCTAssertTrue(ClaudeUsageReader.modelHas1MWindow("claude-fable-5"))
        // Haiku stays small however new it is.
        XCTAssertFalse(ClaudeUsageReader.modelHas1MWindow("claude-haiku-5"))
        // And an unreadable id keeps the conservative denominator.
        XCTAssertFalse(ClaudeUsageReader.modelHas1MWindow("some-other-model"))
    }

    func testModelVersionParsing() {
        XCTAssertEqual(ClaudeUsageReader.modelVersion("claude-opus-4-8"), 4.8)
        XCTAssertEqual(ClaudeUsageReader.modelVersion("claude-sonnet-5"), 5.0)
        // A trailing date stamp is not a version component.
        XCTAssertEqual(ClaudeUsageReader.modelVersion("claude-haiku-4-5-20251001"), 4.5)
        XCTAssertNil(ClaudeUsageReader.modelVersion("unknown"))
    }

    func testOpus48SessionIsNotReportedAsNearlyFull() {
        // The screenshot that started this: 161k tokens on Opus 4.8.
        let w = ClaudeUsageReader.contextWindow(forModel: "claude-opus-4-8", tokens: 161_000, mode: .auto)
        XCTAssertEqual(w, ClaudeUsageReader.contextWindow1M)
        let p = ClaudeUsageReader.contextPercent(tokens: 161_000, model: "claude-opus-4-8", mode: .auto)
        XCTAssertEqual(p, 0.161, accuracy: 0.001, "16% full, not 81%")
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

    func testShortModelKeepsTheVersion() {
        XCTAssertEqual(ClaudeUsageReader.shortModel("claude-opus-4-7"), "opus 4.7")
        XCTAssertEqual(ClaudeUsageReader.shortModel("claude-sonnet-4-6"), "sonnet 4.6")
        XCTAssertEqual(ClaudeUsageReader.shortModel("claude-haiku-4-5"), "haiku 4.5")
        XCTAssertEqual(ClaudeUsageReader.shortModel("gpt-4"), "gpt-4")
    }

    /// A single-digit version is a version. Reading a fixed N-M pair found
    /// nothing in claude-opus-5, so the notch showed a bare "Opus".
    func testASingleDigitVersionIsRead() {
        XCTAssertEqual(ClaudeUsageReader.modelVersionLabel("claude-opus-5"), "5")
        XCTAssertEqual(ClaudeUsageReader.modelNameVersion("claude-opus-5").version, "5")
        XCTAssertEqual(ClaudeUsageReader.shortModel("claude-opus-5"), "opus 5")
    }

    /// The point of doing this by digit groups rather than a fixed shape: a
    /// later 5.1 or 5.2 has to work without anyone touching this again.
    func testAFutureMinorVersionIsRead() {
        XCTAssertEqual(ClaudeUsageReader.modelVersionLabel("claude-opus-5-1"), "5.1")
        XCTAssertEqual(ClaudeUsageReader.modelVersionLabel("claude-opus-5-2"), "5.2")
        XCTAssertEqual(ClaudeUsageReader.modelVersionLabel("claude-opus-10-3"), "10.3")
        XCTAssertEqual(ClaudeUsageReader.shortModel("claude-opus-5-1"), "opus 5.1")
    }

    /// A release date is not a version component.
    func testATrailingDateIsNotReadAsAVersion() {
        XCTAssertEqual(ClaudeUsageReader.modelVersionLabel("claude-sonnet-4-5-20250929"), "4.5")
        XCTAssertEqual(ClaudeUsageReader.modelVersionLabel("claude-haiku-4-5-20251001"), "4.5")
        XCTAssertEqual(ClaudeUsageReader.modelVersionLabel("claude-opus-4-1-20250805"), "4.1")
    }

    /// Older ids put the version before the family name.
    func testTheOlderIdLayoutStillParses() {
        XCTAssertEqual(ClaudeUsageReader.modelVersionLabel("claude-3-5-sonnet-20241022"), "3.5")
        XCTAssertEqual(ClaudeUsageReader.shortModel("claude-3-5-sonnet-20241022"), "sonnet 3.5")
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

/// The notch's per-session cost meter must agree with the 7-day project total,
/// which means subagent (isSidechain) turns have to count — they're real spend.
/// A regression here silently undercounts every session that used a Task agent.
final class ClaudeUsageReaderSessionMeterTests: XCTestCase {

    private func writeTranscript(_ lines: [String]) -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cnt-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("session.jsonl").path
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func assistant(input: Int, output: Int, sidechain: Bool, model: String = "claude-opus-4-8") -> String {
        let side = sidechain ? ",\"isSidechain\":true" : ""
        return "{\"message\":{\"role\":\"assistant\",\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}\(side)}"
    }

    func testSubagentTurnsCountTowardSessionCost() {
        let mainOnly = writeTranscript([assistant(input: 1000, output: 500, sidechain: false)])
        let withAgent = writeTranscript([
            assistant(input: 1000, output: 500, sidechain: false),
            assistant(input: 2000, output: 800, sidechain: true),   // a Task subagent turn
        ])
        let a = ClaudeUsageReader.sessionMeter(transcriptPath: mainOnly)
        let b = ClaudeUsageReader.sessionMeter(transcriptPath: withAgent)
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        // The subagent turn is extra spend, so the total must be strictly higher.
        XCTAssertGreaterThan(b!.costUSD, a!.costUSD)
    }

    func testContextReadingIgnoresSubagentTurns() {
        // A subagent runs in its own small, fresh context. If it arrives after
        // the main turn, it must NOT become the live occupancy reading.
        let path = writeTranscript([
            assistant(input: 150_000, output: 500, sidechain: false),   // main: big context
            assistant(input: 3_000, output: 200, sidechain: true),      // subagent: tiny
        ])
        let m = ClaudeUsageReader.sessionMeter(transcriptPath: path)
        XCTAssertEqual(m?.contextTokens, 150_000, "occupancy comes from the main thread, not the subagent")
    }

    /// One API response, written out as three lines (thinking, text, tool_use),
    /// each repeating the same id and the same usage — exactly what Claude Code
    /// writes for a turn that thinks, talks and then calls a tool.
    private func blocks(id: String, input: Int, output: Int) -> [String] {
        (0..<3).map { _ in
            "{\"message\":{\"id\":\"\(id)\",\"role\":\"assistant\",\"model\":\"claude-opus-4-8\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}}"
        }
    }

    func testATurnIsChargedOncePerMessageNotOncePerLine() {
        let oneLine = writeTranscript([blocks(id: "msg_a", input: 1000, output: 500)[0]])
        let threeLines = writeTranscript(blocks(id: "msg_a", input: 1000, output: 500))
        let a = ClaudeUsageReader.sessionMeter(transcriptPath: oneLine)
        let b = ClaudeUsageReader.sessionMeter(transcriptPath: threeLines)
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        // Same turn, same spend — whether it arrived as one block or three.
        XCTAssertEqual(b!.costUSD, a!.costUSD, accuracy: 1e-9,
                       "repeated lines for one message must not be billed again")
    }

    func testDistinctMessagesStillBothCount() {
        // The dedupe is by message id, so two genuinely different turns must add up.
        let path = writeTranscript(blocks(id: "msg_a", input: 1000, output: 500)
                                   + blocks(id: "msg_b", input: 1000, output: 500))
        let one = writeTranscript(blocks(id: "msg_a", input: 1000, output: 500))
        let two = ClaudeUsageReader.sessionMeter(transcriptPath: path)!
        let single = ClaudeUsageReader.sessionMeter(transcriptPath: one)!
        XCTAssertEqual(two.costUSD, single.costUSD * 2, accuracy: 1e-9)
    }

    func testLinesWithoutAnIdAreStillCounted() {
        // Old transcripts have no message id. They can't be deduped, and dropping
        // them would be worse than the double count they might carry.
        let path = writeTranscript([
            assistant(input: 1000, output: 500, sidechain: false),
            assistant(input: 1000, output: 500, sidechain: false),
        ])
        let one = writeTranscript([assistant(input: 1000, output: 500, sidechain: false)])
        let both = ClaudeUsageReader.sessionMeter(transcriptPath: path)!
        let single = ClaudeUsageReader.sessionMeter(transcriptPath: one)!
        XCTAssertEqual(both.costUSD, single.costUSD * 2, accuracy: 1e-9)
    }
}

/// The window Claude Code reports beats anything the app infers. Inference is
/// the fallback for the first frames of a session, before a status line lands.
final class ReportedContextWindowTests: XCTestCase {

    func testReportedWindowWinsOverInference() {
        // The model rule would say 200k here; Claude Code says otherwise, and
        // Claude Code is the one running the model.
        let w = AppState.windowFor(model: "claude-haiku-4-5", reported: 1_000_000,
                                   learned: [:], tokens: 10, mode: .auto)
        XCTAssertEqual(w, 1_000_000)
    }

    func testLearnedWindowUsedBeforeThisSessionReportsOne() {
        // A fresh session on a model we have seen before starts with the truth
        // instead of guessing until its first status line arrives.
        let w = AppState.windowFor(model: "claude-opus-4-8", reported: 0,
                                   learned: ["claude-opus-4-8": 1_000_000],
                                   tokens: 10, mode: .auto)
        XCTAssertEqual(w, 1_000_000)
    }

    func testInferenceIsTheFallback() {
        let w = AppState.windowFor(model: "claude-haiku-4-5", reported: 0, learned: [:],
                                   tokens: 10, mode: .auto)
        XCTAssertEqual(w, ClaudeUsageReader.contextWindow)
    }

    func testAnExplicitModeOverridesEverything() {
        // The user forcing 200k means 200k, whatever Claude Code reported.
        let w = AppState.windowFor(model: "claude-opus-4-8", reported: 1_000_000,
                                   learned: [:], tokens: 10, mode: .w200k)
        XCTAssertEqual(w, ClaudeUsageReader.contextWindow)
    }
}

/// Labels shorten from the middle rather than being crushed by the layout — a
/// branch called "main" was being drawn as "m".
final class ElideTests: XCTestCase {

    func testShortNamesAreLeftAlone() {
        XCTAssertEqual(NotchView.elide("main", to: 18), "main")
        XCTAssertEqual(NotchView.elide("feature/pet", to: 18), "feature/pet")
    }

    func testLongNamesKeepBothEnds() {
        let out = NotchView.elide("feature/really-long-branch-name", to: 18)
        XCTAssertEqual(out.count, 18)
        XCTAssertTrue(out.hasPrefix("feature"), "the start says which branch it is")
        XCTAssertTrue(out.hasSuffix("name"), "the end distinguishes siblings")
        XCTAssertTrue(out.contains("…"))
    }
}

/// The reset countdown. A percentage tells you that you are in trouble; this
/// tells you whether you can wait it out, so its wording has to be unambiguous
/// at a glance.
final class ResetCountdownTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func inSeconds(_ s: Double) -> Date { now.addingTimeInterval(s) }

    func testMinutes() {
        XCTAssertEqual(ClaudeUsageReader.resetCountdown(until: inSeconds(60 * 42), now: now), "42m")
        XCTAssertEqual(ClaudeUsageReader.resetCountdown(until: inSeconds(90), now: now), "2m")   // rounds up
    }

    func testHoursAndMinutes() {
        XCTAssertEqual(ClaudeUsageReader.resetCountdown(until: inSeconds(3600 + 60 * 12), now: now), "1h 12m")
        XCTAssertEqual(ClaudeUsageReader.resetCountdown(until: inSeconds(3600 * 2), now: now), "2h")
    }

    func testDays() {
        XCTAssertEqual(ClaudeUsageReader.resetCountdown(until: inSeconds(3600 * 26), now: now), "1d 2h")
        XCTAssertEqual(ClaudeUsageReader.resetCountdown(until: inSeconds(3600 * 48), now: now), "2d")
    }

    func testAlreadyPast() {
        // A stale reset instant must not render as a negative countdown.
        XCTAssertEqual(ClaudeUsageReader.resetCountdown(until: inSeconds(-5), now: now), "now")
        XCTAssertEqual(ClaudeUsageReader.resetCountdown(until: now, now: now), "now")
    }
}

/// How old a reading is. A separate job from the reset countdown, and the two
/// round in opposite directions: a window resetting in 61 seconds must not read
/// "1m" while you wait on it, but a reading taken an hour ago is "1h old", not
/// "1h 1m old". Sharing one function between them is what shipped the latter.
final class AgeDescriptionTests: XCTestCase {

    func testAgeRoundsDown() {
        XCTAssertEqual(ClaudeUsageReader.ageDescription(seconds: 3600), "1h")
        XCTAssertEqual(ClaudeUsageReader.ageDescription(seconds: 3599), "59m")
        XCTAssertEqual(ClaudeUsageReader.ageDescription(seconds: 3660), "1h 1m")
    }

    func testCountdownRoundsUp() {
        let now = Date()
        XCTAssertEqual(ClaudeUsageReader.resetCountdown(until: now.addingTimeInterval(90), now: now), "2m")
    }

    func testFreshIsJustNow() {
        XCTAssertEqual(ClaudeUsageReader.ageDescription(seconds: 30), "just now")
    }

    func testDays() {
        XCTAssertEqual(ClaudeUsageReader.ageDescription(seconds: 3600 * 26), "1d 2h")
        XCTAssertEqual(ClaudeUsageReader.ageDescription(seconds: 3600 * 48), "2d")
    }
}
