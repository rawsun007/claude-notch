import XCTest
@testable import ClaudeNotch

/// Per-event sounds decide whether the app is pleasant to leave running. The
/// two that matter: an event the user silenced must stay silent, and an event
/// the user never touched must keep sounding exactly as it did before the
/// setting existed.
@MainActor
final class SoundEventTests: XCTestCase {

    func testUntouchedEventsKeepTheirOldSounds() {
        let s = AppState()
        XCTAssertEqual(s.sound(for: .completed), "Glass",
                       "a finished task chimed with Glass before this setting; it still must")
        XCTAssertEqual(s.sound(for: .approved), "Tink")
        XCTAssertEqual(s.sound(for: .dismissed), "Pop")
        XCTAssertEqual(s.sound(for: .messageSent), "Tink")
    }

    func testPromptsFollowTheAlertSound() {
        let s = AppState()
        s.setAlertSound("Hero")
        XCTAssertEqual(s.sound(for: .permission), "Hero",
                       "prompts had no sound of their own; changing the alert sound must still move them")
        XCTAssertEqual(s.sound(for: .question), "Hero")
    }

    func testSilencingOneEventLeavesTheRestAlone() {
        let s = AppState()
        s.setSound(.approved, AppState.silentSound)
        XCTAssertEqual(s.sound(for: .approved), AppState.silentSound)
        XCTAssertEqual(s.sound(for: .dismissed), "Pop",
                       "silencing the allow tick must not silence the deny one")
        XCTAssertEqual(s.sound(for: .completed), "Glass")
        XCTAssertFalse(s.soundMuted, "silencing one event is not the global mute")
    }

    func testChoosingTheDefaultAgainClearsTheOverride() {
        let s = AppState()
        s.setSound(.completed, "Hero")
        XCTAssertEqual(s.soundPrefs.perEvent["completed"], "Hero")
        s.setSound(.completed, "Glass")
        XCTAssertNil(s.soundPrefs.perEvent["completed"],
                     "back at the default, nothing should be stored to carry forward")
        XCTAssertEqual(s.sound(for: .completed), "Glass")
    }

    /// Prompts have no default of their own, so every pick is an override,
    /// including one that happens to equal the current alert sound.
    func testPromptOverrideStaysPutWhenTheAlertSoundMovesOn() {
        let s = AppState()
        s.setSound(.question, "Submarine")
        s.setAlertSound("Hero")
        XCTAssertEqual(s.sound(for: .question), "Submarine")
        XCTAssertEqual(s.sound(for: .permission), "Hero",
                       "the prompt that was never given its own sound still follows the alert sound")
    }

    func testSilenceIsNotAnNSSoundName() {
        XCTAssertFalse(AppState.availableSounds.contains(AppState.silentSound),
                       "None is a choice, not a system sound; playSound must bail before AppKit sees it")
        XCTAssertEqual(AppState.selectableSounds.first, AppState.silentSound,
                       "silence belongs at the top of the picker, where it is easy to reach")
    }

    func testEverySoundingMomentIsListed() {
        for event in SoundEvent.allCases {
            XCTAssertFalse(event.label.isEmpty, "\(event.rawValue) needs a label for the settings row")
            XCTAssertFalse(event.detail.isEmpty, "\(event.rawValue) needs a line saying when it fires")
            if let own = event.defaultSound {
                XCTAssertTrue(AppState.availableSounds.contains(own),
                              "\(event.rawValue) defaults to \(own), which is not a sound we ship")
            }
        }
    }

    /// A silenced event coming back noisy after a relaunch is the worst failure
    /// here: the user thinks they turned it off and the app disagrees.
    func testEventSoundsSurviveASaveAndReload() throws {
        let s = AppState()
        s.setSound(.autoApproved, AppState.silentSound)
        s.setSound(.completed, "Hero")

        var snap = Persistence.Snapshot(history: [], allowRules: [], recentProjects: [])
        snap.eventSoundMap = s.soundPrefs.perEvent
        let data = try XCTUnwrap(Persistence.encode(snap))
        let back = try XCTUnwrap(Persistence.decode(data))

        let saved = try XCTUnwrap(back.eventSoundMap)
        let restored = AppState()
        restored.updateSoundPrefs { prefs in
            for (key, sound) in saved {
                if let event = SoundEvent(rawValue: key) { prefs.set(event, sound) }
            }
        }
        XCTAssertEqual(restored.sound(for: .autoApproved), AppState.silentSound)
        XCTAssertEqual(restored.sound(for: .completed), "Hero")
        XCTAssertEqual(restored.sound(for: .approved), "Tink",
                       "an event nobody touched must not be written into the file")
    }
}
