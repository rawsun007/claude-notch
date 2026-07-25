import XCTest
@testable import ClaudeNotch

/// isReportFilename is what tells the reporter which files in the shared
/// diagnostics dir (it lives alongside DebugLog output) are its own crash
/// reports — the set it lists for the menu and prunes down to maxReports. Too
/// loose and it would delete a debug log; too tight and reports pile up.
final class CrashReporterTests: XCTestCase {

    func testMatchesCrashReports() {
        XCTAssertTrue(CrashReporter.isReportFilename("crash-1712345678.log"))
        XCTAssertTrue(CrashReporter.isReportFilename("crash-signal.log"))
    }

    func testRejectsOtherDiagnostics() {
        XCTAssertFalse(CrashReporter.isReportFilename("debug.log"))       // DebugLog's own file
        XCTAssertFalse(CrashReporter.isReportFilename("crash-1712.txt"))  // wrong extension
        XCTAssertFalse(CrashReporter.isReportFilename("crash-1712"))      // no extension
        XCTAssertFalse(CrashReporter.isReportFilename("mycrash-1.log"))   // prefix not at start
        XCTAssertFalse(CrashReporter.isReportFilename(""))
    }
}
