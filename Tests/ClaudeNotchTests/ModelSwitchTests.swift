import XCTest
@testable import ClaudeNotch

/// The `PostModelSwitch` hook (Claude Code 2.1.251+) reports that a session
/// changed model mid-run. What the notch does with it is show one line, so the
/// only logic worth pinning down is the line itself: which model ids it can
/// render, and what it does with the ones it cannot.
final class ModelSwitchTests: XCTestCase {

    func testReadsAsAMoveBetweenTwoModels() {
        XCTAssertEqual(
            AppState.modelSwitchDetail(from: "claude-opus-4-8", to: "claude-sonnet-4-6"),
            "opus 4.8 to sonnet 4.6")
    }

    /// An id from a model family we do not know about is shown as itself. The
    /// alternative, dropping it, would render "switched to " with a blank where
    /// the answer goes, and the first new model family Anthropic ships would
    /// turn every switch card into a puzzle.
    func testUnknownModelIdsAreShownVerbatim() {
        let detail = AppState.modelSwitchDetail(from: "claude-opus-5", to: "some-future-model")
        XCTAssertEqual(detail, "opus 5 to some-future-model")
    }

    /// The CLI does not always know what it switched away from.
    func testMissingSourceModelStillNamesTheDestination() {
        XCTAssertEqual(AppState.modelSwitchDetail(from: "", to: "claude-opus-5"), "opus 5")
    }

    /// Both sides unknown is not a case worth special-casing, but it must not
    /// produce something that reads as a bug.
    func testBothSidesUnknownStillReadsAsAMove() {
        XCTAssertEqual(AppState.modelSwitchDetail(from: "mystery-a", to: "mystery-b"),
                       "mystery-a to mystery-b")
    }

    /// The dedupe window is short on purpose: a switch and an immediate switch
    /// back is real news, not a duplicate. This pins the intent so the constant
    /// is not quietly raised to something that would swallow it.
    func testDedupeWindowStaysShortEnoughToShowASwitchBack() {
        XCTAssertLessThanOrEqual(AppState.modelSwitchCardGrace, 10)
        XCTAssertGreaterThan(AppState.modelSwitchCardGrace, 0)
    }

    // MARK: - Which switches count as an upgrade

    func testMovingToAMoreExpensiveFamilyIsAnUpgrade() {
        XCTAssertTrue(AppState.modelSwitchIsUpgrade(from: "claude-haiku-4-5", to: "claude-sonnet-4-6"))
        XCTAssertTrue(AppState.modelSwitchIsUpgrade(from: "claude-sonnet-4-6", to: "claude-opus-5"))
        XCTAssertTrue(AppState.modelSwitchIsUpgrade(from: "claude-haiku-4-5", to: "claude-opus-5"))
    }

    func testMovingDownOrSidewaysIsNot() {
        XCTAssertFalse(AppState.modelSwitchIsUpgrade(from: "claude-opus-5", to: "claude-sonnet-4-6"))
        XCTAssertFalse(AppState.modelSwitchIsUpgrade(from: "claude-opus-5", to: "claude-haiku-4-5"))
        XCTAssertFalse(AppState.modelSwitchIsUpgrade(from: "claude-opus-5", to: "claude-opus-5"))
    }

    /// A version bump inside one family is not an upgrade in the sense that
    /// matters here. Anthropic prices by family, so gating these would stop
    /// sessions over a switch that costs nothing extra, which is how a gate
    /// gets switched off for good.
    func testAVersionBumpWithinAFamilyIsNotAnUpgrade() {
        XCTAssertFalse(AppState.modelSwitchIsUpgrade(from: "claude-sonnet-4-5", to: "claude-sonnet-4-6"))
        XCTAssertFalse(AppState.modelSwitchIsUpgrade(from: "claude-opus-4-8", to: "claude-opus-5"))
    }

    /// Everything we cannot place has to come back false. This gates a blocking
    /// card, so the cost of a wrong true is a session stopped dead waiting on a
    /// notch nobody is looking at.
    func testUnknownOrMissingModelsAreNeverTreatedAsUpgrades() {
        XCTAssertFalse(AppState.modelSwitchIsUpgrade(from: "", to: "claude-opus-5"))
        XCTAssertFalse(AppState.modelSwitchIsUpgrade(from: "claude-haiku-4-5", to: ""))
        XCTAssertFalse(AppState.modelSwitchIsUpgrade(from: "some-future-model", to: "claude-opus-5"))
        XCTAssertFalse(AppState.modelSwitchIsUpgrade(from: "claude-haiku-4-5", to: "some-future-model"))
        XCTAssertEqual(AppState.modelCostRank("some-future-model"), 0)
    }

    /// The families are ordered by cost, not alphabetically or by release date.
    func testFamilyOrder() {
        XCTAssertLessThan(AppState.modelCostRank("claude-haiku-4-5"),
                          AppState.modelCostRank("claude-sonnet-4-6"))
        XCTAssertLessThan(AppState.modelCostRank("claude-sonnet-4-6"),
                          AppState.modelCostRank("claude-opus-5"))
    }

    // MARK: - What the gate answers the CLI

    /// The shape is not ours to choose: permissionDecision lives inside
    /// hookSpecificOutput, alongside a hookEventName that must be the event's
    /// own name. Get any of that wrong and the CLI ignores the answer, which
    /// looks exactly like a gate that does not work.
    func testDenyNamesTheEventAndCarriesAReason() throws {
        let body = EventServer.modelSwitchReply(.deny, "too expensive")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(body.utf8)) as? [String: Any])
        let inner = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(inner["hookEventName"] as? String, "PreModelSwitch")
        XCTAssertEqual(inner["permissionDecision"] as? String, "deny")
        XCTAssertEqual(inner["permissionDecisionReason"] as? String, "too expensive")
    }

    /// A deny with nothing typed still has to say something, or the terminal
    /// reports a blocked switch with no explanation at all.
    func testDenyWithoutAReasonStillExplainsItself() throws {
        for reason in [nil, ""] as [String?] {
            let body = EventServer.modelSwitchReply(.deny, reason)
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(
                with: Data(body.utf8)) as? [String: Any])
            let inner = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
            let text = try XCTUnwrap(inner["permissionDecisionReason"] as? String)
            XCTAssertFalse(text.isEmpty)
        }
    }

    func testAllowIsStatedAndCarriesNoReason() throws {
        let body = EventServer.modelSwitchReply(.allow, nil)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(body.utf8)) as? [String: Any])
        let inner = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(inner["permissionDecision"] as? String, "allow")
        XCTAssertNil(inner["permissionDecisionReason"])
    }

    /// Anything that is not a decision has to be silence, not a guess. A
    /// dismissed card or a timeout must leave the user's own /model change
    /// alone: the CLI reads a plain OK as no opinion and carries on.
    func testNoDecisionIsSilenceSoTheSwitchProceeds() {
        XCTAssertEqual(EventServer.modelSwitchReply(.ask, nil), EventServer.okBody)
    }

    // MARK: - The hook entry itself

    /// The matcher for this event is tested against the destination model id
    /// rather than a tool name, so it has to be a pattern that matches any
    /// model. A nil matcher (which is right for ConfigChange) or a tool-shaped
    /// one would install an entry that never fires.
    func testInstalledHookMatchesEveryDestinationModel() {
        var hooks: [String: Any] = [:]
        HookInstaller.appendHook(to: "PostModelSwitch", in: &hooks, matcher: ".*")
        let rules = try? XCTUnwrap(hooks["PostModelSwitch"] as? [[String: Any]])
        XCTAssertEqual(rules?.count, 1)
        XCTAssertEqual(rules?.first?["matcher"] as? String, ".*")
    }
}
