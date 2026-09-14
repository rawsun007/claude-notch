import XCTest
@testable import ClaudeNotch

/// The rules that decide whether the notch says anything about a session's
/// prompt cache. Getting these wrong in either direction is bad in a specific
/// way: too eager and it warns through ordinary work until people stop reading
/// it, too shy and it stays quiet through exactly the idle stretch it exists to
/// catch.
final class PromptCacheStateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ offset: TimeInterval) -> Date { now.addingTimeInterval(offset) }

    // MARK: - Nothing reported

    /// Every session is in this state until its first API response, so it has
    /// to be silent rather than reassuring.
    func testAnUnreportedCacheSaysNothing() {
        let s = PromptCacheState()
        XCTAssertTrue(s.isUnknown)
        XCTAssertFalse(s.isCold(now: now))
        XCTAssertFalse(s.isExpiringSoon(now: now))
        XCTAssertFalse(s.isWorthReporting(now: now))
    }

    /// nil and false are different answers and must not collapse. This is the
    /// same distinction the jq forwarder had to be fixed for.
    func testUnknownIsNotTheSameAsCold() {
        XCTAssertFalse(PromptCacheState(warm: nil).isCold(now: now))
        XCTAssertTrue(PromptCacheState(warm: false).isCold(now: now))
    }

    // MARK: - Cold

    func testTheCliSayingColdIsEnough() {
        let s = PromptCacheState(warm: false, recacheTokens: 45_000)
        XCTAssertTrue(s.isCold(now: now))
        XCTAssertTrue(s.isWorthReporting(now: now))
    }

    /// The status line only redraws while something is happening, so a session
    /// left alone goes cold with nothing reporting it. The last known expiry is
    /// the only evidence there will be, and it has to count.
    func testAPassedExpiryCountsAsColdEvenIfTheLastReportSaidWarm() {
        let s = PromptCacheState(warm: true, expiresAt: at(-1), recacheTokens: 45_000)
        XCTAssertTrue(s.isCold(now: now))
        XCTAssertEqual(s.secondsUntilExpiry(now: now), 0, "the countdown floors rather than going negative")
    }

    // MARK: - About to go cold

    func testWarmWithSecondsLeftIsExpiringSoon() {
        let s = PromptCacheState(warm: true, expiresAt: at(60), recacheTokens: 45_000)
        XCTAssertTrue(s.isExpiringSoon(now: now))
        XCTAssertFalse(s.isCold(now: now))
        XCTAssertTrue(s.isWorthReporting(now: now))
    }

    /// Comfortably warm is the normal state of a session being worked in, and
    /// must stay silent or the badge is lit permanently.
    func testAComfortablyWarmCacheSaysNothing() {
        let s = PromptCacheState(warm: true, expiresAt: at(3_000), recacheTokens: 45_000)
        XCTAssertFalse(s.isExpiringSoon(now: now))
        XCTAssertFalse(s.isCold(now: now))
        XCTAssertFalse(s.isWorthReporting(now: now))
    }

    /// Once it has gone it is cold, not expiring. The two states must not both
    /// be true, or the UI has to pick and will pick wrong.
    func testColdAndExpiringAreMutuallyExclusive() {
        let s = PromptCacheState(warm: true, expiresAt: at(-30), recacheTokens: 1)
        XCTAssertTrue(s.isCold(now: now))
        XCTAssertFalse(s.isExpiringSoon(now: now))
    }

    func testTheWarningWindowIsShortEnoughNotToNag() {
        XCTAssertLessThanOrEqual(PromptCacheState.expiringSoonWindow, 180)
        XCTAssertGreaterThan(PromptCacheState.expiringSoonWindow, 0)
    }

    // MARK: - Worth reporting

    /// A warning with no number attached says "this will cost something"
    /// without saying how much, which is the kind people learn to ignore.
    func testColdWithNoRebuildCostIsNotReported() {
        let s = PromptCacheState(warm: false, recacheTokens: nil)
        XCTAssertTrue(s.isCold(now: now))
        XCTAssertFalse(s.isWorthReporting(now: now), "nothing to tell the user it would cost")

        let zero = PromptCacheState(warm: false, recacheTokens: 0)
        XCTAssertFalse(zero.isWorthReporting(now: now))
    }

    /// A hit ratio alone is interesting but not actionable, so it does not
    /// raise the badge by itself.
    func testAHitRatioAloneDoesNotRaiseTheBadge() {
        let s = PromptCacheState(warm: true, expiresAt: at(3_000), hitRatio: 0.2)
        XCTAssertFalse(s.isWorthReporting(now: now))
    }
}

/// The countdown on the badge. Short because the decision it supports is
/// "type now or not", which is a seconds-scale question.
@MainActor
final class PromptCacheBadgeTests: XCTestCase {
    func testSecondsBelowTwoMinutes() {
        XCTAssertEqual(SessionsList.shortCountdown(9), "9s")
        XCTAssertEqual(SessionsList.shortCountdown(119), "119s")
    }

    func testMinutesAboveThat() {
        XCTAssertEqual(SessionsList.shortCountdown(120), "2m")
        XCTAssertEqual(SessionsList.shortCountdown(605), "10m")
    }

    func testZeroIsNotNegative() {
        XCTAssertEqual(SessionsList.shortCountdown(0), "0s")
    }
}
