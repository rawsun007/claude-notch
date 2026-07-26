import Foundation
import AppKit

// Alert sounds, including the per-tool sound categories.

extension AppState {
    func playSound(_ name: String) {
        guard !soundMuted else { return }
        NSSound(named: NSSound.Name(name))?.play()
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

    /// The user-set (or default) chime for a tool when "Per-tool sounds" is on.
    func soundForTool(_ tool: String) -> String {
        let category = ToolSoundCategory.category(for: tool)
        return perToolSoundMap[category.rawValue] ?? category.defaultSound
    }

    /// Set (or clear, when equal to the default) the sound for a category.
    func setToolSound(_ category: ToolSoundCategory, _ sound: String) {
        if sound == category.defaultSound {
            perToolSoundMap.removeValue(forKey: category.rawValue)
        } else {
            perToolSoundMap[category.rawValue] = sound
        }
        schedulePersist()
    }

    /// The current sound for a category (override or default).
    func toolSound(_ category: ToolSoundCategory) -> String {
        perToolSoundMap[category.rawValue] ?? category.defaultSound
    }

    func playChime() {
        playSound("Glass")
    }
}
