import XCTest
@testable import ClaudeNotch

/// "Is this thing working?" is the question every silent moment raises, and
/// until now the app had no answer to give.
final class HookHealthTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(serverHealthy: Bool = true, installed: Bool = true,
                       lastHookAgo: TimeInterval?) -> HookHealth.State {
        HookHealth.state(serverHealthy: serverHealthy,
                         installed: installed,
                         lastHookAt: lastHookAgo.map { now.addingTimeInterval(-$0) },
                         now: now)
    }

    // MARK: - Which state

    func testAServerThatIsNotListeningOutranksEverything() {
        XCTAssertEqual(state(serverHealthy: false, installed: false, lastHookAgo: nil), .serverDown)
        XCTAssertEqual(state(serverHealthy: false, lastHookAgo: 1), .serverDown)
    }

    func testMissingHooksAreReportedBeforeSilence() {
        XCTAssertEqual(state(installed: false, lastHookAgo: nil), .notInstalled)
    }

    func testNothingYetIsWaitingNotBroken() {
        XCTAssertEqual(state(lastHookAgo: nil), .waiting)
    }

    func testARecentHookIsHealthy() {
        XCTAssertEqual(state(lastHookAgo: 4), .healthy(lastHookAgo: 4))
        XCTAssertEqual(state(lastHookAgo: HookHealth.quietAfter - 1),
                       .healthy(lastHookAgo: HookHealth.quietAfter - 1))
    }

    /// Nobody is at the keyboard all day, so the threshold is looking for
    /// broken rather than idle.
    func testALongSilenceIsQuiet() {
        guard case .quiet = state(lastHookAgo: HookHealth.quietAfter + 1) else {
            return XCTFail("a long silence should read as quiet")
        }
        XCTAssertGreaterThan(HookHealth.quietAfter, 3600)
    }

    /// A clock that jumped, or a hook stamped in the future, is not evidence of
    /// anything wrong.
    func testAFutureTimestampIsNotAnAge() {
        XCTAssertEqual(state(lastHookAgo: -500), .healthy(lastHookAgo: 0))
    }

    // MARK: - What it says

    func testOnlyRealProblemsReadAsProblems() {
        XCTAssertFalse(HookHealth.isProblem(.healthy(lastHookAgo: 3)))
        XCTAssertFalse(HookHealth.isProblem(.waiting))
        XCTAssertTrue(HookHealth.isProblem(.quiet(lastHookAgo: 90_000)))
        XCTAssertTrue(HookHealth.isProblem(.notInstalled))
        XCTAssertTrue(HookHealth.isProblem(.serverDown))
    }

    func testEveryStateSaysSomething() {
        for s: HookHealth.State in [.healthy(lastHookAgo: 3), .waiting,
                                    .quiet(lastHookAgo: 90_000), .notInstalled, .serverDown] {
            XCTAssertFalse(HookHealth.summary(s).isEmpty, "\(s)")
        }
    }

    /// The two states a user can act on say what to do.
    func testTheActionableStatesGiveAnInstruction() {
        XCTAssertTrue(HookHealth.summary(.notInstalled).lowercased().contains("setup"))
        XCTAssertTrue(HookHealth.summary(.serverDown).lowercased().contains("menu bar"))
    }

    // MARK: - Durations read like a person wrote them

    func testDurationsRoundTheWayPeopleSpeak() {
        XCTAssertEqual(HookHealth.duration(4), "4s")
        XCTAssertEqual(HookHealth.duration(59), "59s")
        XCTAssertEqual(HookHealth.duration(60), "1 minute")
        XCTAssertEqual(HookHealth.duration(3599), "59 minutes")
        XCTAssertEqual(HookHealth.duration(3600), "1 hour")
        XCTAssertEqual(HookHealth.duration(86_399), "23 hours")
        XCTAssertEqual(HookHealth.duration(86_400), "1 day")
        XCTAssertEqual(HookHealth.duration(172_800), "2 days")
    }

    func testANegativeDurationDoesNotReadAsNonsense() {
        XCTAssertEqual(HookHealth.duration(-10), "0s")
    }
}
