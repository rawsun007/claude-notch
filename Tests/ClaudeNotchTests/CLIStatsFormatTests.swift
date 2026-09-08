import XCTest
@testable import ClaudeNotch

/// Formatting for Claude Code's lifetime figures. Small functions, but they run
/// on numbers with eleven digits and durations measured in weeks, which is
/// where a plain formatter produces something unreadable.
@MainActor
final class CLIStatsFormatTests: XCTestCase {

    /// Lifetime token counts reach billions, and at that size the low digits
    /// carry no information.
    func testTokensAreCompactedByMagnitude() {
        XCTAssertEqual(SettingsView.compactTokens(11_513_402_118), "11.51b")
        XCTAssertEqual(SettingsView.compactTokens(37_600_000), "37.6m")
        XCTAssertEqual(SettingsView.compactTokens(1_200), "1.2k")
        XCTAssertEqual(SettingsView.compactTokens(999), "999")
        XCTAssertEqual(SettingsView.compactTokens(0), "0")
    }

    /// The real longest session on this machine is 26 days, which is why the
    /// duration format has to carry days at all.
    func testDurationsCarryDaysWhenTheyNeedTo() {
        XCTAssertEqual(SettingsView.compactDuration(seconds: 2_265_008), "26d 5h 10m")
    }

    /// And must not read as "0d 0h 9m" for a short one.
    func testZeroPartsAreDropped() {
        XCTAssertEqual(SettingsView.compactDuration(seconds: 540), "9m")
        XCTAssertEqual(SettingsView.compactDuration(seconds: 3_600), "1h")
        XCTAssertEqual(SettingsView.compactDuration(seconds: 86_400), "1d")
        XCTAssertEqual(SettingsView.compactDuration(seconds: 0), "0m")
    }

    /// A model id shortens to its family and version. An id from a family we do
    /// not know is shown as itself rather than blanked, the same rule the model
    /// switch card follows.
    func testModelLabels() {
        XCTAssertEqual(SettingsView.statsModelLabel("claude-opus-5"), "Opus 5")
        XCTAssertEqual(SettingsView.statsModelLabel("claude-sonnet-4-6"), "Sonnet 4.6")
        XCTAssertEqual(SettingsView.statsModelLabel("some-future-model"), "some-future-model")
    }

    /// An unparseable date is shown raw rather than dropped: a wrong-looking
    /// date is a bug report, a missing one is a mystery.
    func testFriendlyDayFallsBackToTheRawString() {
        XCTAssertEqual(SettingsView.friendlyDay("not-a-date"), "not-a-date")
        XCTAssertFalse(SettingsView.friendlyDay("2026-05-17").isEmpty)
    }
}
