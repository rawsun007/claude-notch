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

/// Arrow-key movement through the settings sidebar.
///
/// The order has to come from the same place the sidebar is built from, or the
/// arrows walk a different list than the one on screen.
final class SettingsSectionNavigationTests: XCTestCase {

    func testEverySectionIsReachable() {
        XCTAssertEqual(Set(SettingsSection.ordered), Set(SettingsSection.allCases),
                       "a section missing from nav can never be reached with the arrows")
        XCTAssertEqual(SettingsSection.ordered.count, SettingsSection.allCases.count,
                       "a section listed twice would be visited twice")
    }

    func testArrowsMoveOneRow() {
        XCTAssertEqual(SettingsSection.section(from: .general, offset: 1), .notch)
        XCTAssertEqual(SettingsSection.section(from: .notch, offset: -1), .general)
    }

    /// The sidebar is grouped, but the arrows walk it as one list.
    func testMovementCrossesGroupBoundaries() {
        XCTAssertEqual(SettingsSection.section(from: .pet, offset: 1), .session)
        XCTAssertEqual(SettingsSection.section(from: .session, offset: -1), .pet)
    }

    /// Clamped, not wrapped: holding an arrow should come to rest at the end
    /// rather than silently starting again from the other one.
    func testMovementClampsAtBothEnds() {
        XCTAssertEqual(SettingsSection.section(from: SettingsSection.ordered.first!, offset: -1),
                       SettingsSection.ordered.first!)
        XCTAssertEqual(SettingsSection.section(from: SettingsSection.ordered.last!, offset: 1),
                       SettingsSection.ordered.last!)
    }
}
