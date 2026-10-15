import XCTest
@testable import ClaudeNotch

/// CLI 2.1.299 compacts a long conversation left idle for about 54 minutes,
/// before its prompt cache expires, and reports it to hooks as "auto", the
/// same word as a window that filled up mid-turn. The difference is whether a
/// turn was running when it started.
final class IdleCompactionTests: XCTestCase {

    func testKinds() {
        XCTAssertEqual(AppState.compactionKind(trigger: "manual", startedWhileIdle: true), .manual)
        XCTAssertEqual(AppState.compactionKind(trigger: "auto", startedWhileIdle: false), .full)
        XCTAssertEqual(AppState.compactionKind(trigger: "auto", startedWhileIdle: true), .idle)
        XCTAssertEqual(AppState.compactionKind(trigger: "", startedWhileIdle: false), .full)
    }

    func testBusyStatuses() {
        for s in ["thinking", "replying", "Running"] { XCTAssertTrue(AppState.sessionIsBusy(s), s) }
        for s in ["done", "ready", "error", "", "waiting"] { XCTAssertFalse(AppState.sessionIsBusy(s), s) }
    }
}
