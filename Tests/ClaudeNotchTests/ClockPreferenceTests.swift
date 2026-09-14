import XCTest
@testable import ClaudeNotch

/// Claude Code's timeFormat and timeZone settings (2.1.257), honoured so the
/// notch and the terminal below it agree about what time something happened.
///
/// The accepted values are quoted from the CLI binary itself:
///   "auto" (default), "12-hour", "24-hour", "24-hour-utc", or a strftime
///   pattern such as "%H:%M"
final class ClockPreferenceTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14 22:13:20 UTC

    private func formatted(_ s: ClockPreference.Settings) -> String? {
        ClockPreference.timeFormatter(s).map { $0.string(from: noon) }
    }

    /// No settings means no opinion, and the caller keeps whatever it already
    /// did. Returning a default formatter instead would quietly restyle
    /// unrelated screens.
    func testNoPreferenceMeansNoFormatter() {
        XCTAssertNil(ClockPreference.timeFormatter(.init()))
        XCTAssertNil(ClockPreference.timeFormatter(.init(format: "auto")))
    }

    func testTwentyFourHour() {
        let s = ClockPreference.Settings(format: "24-hour", timeZone: "UTC")
        XCTAssertEqual(formatted(s), "22:13")
    }

    func testTwelveHour() {
        let s = ClockPreference.Settings(format: "12-hour", timeZone: "UTC")
        XCTAssertEqual(formatted(s), "10:13 PM")
    }

    /// UTC is part of the format here, so an explicit zone must not override it.
    func testTwentyFourHourUtcIgnoresAConflictingZone() {
        let s = ClockPreference.Settings(format: "24-hour-utc", timeZone: "Asia/Kolkata")
        XCTAssertEqual(formatted(s), "22:13")
    }

    func testAnExplicitZoneMovesTheClock() {
        let s = ClockPreference.Settings(format: "24-hour", timeZone: "Asia/Kolkata")
        XCTAssertEqual(formatted(s), "03:43", "UTC+5:30")
    }

    // MARK: - strftime

    /// DateFormatter speaks Unicode date-field patterns, so "%H:%M" handed to
    /// it directly prints a literal percent sign and the letter H.
    func testStrftimeIsTranslatedNotPassedThrough() {
        XCTAssertEqual(ClockPreference.strftimeToDateFormat("%H:%M"), "HH:mm")
        let s = ClockPreference.Settings(format: "%H:%M", timeZone: "UTC")
        XCTAssertEqual(formatted(s), "22:13")
    }

    func testCommonFields() {
        XCTAssertEqual(ClockPreference.strftimeToDateFormat("%I:%M %p"), "hh:mm a")
        XCTAssertEqual(ClockPreference.strftimeToDateFormat("%Y-%m-%d"), "yyyy-MM-dd")
    }

    /// Literal letters have to be quoted or DateFormatter reads them as fields:
    /// an unquoted "at" prints an era and a year.
    func testLiteralLettersAreQuoted() {
        let pattern = ClockPreference.strftimeToDateFormat("%H h")
        XCTAssertEqual(pattern, "HH 'h'")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = pattern
        XCTAssertEqual(f.string(from: noon), "22 h")
    }

    /// A pattern using a field outside the clock set falls back rather than
    /// printing a half-translated result. A wrong clock is worse than the
    /// default one.
    func testAnUnsupportedFieldFallsBack() {
        XCTAssertNil(ClockPreference.strftimeToDateFormat("%j"))
        XCTAssertNil(ClockPreference.timeFormatter(.init(format: "%j")))
    }

    func testAPatternWithNoFieldsIsNotAPattern() {
        XCTAssertNil(ClockPreference.strftimeToDateFormat("hello"))
    }

    func testAnEscapedPercentSurvives() {
        XCTAssertEqual(ClockPreference.strftimeToDateFormat("%H%%"), "HH%")
    }

    // MARK: - Reading the settings chain

    /// Managed settings are read last and therefore win, matching the rule the
    /// sandbox reader already follows.
    func testManagedSettingsWinOverUserSettings() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clockpref-\(UUID().uuidString)")
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try #"{"timeFormat":"12-hour"}"#.write(
            to: home.appendingPathComponent(".claude/settings.json"),
            atomically: true, encoding: .utf8)
        let managed = dir.appendingPathComponent("managed.json")
        try #"{"timeFormat":"24-hour","timeZone":"UTC"}"#.write(
            to: managed, atomically: true, encoding: .utf8)

        let s = ClockPreference.read(cwd: "", home: home.path, managedPath: managed.path)
        XCTAssertEqual(s.format, "24-hour")
        XCTAssertEqual(s.timeZone, "UTC")
    }

    func testMissingFilesAreNotAnError() {
        let s = ClockPreference.read(cwd: "/nonexistent", home: "/nonexistent",
                                     managedPath: "/nonexistent/managed.json")
        XCTAssertEqual(s, ClockPreference.Settings())
        XCTAssertTrue(s.isDefault)
    }
}
