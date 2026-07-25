import XCTest
@testable import ClaudeNotch

/// openEditedFile takes a hook-supplied path and, for anything but an ordinary
/// source file, reveals it in Finder instead of launching it. isRiskyToOpen is
/// the classifier that decides which. A crafted path ending in an
/// execute-on-open type (a config profile, a .webloc link, a shell script) must
/// never be handed to the default launcher.
final class OpenEditedFileTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openedit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeFile(_ name: String, executable: Bool = false) throws -> String {
        let url = dir.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return url.path
    }

    func testOrdinarySourceFileIsSafe() throws {
        XCTAssertFalse(AppState.isRiskyToOpen(try makeFile("Foo.swift")))
        XCTAssertFalse(AppState.isRiskyToOpen(try makeFile("README.md")))
        XCTAssertFalse(AppState.isRiskyToOpen(try makeFile("data.json")))
    }

    func testRunnableExtensionsAreRisky() throws {
        for name in ["run.sh", "go.command", "Evil.mobileconfig", "link.webloc",
                     "link.url", "prof.terminal", "x.desktop", "a.js"] {
            XCTAssertTrue(AppState.isRiskyToOpen(try makeFile(name)),
                          "\(name) should be revealed in Finder, not opened")
        }
    }

    func testExtensionMatchIsCaseInsensitive() throws {
        XCTAssertTrue(AppState.isRiskyToOpen(try makeFile("EVIL.MobileConfig")))
    }

    func testExecutableBitIsRisky() throws {
        // No dangerous extension, but the execute bit is set.
        XCTAssertTrue(AppState.isRiskyToOpen(try makeFile("tool", executable: true)))
    }

    func testMissingPathIsRisky() {
        XCTAssertTrue(AppState.isRiskyToOpen("/no/such/path/here.swift"))
    }

    func testDirectoryIsRisky() {
        XCTAssertTrue(AppState.isRiskyToOpen(dir.path))
    }
}
