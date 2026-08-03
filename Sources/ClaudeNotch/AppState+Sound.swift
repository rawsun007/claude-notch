import Foundation
import AppKit

// Alert sounds: the global mute, the per-tool categories, and the per-event
// overrides that let one noise be retuned or silenced without touching the rest.

extension AppState {
    func playSound(_ name: String) {
        guard !soundMuted else { return }
        guard name != SoundPreferences.silent, !name.isEmpty else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    /// Play whatever this event is currently set to. Events with no default of
    /// their own (the permission and question prompts) fall through to the alert
    /// sound, or to the per-tool sound when that is on, which is what they did
    /// before they were listed separately.
    func play(_ event: SoundEvent, toolName: String? = nil) {
        // Only the events that borrow the alert sound care about which tool
        // asked; the rest resolve to a sound of their own.
        if event.defaultSound == nil, soundPrefs.perEvent[event.rawValue] == nil {
            playAlert(toolName: toolName)
            return
        }
        playSound(soundPrefs.sound(for: event, alertSound: alertSound))
    }

    func playAlert(toolName: String? = nil) {
        let name: String
        if perToolSounds, let t = toolName {
            name = soundForTool(t)
        } else {
            name = alertSound
        }
        playSound(name)
    }

    /// What this event plays right now. The settings picker shows this.
    func sound(for event: SoundEvent) -> String {
        soundPrefs.sound(for: event, alertSound: alertSound)
    }

    func setSound(_ event: SoundEvent, _ sound: String) {
        updateSoundPrefs { $0.set(event, sound) }
    }

    /// The user-set (or default) chime for a tool when "Per-tool sounds" is on.
    func soundForTool(_ tool: String) -> String {
        soundPrefs.sound(for: ToolSoundCategory.category(for: tool))
    }

    func setToolSound(_ category: ToolSoundCategory, _ sound: String) {
        updateSoundPrefs { $0.set(category, sound) }
    }

    /// The current sound for a category (override or default).
    func toolSound(_ category: ToolSoundCategory) -> String {
        soundPrefs.sound(for: category)
    }

    func playChime() {
        play(.completed)
    }
}
