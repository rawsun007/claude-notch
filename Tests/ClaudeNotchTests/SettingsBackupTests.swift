import XCTest
@testable import ClaudeNotch

/// Installing is idempotent and runs on launch whenever a release adds a hook
/// event, so most installs change nothing. Backing up regardless left hundreds
/// of copies of settings.json in ~/.claude, each a full copy of a file that can
/// hold env values and tokens, none of them ever removed.
final class SettingsBackupTests: XCTestCase {

    private var dir: String = ""
    private var settings: String = ""

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-backups-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        settings = (dir as NSString).appendingPathComponent("settings.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private func makeBackups(_ count: Int) throws {
        for i in 0..<count {
            let name = "settings.json.before-claudenotch.\(1_700_000_000 + i)"
            try "{}".write(toFile: (dir as NSString).appendingPathComponent(name),
                           atomically: true, encoding: .utf8)
        }
    }

    private var backupNames: [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return all.filter { $0.contains(".before-claudenotch.") }.sorted()
    }

    func testPruningKeepsTheNewestFew() throws {
        try makeBackups(20)
        HookInstaller.pruneBackups(settingsPath: settings, keeping: 5)
        XCTAssertEqual(backupNames.count, 5)
        // Newest kept, oldest gone. The timestamp is in the name, so sorting
        // the names sorts by age.
        XCTAssertEqual(backupNames.last, "settings.json.before-claudenotch.\(1_700_000_019)")
        XCTAssertEqual(backupNames.first, "settings.json.before-claudenotch.\(1_700_000_015)")
    }

    func testPruningLeavesASmallSetAlone() throws {
        try makeBackups(3)
        HookInstaller.pruneBackups(settingsPath: settings, keeping: 5)
        XCTAssertEqual(backupNames.count, 3)
    }

    func testPruningAnEmptyDirectoryIsFine() {
        HookInstaller.pruneBackups(settingsPath: settings, keeping: 5)
        XCTAssertEqual(backupNames.count, 0)
    }

    /// Only files that are ours. Somebody else's settings.json.bak stays.
    func testUnrelatedFilesAreNotTouched() throws {
        try makeBackups(10)
        let mine = (dir as NSString).appendingPathComponent("settings.json.bak")
        try "{}".write(toFile: mine, atomically: true, encoding: .utf8)
        HookInstaller.pruneBackups(settingsPath: settings, keeping: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine))
        XCTAssertEqual(backupNames.count, 2)
    }

    /// A backup is a copy of credentials, so it is not readable by anyone else
    /// on the machine.
    func testABackupIsWrittenPrivate() throws {
        HookInstaller.backUp(Data(#"{"env":{"TOKEN":"secret"}}"#.utf8), settingsPath: settings)
        let name = try XCTUnwrap(backupNames.first)
        let path = (dir as NSString).appendingPathComponent(name)
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600)
    }

    func testTheDefaultKeepIsSmall() {
        XCTAssertLessThanOrEqual(HookInstaller.settingsBackupsKept, 10)
        XCTAssertGreaterThan(HookInstaller.settingsBackupsKept, 0)
    }
}
