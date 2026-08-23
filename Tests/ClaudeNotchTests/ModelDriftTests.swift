import XCTest
@testable import ClaudeNotch

/// A session's model changing under it is worth saying once. Saying it when
/// nothing meaningful changed is worse than staying quiet, because the card
/// that cries wolf is the card people switch off.
final class ModelDriftTests: XCTestCase {

    // MARK: - Ranking

    func testTheThreeFamiliesRank() {
        XCTAssertEqual(ModelDrift.tier("claude-opus-5"), .opus)
        XCTAssertEqual(ModelDrift.tier("claude-sonnet-5"), .sonnet)
        XCTAssertEqual(ModelDrift.tier("claude-haiku-4-5-20251001"), .haiku)
        XCTAssertTrue(ModelDrift.tier("claude-opus-5") > ModelDrift.tier("claude-sonnet-5"))
        XCTAssertTrue(ModelDrift.tier("claude-sonnet-5") > ModelDrift.tier("claude-haiku-4-5"))
    }

    /// The family word is matched anywhere in the id, so a dated or
    /// differently-ordered id still ranks.
    func testRankingSurvivesIdShape() {
        XCTAssertEqual(ModelDrift.tier("claude-3-5-sonnet-20241022"), .sonnet)
        XCTAssertEqual(ModelDrift.tier("CLAUDE-OPUS-5"), .opus)
        XCTAssertEqual(ModelDrift.tier("anthropic/claude-opus-4-8"), .opus)
    }

    /// Anything this app has not been taught is unranked, not bottom-ranked.
    func testUnknownModelsAreUnranked() {
        XCTAssertEqual(ModelDrift.tier("claude-fable-5"), .unknown)
        XCTAssertEqual(ModelDrift.tier("gpt-5"), .unknown)
        XCTAssertEqual(ModelDrift.tier("grok-4"), .unknown)
        XCTAssertEqual(ModelDrift.tier(""), .unknown)
    }

    // MARK: - What counts as a change

    /// The regression every one of the reported issues describes.
    func testATierDropIsAnnounced() {
        let c = ModelDrift.change(from: "claude-opus-5", to: "claude-sonnet-5")
        XCTAssertEqual(c, ModelDrift.Change(from: "Opus", to: "Sonnet"))
        XCTAssertEqual(ModelDrift.change(from: "claude-opus-5", to: "claude-haiku-4-5"),
                       ModelDrift.Change(from: "Opus", to: "Haiku"))
        XCTAssertEqual(ModelDrift.change(from: "claude-sonnet-5", to: "claude-haiku-4-5"),
                       ModelDrift.Change(from: "Sonnet", to: "Haiku"))
    }

    /// A version bump inside one family is not a downgrade, and this is the
    /// case most likely to fire on a normal day.
    func testAVersionBumpInsideAFamilyIsSilent() {
        XCTAssertNil(ModelDrift.change(from: "claude-opus-4-8", to: "claude-opus-5"))
        XCTAssertNil(ModelDrift.change(from: "claude-opus-5", to: "claude-opus-4-8"))
        XCTAssertNil(ModelDrift.change(from: "claude-sonnet-4-5", to: "claude-sonnet-5"))
    }

    /// Good news is not an interruption.
    func testMovingUpATierIsSilent() {
        XCTAssertNil(ModelDrift.change(from: "claude-sonnet-5", to: "claude-opus-5"))
        XCTAssertNil(ModelDrift.change(from: "claude-haiku-4-5", to: "claude-sonnet-5"))
    }

    /// A model that cannot be ranked cannot be called a downgrade. Fable in
    /// particular is a real Claude model with no place in the tier order, and
    /// guessing one would tell somebody they were downgraded onto it.
    func testAnUnrankedModelOnEitherSideIsSilent() {
        XCTAssertNil(ModelDrift.change(from: "claude-opus-5", to: "claude-fable-5"))
        XCTAssertNil(ModelDrift.change(from: "claude-fable-5", to: "claude-haiku-4-5"))
        XCTAssertNil(ModelDrift.change(from: "claude-opus-5", to: "gpt-5"))
        XCTAssertNil(ModelDrift.change(from: "grok-4", to: "claude-haiku-4-5"))
    }

    /// A session that has not reported a model yet has not changed model.
    func testAnEmptySideIsSilent() {
        XCTAssertNil(ModelDrift.change(from: "", to: "claude-sonnet-5"))
        XCTAssertNil(ModelDrift.change(from: "claude-opus-5", to: ""))
        XCTAssertNil(ModelDrift.change(from: "", to: ""))
        XCTAssertNil(ModelDrift.change(from: "   ", to: "claude-haiku-4-5"))
    }

    func testTheSameModelIsNotAChange() {
        XCTAssertNil(ModelDrift.change(from: "claude-opus-5", to: "claude-opus-5"))
    }

    // MARK: - What it says

    func testTheCardNamesBothFamilies() {
        let c = ModelDrift.Change(from: "Opus", to: "Sonnet")
        let title = ModelDrift.cardTitle(c)
        XCTAssertTrue(title.contains("Sonnet"), title)
        XCTAssertTrue(title.contains("Opus"), title)
        XCTAssertTrue(ModelDrift.cardDetail(c).contains("Opus"))
    }

    /// The card must not assert a cause it cannot know. A drop can be the
    /// user's own `/model` just as easily as a plan cap.
    func testTheCardDoesNotClaimAReason() {
        let detail = ModelDrift.cardDetail(ModelDrift.Change(from: "Opus", to: "Sonnet")).lowercased()
        XCTAssertFalse(detail.contains("downgrad"), detail)
        XCTAssertTrue(detail.contains("either"), detail)
    }

    // MARK: - On a session

    @MainActor
    private func state(model: String) -> AppState {
        let s = AppState()
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { $0.model = model }
        return s
    }

    @MainActor
    private func modelCards(_ s: AppState) -> Int {
        s.permissionQueue.filter { $0.toolName == "Model" }.count
    }

    @MainActor
    func testAFallIsAnnouncedOnce() {
        let s = state(model: "claude-opus-5")
        s.noteModelChange(sessionId: "s1", cwd: "/tmp/proj", model: "claude-sonnet-5")
        XCTAssertEqual(modelCards(s), 1)
    }

    /// Flapping around a cap boundary must not produce a card per bounce.
    @MainActor
    func testFlappingSaysItOnce() {
        let s = state(model: "claude-opus-5")
        for _ in 0..<5 {
            s.noteModelChange(sessionId: "s1", cwd: "/tmp/proj", model: "claude-sonnet-5")
            s.sessions[s.sessionKey(sessionId: "s1", cwd: "/tmp/proj")]?.model = "claude-sonnet-5"
            s.noteModelChange(sessionId: "s1", cwd: "/tmp/proj", model: "claude-opus-5")
            s.sessions[s.sessionKey(sessionId: "s1", cwd: "/tmp/proj")]?.model = "claude-opus-5"
        }
        XCTAssertEqual(modelCards(s), 1)
    }

    /// A different session falling is a different fact.
    @MainActor
    func testASecondSessionIsItsOwnCard() {
        let s = state(model: "claude-opus-5")
        s.upsertSession(id: "s2", cwd: "/tmp/other", create: true) { $0.model = "claude-opus-5" }
        s.noteModelChange(sessionId: "s1", cwd: "/tmp/proj", model: "claude-sonnet-5")
        s.noteModelChange(sessionId: "s2", cwd: "/tmp/other", model: "claude-sonnet-5")
        XCTAssertEqual(modelCards(s), 2)
    }

    @MainActor
    func testTheSettingSilencesIt() {
        let s = state(model: "claude-opus-5")
        s.setModelChangeAlertsEnabled(false)
        s.noteModelChange(sessionId: "s1", cwd: "/tmp/proj", model: "claude-sonnet-5")
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }

    /// A session that has not reported a model yet, and a session climbing a
    /// tier, both stay quiet through the real entry point.
    @MainActor
    func testTheQuietCasesStayQuietOnASession() {
        let fresh = state(model: "")
        fresh.noteModelChange(sessionId: "s1", cwd: "/tmp/proj", model: "claude-sonnet-5")
        XCTAssertTrue(fresh.permissionQueue.isEmpty)

        let climbing = state(model: "claude-sonnet-5")
        climbing.noteModelChange(sessionId: "s1", cwd: "/tmp/proj", model: "claude-opus-5")
        XCTAssertTrue(climbing.permissionQueue.isEmpty)
    }

    /// A session the app has never seen is not a session that changed model.
    @MainActor
    func testAnUnknownSessionIsIgnored() {
        let s = state(model: "claude-opus-5")
        s.noteModelChange(sessionId: "nope", cwd: "/tmp/nowhere", model: "claude-haiku-4-5")
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }

    /// The real path in: a status line carrying a lower model must raise the
    /// card, and must still update the session's model afterwards.
    @MainActor
    func testAStatusLineFallRaisesTheCard() {
        let s = AppState()
        s.currentCwd = "/tmp/proj"
        s.upsertSession(id: "s1", cwd: "/tmp/proj", create: true) { $0.model = "claude-opus-5" }
        s.noteStatusLine(sessionId: "s1", model: "claude-sonnet-5",
                         contextPct: nil, fiveHourPct: nil, sevenDayPct: nil)
        XCTAssertEqual(modelCards(s), 1)
        XCTAssertEqual(s.sessions[s.sessionKey(sessionId: "s1", cwd: "/tmp/proj")]?.model,
                       "claude-sonnet-5", "the session must still end up on the new model")
    }
}
