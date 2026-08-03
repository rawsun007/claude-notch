import XCTest
@testable import ClaudeNotch

/// The resolution rules, tested without an AppState. They used to be spread
/// across three main-actor methods, so exercising them meant standing up the
/// whole app object; as a value type they answer on their own.
final class SoundPreferencesTests: XCTestCase {

    func testAnEmptyPreferenceSetAnswersWithTheDefaults() {
        let prefs = SoundPreferences()
        XCTAssertEqual(prefs.sound(for: .completed, alertSound: "Funk"), "Glass")
        XCTAssertEqual(prefs.sound(for: .permission, alertSound: "Funk"), "Funk",
                       "an event with no sound of its own borrows the alert sound")
        XCTAssertEqual(prefs.sound(for: .bash), "Funk")
        XCTAssertEqual(prefs.sound(for: .notification), "Submarine")
    }

    func testSettingAndClearingAnEventOverride() {
        var prefs = SoundPreferences()
        prefs.set(.completed, "Hero")
        XCTAssertEqual(prefs.sound(for: .completed, alertSound: "Funk"), "Hero")
        XCTAssertEqual(prefs.perEvent["completed"], "Hero")

        prefs.set(.completed, "Glass")
        XCTAssertNil(prefs.perEvent["completed"],
                     "the default needs no entry; storing it would freeze today's default forever")
    }

    func testSilenceIsStoredRatherThanTreatedAsAbsent() {
        var prefs = SoundPreferences()
        prefs.set(.approved, SoundPreferences.silent)
        XCTAssertTrue(prefs.isSilenced(.approved))
        XCTAssertEqual(prefs.perEvent["approved"], SoundPreferences.silent,
                       "silence must be written down, or a relaunch brings the sound back")
        XCTAssertFalse(prefs.isSilenced(.dismissed))
    }

    func testCategoryOverridesBehaveTheSameWay() {
        var prefs = SoundPreferences()
        prefs.set(.edit, "Hero")
        XCTAssertEqual(prefs.sound(for: .edit), "Hero")
        XCTAssertEqual(prefs.sound(for: .write), "Tink", "one category does not move the others")

        prefs.set(.edit, ToolSoundCategory.edit.defaultSound)
        XCTAssertNil(prefs.perTool["edit"])
    }

    /// Two dictionaries in, two dictionaries out: the on-disk format is
    /// unchanged by this type existing, so an existing state.json still loads.
    func testItRoundTripsThroughTheFlatDictionariesOnDisk() {
        var prefs = SoundPreferences()
        prefs.set(.autoApproved, SoundPreferences.silent)
        prefs.set(.bash, "Hero")

        let reloaded = SoundPreferences(perTool: prefs.perTool, perEvent: prefs.perEvent)
        XCTAssertEqual(reloaded, prefs)
        XCTAssertTrue(reloaded.isSilenced(.autoApproved))
        XCTAssertEqual(reloaded.sound(for: .bash), "Hero")
    }
}
