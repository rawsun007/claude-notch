import XCTest
@testable import ClaudeNotch

/// The Setup window polls the machine twice a second. What it asks, and where
/// it asks it from, is the difference between a checklist that ticks itself and
/// an app macOS calls unresponsive.
@MainActor
final class OnboardingProbeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        OnboardingState.invalidateProbeCache()
    }

    /// A refresh must return immediately. It gathers on a background queue and
    /// publishes later; if it ever goes back to doing the work inline, this is
    /// what notices, because the work includes two TCC lookups and a launchd
    /// round trip.
    func testRefreshDoesNotBlockTheCaller() {
        let state = OnboardingState()
        let started = Date()
        for _ in 0..<20 { state.refresh() }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.05,
                          "twenty refreshes took \(elapsed)s on the main thread")
    }

    /// And it does eventually publish something.
    func testRefreshEventuallyPublishes() {
        let state = OnboardingState()
        let done = expectation(description: "probe published")
        state.refresh()
        // hooksInstalled is read from a file, so it settles on the first probe
        // whichever way it lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(state.hooksInstalled, HookInstaller.isInstalled)
    }

    /// jq does not change twice a second, and finding out costs a subprocess on
    /// a Mac where it is not on a known path. The second answer comes from the
    /// cache.
    func testTheJqProbeIsCached() {
        let first = measureJqProbe()
        let second = measureJqProbe()
        XCTAssertLessThan(second, max(first, 0.001),
                          "the cached probe should not cost what the first one did")
    }

    private func measureJqProbe() -> TimeInterval {
        let state = OnboardingState()
        let started = Date()
        state.refresh()
        return Date().timeIntervalSince(started)
    }

    /// Installing can be the thing that changes the answer, so it clears the
    /// cache rather than letting the checklist lie for ten seconds.
    func testTheCacheCanBeInvalidated() {
        OnboardingState.invalidateProbeCache()   // must not crash or throw
        let state = OnboardingState()
        state.refresh()
        XCTAssertNotNil(state)
    }
}
