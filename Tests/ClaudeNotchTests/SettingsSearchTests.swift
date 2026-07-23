import XCTest
@testable import ClaudeNotch

/// The settings search is tokenized AND across title + keywords + section, so
/// multi-word and cross-field queries must work and empty/no-match must return
/// nothing.
final class SettingsSearchTests: XCTestCase {

    private func titles(_ q: String) -> [String] {
        SettingsSearchItem.matching(q).map(\.title)
    }

    func testSingleTermPrefixInTitle() {
        XCTAssertTrue(titles("send f").contains("Send feedback"))
    }

    func testTermsSpanTitleAndKeywords() {
        // "feedback" is in the title, "linkedin" only in the keywords.
        XCTAssertTrue(titles("feedback linkedin").contains("Send feedback"))
    }

    func testHyphenSplitsLikeSpace() {
        XCTAssertFalse(titles("auto approve").isEmpty)
        XCTAssertEqual(titles("auto approve"), titles("auto-approve"))
    }

    func testKeywordOnlyMatch() {
        XCTAssertTrue(titles("openai").contains("Codex integration"))
        XCTAssertTrue(titles("boop").contains("Pet Mode"))
    }

    func testEmptyAndNoMatch() {
        XCTAssertTrue(SettingsSearchItem.matching("").isEmpty)
        XCTAssertTrue(SettingsSearchItem.matching("   ").isEmpty)
        XCTAssertTrue(SettingsSearchItem.matching("zzzznotathing").isEmpty)
    }

    func testAllTermsRequired() {
        // "send" alone matches; "send zzz" requires both, so it must not.
        XCTAssertFalse(titles("send").isEmpty)
        XCTAssertTrue(titles("send zzz").isEmpty)
    }
}
