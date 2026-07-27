import XCTest
@testable import ClaudeNotch

/// Projecting when a usage limit runs out.
///
/// The failure that matters is a confident wrong number. Telling someone they
/// have forty minutes when they have five is worse than saying nothing, so most
/// of these pin down the cases where it must refuse to guess.
final class BurnRateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func sample(_ percent: Double, _ minutes: Double) -> BurnRate.Sample {
        .init(percent: percent, at: t0.addingTimeInterval(minutes * 60))
    }

    // MARK: - Projecting

    func testASteadyBurnProjectsTheRemainder() {
        // Half the window in an hour, so an hour left.
        let f = BurnRate.project(from: sample(0, 0), to: sample(0.5, 60))
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.secondsRemaining ?? 0, 3600, accuracy: 1)
    }

    func testFlatUsageProjectsNothing() {
        XCTAssertNil(BurnRate.project(from: sample(0.4, 0), to: sample(0.4, 60)))
    }

    /// Percentage falling means the window rolled over between readings, not
    /// that usage is being given back.
    func testFallingUsageProjectsNothing() {
        XCTAssertNil(BurnRate.project(from: sample(0.9, 0), to: sample(0.1, 60)))
    }

    /// Whole-number percentages ten seconds apart give a rate with enormous
    /// error bars, and extrapolating that to hours is how you promise someone
    /// time they do not have.
    func testSamplesTooCloseTogetherProjectNothing() {
        XCTAssertNil(BurnRate.project(from: sample(0.1, 0), to: sample(0.2, 10.0 / 60)))
    }

    func testAlreadyAtTheCapProjectsNothing() {
        XCTAssertNil(BurnRate.project(from: sample(0.5, 0), to: sample(1.0, 60)))
    }

    // MARK: - The window resetting first

    func testAWindowThatResetsFirstIsFlagged() {
        let f = BurnRate.project(from: sample(0, 0), to: sample(0.5, 60),
                                 resetAt: t0.addingTimeInterval(70 * 60))
        XCTAssertEqual(f?.resetsFirst, true)
    }

    func testAWindowThatOutlastsTheBurnIsNotFlagged() {
        let f = BurnRate.project(from: sample(0, 0), to: sample(0.5, 60),
                                 resetAt: t0.addingTimeInterval(600 * 60))
        XCTAssertEqual(f?.resetsFirst, false)
    }

    // MARK: - Whether to say anything

    func testNothingIsSaidWhenTheWindowResetsFirst() {
        let f = BurnRate.project(from: sample(0, 0), to: sample(0.5, 60),
                                 resetAt: t0.addingTimeInterval(70 * 60))
        XCTAssertNil(BurnRate.warning(f, limitName: "5-hour limit"))
    }

    func testNothingIsSaidWhenTheCapIsHoursAway() {
        let f = BurnRate.project(from: sample(0, 0), to: sample(0.5, 60),
                                 resetAt: t0.addingTimeInterval(600 * 60))
        XCTAssertNil(BurnRate.warning(f, limitName: "5-hour limit"))
    }

    func testAWarningIsGivenWhenTheCapIsClose() {
        let f = BurnRate.project(from: sample(0, 0), to: sample(0.9, 60))
        let text = BurnRate.warning(f, limitName: "5-hour limit")
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("5-hour limit") ?? false)
    }

    func testNoForecastMeansNoWarning() {
        XCTAssertNil(BurnRate.warning(nil, limitName: "5-hour limit"))
    }

    // MARK: - Wording

    /// The projection is not precise enough to justify "in 37 minutes".
    func testDurationsAreRoundedTheWayACountdownIsRead() {
        XCTAssertEqual(BurnRate.humanDuration(30), "under a minute")
        XCTAssertEqual(BurnRate.humanDuration(7 * 60), "7 min")
        XCTAssertEqual(BurnRate.humanDuration(37 * 60), "35 min")
        XCTAssertEqual(BurnRate.humanDuration(70 * 60), "about an hour")
        XCTAssertEqual(BurnRate.humanDuration(3 * 3600), "about 3 hours")
    }
}
