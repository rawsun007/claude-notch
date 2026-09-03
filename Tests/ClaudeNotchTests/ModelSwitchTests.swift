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
