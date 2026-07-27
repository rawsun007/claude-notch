import XCTest
@testable import ClaudeNotch

/// The language picker and the lookup behind it.
///
/// The bundle itself is not present under the test runner, so these cover the
/// parts that are pure: how the list is ordered, how a language is named, and
/// that the override round-trips through UserDefaults. Whether the tables
/// actually resolve is checked against the built .app, which is the only place
/// that question is real.
final class LocalizationTests: XCTestCase {

    private var saved: String = ""

    override func setUp() {
        super.setUp()
        saved = Localization.languageCode
    }

    override func tearDown() {
        Localization.languageCode = saved
        super.tearDown()
    }

    func testTheOverrideRoundTrips() {
        Localization.languageCode = "ja"
        XCTAssertEqual(Localization.languageCode, "ja")
        Localization.languageCode = ""
        XCTAssertEqual(Localization.languageCode, "")
    }

    /// Empty means follow macOS, which is the default and must stay reachable.
    func testAnEmptyCodeMeansNoOverrideBundle() {
        Localization.languageCode = ""
        XCTAssertNil(Localization.overrideBundle())
    }

    /// A code with no table must not leave a stale bundle behind from the
    /// previous selection.
    func testAnUnknownLanguageResolvesToNoBundle() {
        Localization.languageCode = "ja"
        _ = Localization.overrideBundle()
        Localization.languageCode = "zz-NOPE"
        XCTAssertNil(Localization.overrideBundle())
    }

    /// A picker showing "Japanese" to someone who only reads Japanese is not
    /// much of a picker.
    func testLanguagesAreNamedInTheirOwnLanguage() {
        XCTAssertEqual(Localization.nativeName("ja"), "日本語")
        XCTAssertEqual(Localization.nativeName("ru"), "Русский")
        XCTAssertEqual(Localization.nativeName("de"), "Deutsch")
    }

    /// Some locales lowercase their own name; a picker row should not.
    func testNativeNamesAreCapitalised() {
        for code in ["de", "fr", "es", "ru"] {
            let name = Localization.nativeName(code) ?? ""
            XCTAssertFalse(name.isEmpty, "no name for \(code)")
            XCTAssertEqual(String(name.prefix(1)), String(name.prefix(1)).uppercased(),
                           "\(code) starts lowercase: \(name)")
        }
    }

    /// English is the source language, so it belongs at the top rather than
    /// sorted in among the others.
    func testEnglishLeadsTheListWhenPresent() {
        let list = Localization.available
        if list.contains("en") {
            XCTAssertEqual(list.first, "en")
        }
    }

    func testAMissingKeyFallsBackToItself() {
        Localization.languageCode = ""
        XCTAssertEqual(L("NotARealKey", comment: ""), "NotARealKey")
    }
}
