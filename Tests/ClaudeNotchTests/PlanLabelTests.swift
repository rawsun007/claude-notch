import XCTest
@testable import ClaudeNotch

/// The menu-bar readout has about fifteen characters to answer "how much have I
/// got left", and the credit card fires when money starts. Both are decided by
/// pure functions so they can be tested without a plan or a billing period.
final class PlanLabelTests: XCTestCase {

    private func limit(_ kind: String, _ pct: Double) -> PlanReader.Limit {
        PlanReader.Limit(kind: kind, label: PlanReader.limitName(kind), percent: pct,
                         severity: "normal", resetsAt: nil, isActive: true)
    }

    private func snapshot(tier: String?, _ limits: [PlanReader.Limit]) -> PlanReader.Snapshot {
        PlanReader.Snapshot(
            account: tier.map { PlanReader.Account(tier: $0, rawTier: "claude_\($0.lowercased())") },
            limits: limits, credits: nil, fetchedAt: nil)
    }

    func testLabelNamesThePlanAndTheTightestLimit() {
        let s = snapshot(tier: "Pro", [limit("session", 7), limit("weekly_all", 13)])
        XCTAssertEqual(AppState.planLabel(s), "Pro · WK 13%")
    }

    /// The point of the readout is the limit closest to stopping you, which is
    /// not always the weekly one.
    func testTightestWins() {
        let s = snapshot(tier: "Max", [limit("session", 91), limit("weekly_all", 13), limit("weekly_opus", 44)])
        XCTAssertEqual(AppState.planLabel(s), "Max · 5H 91%")
    }

    func testOpusGetsItsOwnLabelOnAMaxPlan() {
        let s = snapshot(tier: "Max 20x", [limit("weekly_all", 20), limit("weekly_opus", 80)])
        XCTAssertEqual(AppState.planLabel(s), "Max 20x · OPUS 80%")
    }

    func testPercentagesAreRoundedNotTruncated() {
        XCTAssertEqual(AppState.planLabel(snapshot(tier: "Pro", [limit("session", 7.6)])), "Pro · 5H 8%")
    }

    /// Half a reading is still worth the width: a plan with no limits yet reads
    /// as the plan, and limits with no plan read as the limits.
    func testPartialReadings() {
        XCTAssertEqual(AppState.planLabel(snapshot(tier: "Pro", [])), "Pro")
        XCTAssertEqual(AppState.planLabel(snapshot(tier: nil, [limit("session", 5)])), "5H 5%")
        XCTAssertNil(AppState.planLabel(snapshot(tier: nil, [])))
        XCTAssertNil(AppState.planLabel(nil))
    }

    /// A window this app has never heard of still has to render as something.
    func testUnknownLimitKindIsInitialled() {
        XCTAssertEqual(AppState.shortLimitLabel("monthly_haiku"), "MH")
        XCTAssertEqual(AppState.shortLimitLabel("session"), "5H")
    }

    // MARK: - Credits engaging

    private func credits(enabled: Bool, spent: Double?) -> PlanReader.Credits {
        PlanReader.Credits(isEnabled: enabled, everEnabled: true, userDisabled: false,
                           spendLimitReached: false, canPurchase: true, disabledReason: nil,
                           usedCredits: nil, monthlyLimit: nil, utilization: nil, currency: "USD",
                           spent: spent, spendLimit: nil, balance: nil, autoReload: nil)
    }

    func testFiresWhenSpendFirstAppears() {
        XCTAssertTrue(AppState.creditsJustEngaged(from: credits(enabled: true, spent: 0),
                                                  to: credits(enabled: true, spent: 0.42)))
    }

    /// Every later refresh reports a bigger number. A card per refresh would
    /// bury the one that matters.
    func testDoesNotFireAgainAsSpendGrows() {
        XCTAssertFalse(AppState.creditsJustEngaged(from: credits(enabled: true, spent: 0.42),
                                                   to: credits(enabled: true, spent: 3.10)))
    }

    /// Back to zero is a new billing period, so the next spend is news again.
    func testFiresAgainInANewPeriod() {
        XCTAssertTrue(AppState.creditsJustEngaged(from: credits(enabled: true, spent: 0),
                                                  to: credits(enabled: true, spent: 0.05)))
    }

    /// Launching into a period that is already running is not an event. Without
    /// this, every start of the app would announce spend that happened days ago.
    func testNoPreviousReadingIsNotAnEvent() {
        XCTAssertFalse(AppState.creditsJustEngaged(from: nil, to: credits(enabled: true, spent: 9)))
    }

    func testSilentWhenCreditsAreOff() {
        XCTAssertFalse(AppState.creditsJustEngaged(from: credits(enabled: false, spent: 0),
                                                   to: credits(enabled: false, spent: 5)))
        XCTAssertFalse(AppState.creditsJustEngaged(from: credits(enabled: true, spent: 0),
                                                   to: nil))
    }

    /// Some accounts report used_credits and no spend block.
    func testFallsBackToUsedCredits() {
        var before = credits(enabled: true, spent: nil); before.usedCredits = 0
        var after = credits(enabled: true, spent: nil); after.usedCredits = 2
        XCTAssertTrue(AppState.creditsJustEngaged(from: before, to: after))
    }
}

/// The status bar has two slots. A credits slot that reads $0.00 for ever is
/// one of them wasted, so it only appears while credits are actually on.
extension PlanLabelTests {

    func testCreditsSlotOnlyAppearsWhileCreditsAreOn() {
        let picked: [StatusBarItem] = [.fiveHourLimit, .credits]
        XCTAssertEqual(AppState.visibleStatusItems(picked, creditsOn: true), [.fiveHourLimit, .credits])
        XCTAssertEqual(AppState.visibleStatusItems(picked, creditsOn: false), [.fiveHourLimit])
    }

    func testEveryOtherSlotIsUnaffected() {
        let picked: [StatusBarItem] = [.weeklyLimit, .sessionCost]
        XCTAssertEqual(AppState.visibleStatusItems(picked, creditsOn: false), picked)
        XCTAssertEqual(AppState.visibleStatusItems([], creditsOn: true), [])
    }
}

/// Claude Code never reports a rate-limit percentage for an ANTHROPIC_API_KEY
/// session, so silence plus a missing account is the only signal there is.
/// Each condition alone just means "too soon" — all three have to hold.
extension PlanLabelTests {

    func testApiKeyBillingNeedsSeveralSilentUpdates() {
        XCTAssertFalse(AppState.isApiKeyBilling(statusLineUpdateCount: 0, everSawPlanLimitData: false, hasAccount: false))
        XCTAssertFalse(AppState.isApiKeyBilling(statusLineUpdateCount: 1, everSawPlanLimitData: false, hasAccount: false))
        XCTAssertTrue(AppState.isApiKeyBilling(statusLineUpdateCount: 2, everSawPlanLimitData: false, hasAccount: false))
    }

    func testApiKeyBillingIsFalseOnceALimitHasEverArrived() {
        XCTAssertFalse(AppState.isApiKeyBilling(statusLineUpdateCount: 10, everSawPlanLimitData: true, hasAccount: false))
    }

    func testApiKeyBillingIsFalseWhenAnAccountExists() {
        // A subscription account with limits temporarily silent (e.g. the
        // status line just restarted) must not be misread as API-key billing.
        XCTAssertFalse(AppState.isApiKeyBilling(statusLineUpdateCount: 10, everSawPlanLimitData: false, hasAccount: true))
    }

    /// The menu bar falls back to naming the billing mode instead of showing
    /// nothing once API-key billing is confirmed.
    @MainActor
    func testMenuBarLabelFallsBackToApiKeyWhenNoPlanExists() {
        let s = AppState()
        s.statusLineUpdateCount = 3
        s.everSawPlanLimitData = false
        s.plan = nil
        XCTAssertEqual(s.menuBarPlanLabel, "API key")
    }

    @MainActor
    func testMenuBarLabelStaysNilBeforeApiKeyBillingIsConfirmed() {
        let s = AppState()
        s.statusLineUpdateCount = 0
        s.plan = nil
        XCTAssertNil(s.menuBarPlanLabel)
    }
}
