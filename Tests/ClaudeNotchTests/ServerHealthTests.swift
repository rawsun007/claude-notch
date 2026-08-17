import XCTest
@testable import ClaudeNotch

/// A hook server that never started is the one failure this app must not keep
/// to itself: it looks exactly like a quiet day, and the reason for it may be
/// that something else is answering the permission prompts.
@MainActor
final class ServerHealthTests: XCTestCase {

    func testHealthyByDefault() {
        XCTAssertEqual(AppState().serverStatus, .listening)
        XCTAssertTrue(AppState.ServerStatus.listening.isHealthy)
    }

    func testAFailureRaisesACardAndAHistoryRow() {
        let s = AppState()
        s.noteServerFailed(.portTaken(port: 53127))

        XCTAssertEqual(s.serverStatus, .portTaken(port: 53127))
        XCTAssertEqual(s.permissionQueue.count, 1)
        XCTAssertEqual(s.permissionQueue.first?.kind, .notification)
        XCTAssertEqual(s.permissionQueue.first?.toolName, "EventServer")
        XCTAssertEqual(s.history.first?.toolName, "EventServer")
    }

    /// The row is marked dangerous, not info: this is the app telling you it
    /// cannot do the job you installed it for.
    func testTheHistoryRowIsMarkedDangerous() {
        let s = AppState()
        s.noteServerFailed(.failed(reason: "EPERM"))
        XCTAssertEqual(s.history.first?.outcome, .dangerous)
    }

    /// Repeated reports of the same failure must not stack up cards.
    func testTheSameFailureIsReportedOnce() {
        let s = AppState()
        s.noteServerFailed(.portTaken(port: 53127))
        s.noteServerFailed(.portTaken(port: 53127))
        s.noteServerFailed(.portTaken(port: 53127))
        XCTAssertEqual(s.permissionQueue.count, 1)
    }

    /// A retry that works puts the app back to normal without a restart.
    func testRecoveryClearsTheState() {
        let s = AppState()
        s.noteServerFailed(.portTaken(port: 53127))
        s.noteServerListening()
        XCTAssertEqual(s.serverStatus, .listening)
        XCTAssertTrue(s.serverStatus.isHealthy)
    }

    // MARK: - What it says

    /// A port conflict and a broken socket are different problems with
    /// different first moves, so they must not share wording.
    func testTheTwoFailuresReadDifferently() {
        let taken = AppState.serverFailureTitle(.portTaken(port: 53127))
        let broke = AppState.serverFailureTitle(.failed(reason: "EPERM"))
        XCTAssertNotEqual(taken, broke)
        XCTAssertFalse(taken.isEmpty)
        XCTAssertFalse(broke.isEmpty)
    }

    /// The detail hands over the command that answers "who has it", because
    /// that is the only question the user can act on.
    func testThePortConflictDetailNamesThePortAndTheCommand() {
        let detail = AppState.serverFailureDetail(.portTaken(port: 53127))
        XCTAssertTrue(detail.contains("53127"))
        XCTAssertTrue(detail.contains("lsof"))
    }

    /// No jargon in the part a person reads. "bind failed, errno 48" is true
    /// and useless.
    func testTheTitlesAreInEnglish() {
        for status: AppState.ServerStatus in [.portTaken(port: 53127), .failed(reason: "errno 48")] {
            let title = AppState.serverFailureTitle(status)
            XCTAssertFalse(title.contains("errno"), title)
            XCTAssertFalse(title.contains("bind"), title)
            XCTAssertFalse(title.lowercased().contains("socket"), title)
        }
    }

    func testAHealthyServerSaysNothingAnywhere() {
        XCTAssertEqual(AppState.serverFailureTitle(.listening), "")
        XCTAssertEqual(AppState.serverFailureDetail(.listening), "")
        XCTAssertNil(AppState.serverFailureMenuLabel(.listening))
    }

    func testTheMenuLabelExistsForBothFailures() {
        XCTAssertNotNil(AppState.serverFailureMenuLabel(.portTaken(port: 53127)))
        XCTAssertNotNil(AppState.serverFailureMenuLabel(.failed(reason: "x")))
    }
}
