import XCTest
@testable import ClaudeNotch

/// Codex publishes no token pricing, so a Codex session is budgeted in the one
/// unit that can be measured rather than guessed. These cover the pieces that
/// decide when work is blocked and what the card then says.
final class CodexTokenBudgetTests: XCTestCase {

    // MARK: - Raising the cap

    /// The dollar presets top out at 500, which a single Codex turn can pass in
    /// tokens, so the raise button needs steps of its own or it offers a cap
    /// that is already spent.
    func testTokenCapsRiseInTokenSizedSteps() {
        XCTAssertEqual(AppState.nextTokenCap(covering: 120_000, current: 100_000), 250_000)
        XCTAssertEqual(AppState.nextTokenCap(covering: 600_000, current: 500_000), 1_000_000)
    }

    /// Past the presets it keeps going rather than handing back a cap below
    /// what has already been used, which would re-block the next call.
    func testBeyondThePresetsItStillClears() {
        let next = AppState.nextTokenCap(covering: 12_000_000, current: 10_000_000)
        XCTAssertGreaterThan(next, 12_000_000)
    }

    /// The new cap must clear BOTH the spend and the old cap. Clearing only the
    /// spend would leave a cap that blocks again immediately.
    func testRaisedCapAlwaysClearsSpendAndCap() {
        for (used, cap) in [(50_000.0, 1_000_000.0), (999_999.0, 100_000.0), (7_000_000.0, 250_000.0)] {
            let next = AppState.nextTokenCap(covering: used, current: cap)
            XCTAssertGreaterThan(next, used, "cap \(next) must clear spend \(used)")
            XCTAssertGreaterThan(next, cap, "cap \(next) must clear old cap \(cap)")
        }
    }

    /// A block carries its unit, so the same button routes to the right cap.
    func testRaisedCapFollowsTheBlocksUnit() {
        let tokens = BudgetBlock(scope: "session", cost: 120_000, cap: 100_000, unit: .tokens)
        let usd = BudgetBlock(scope: "session", cost: 12, cap: 10, unit: .usd)
        XCTAssertEqual(AppState.raisedCap(for: tokens), 250_000)
        XCTAssertEqual(AppState.raisedCap(for: usd), 25)
    }

    // MARK: - What the card says

    /// A token block that formatted itself as money would read as a bill for
    /// hundreds of thousands of dollars.
    func testTokenBlocksReadAsTokens() {
        let b = BudgetBlock(scope: "daily", cost: 1_250_000, cap: 1_000_000, unit: .tokens)
        XCTAssertEqual(b.amount(b.cost), "1.2M tokens")
        XCTAssertEqual(b.amount(b.cap), "1.0M tokens")
        XCTAssertEqual(b.pct, 125)
    }

    func testDollarBlocksAreUnchanged() {
        let b = BudgetBlock(scope: "daily", cost: 12.5, cap: 10)
        XCTAssertEqual(b.unit, .usd)                    // the default, so old call sites keep working
        XCTAssertEqual(b.amount(b.cost), ClaudeUsageReader.fmtMoney(12.5))
    }

    func testTokenFormatting() {
        XCTAssertEqual(BudgetBlock.tokens(900), "900")
        XCTAssertEqual(BudgetBlock.tokens(1_500), "1.5K")
        XCTAssertEqual(BudgetBlock.tokens(2_400_000), "2.4M")
        XCTAssertEqual(BudgetBlock.tokens(0), "0")
    }

    // MARK: - Blocking

    /// A cap of 0 is off, and must never block however much has been used.
    @MainActor
    func testZeroCapNeverBlocks() {
        let s = AppState()
        s.codexTodayTokens = 9_000_000
        s.codexDailyTokenCap = 0
        s.codexSessionTokenCap = 0
        XCTAssertNil(s.codexTokenBlock(forCwd: "/tmp/p"))
    }

    @MainActor
    func testDailyTokenCapBlocksAtTheCap() {
        let s = AppState()
        s.codexDailyTokenCap = 1_000_000
        s.codexTodayTokens = 1_000_000          // exactly at the cap counts as over
        let block = s.codexTokenBlock(forCwd: "/tmp/p")
        XCTAssertEqual(block?.scope, "daily")
        XCTAssertEqual(block?.unit, .tokens)
        XCTAssertEqual(block?.cost, 1_000_000)
    }

    @MainActor
    func testUnderTheCapDoesNotBlock() {
        let s = AppState()
        s.codexDailyTokenCap = 1_000_000
        s.codexTodayTokens = 999_999
        XCTAssertNil(s.codexTokenBlock(forCwd: "/tmp/p"))
    }

    /// Build a live session the way the app does, so the test cannot drift
    /// from the real shape as LiveSession gains fields.
    @MainActor
    private func addSession(_ s: AppState, id: String, cwd: String, tokens: Int) {
        s.upsertSession(id: id, cwd: cwd, create: true) { $0.totalTokens = tokens }
    }

    /// Trailing slashes are two spellings of one directory. Treating them as
    /// two projects would hide a session's usage from its own cap.
    @MainActor
    func testSessionLookupIgnoresATrailingSlash() {
        let s = AppState()
        s.codexSessionTokenCap = 100_000
        addSession(s, id: "a", cwd: "/tmp/proj", tokens: 150_000)
        XCTAssertEqual(s.codexSessionTokens(forCwd: "/tmp/proj/"), 150_000)
        XCTAssertEqual(s.codexTokenBlock(forCwd: "/tmp/proj/")?.scope, "session")
    }

    /// Two sessions in one folder: the one that has burned the most is the one
    /// the cap is about.
    @MainActor
    func testBusiestSessionInTheFolderWins() {
        let s = AppState()
        addSession(s, id: "a", cwd: "/tmp/proj", tokens: 10_000)
        addSession(s, id: "b", cwd: "/tmp/proj", tokens: 80_000)
        addSession(s, id: "c", cwd: "/other", tokens: 999_999)
        XCTAssertEqual(s.codexSessionTokens(forCwd: "/tmp/proj"), 80_000)
    }

    /// The token total only ever goes up. A stale rollout read reporting less
    /// than we already saw must not walk a session back under its cap.
    @MainActor
    func testSessionTokensNeverGoBackwards() {
        let s = AppState()
        addSession(s, id: "a", cwd: "/tmp/proj", tokens: 0)
        s.noteCodexUsage(sessionId: "a", cwd: "/tmp/proj", contextTokens: 10,
                         contextWindow: 100, model: "gpt-5", totalTokens: 90_000)
        s.noteCodexUsage(sessionId: "a", cwd: "/tmp/proj", contextTokens: 10,
                         contextWindow: 100, model: "gpt-5", totalTokens: 12_000)
        XCTAssertEqual(s.codexSessionTokens(forCwd: "/tmp/proj"), 90_000)
    }

    @MainActor
    func testNormalizedCwd() {
        XCTAssertEqual(AppState.normalizedCwd("/a/b/"), "/a/b")
        XCTAssertEqual(AppState.normalizedCwd("/a/b///"), "/a/b")
        XCTAssertEqual(AppState.normalizedCwd("/a/b"), "/a/b")
        XCTAssertEqual(AppState.normalizedCwd("/"), "/")     // root keeps its slash
    }
}
