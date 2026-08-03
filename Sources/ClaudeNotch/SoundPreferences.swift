import Foundation

/// Which sound each thing plays, and the rules for resolving that.
///
/// The two dictionaries used to sit loose on AppState with the rules that read
/// them scattered across AppState+Sound, so "what does this event play" was
/// answerable only by reading three functions, and any code holding an AppState
/// could write a preference and forget to persist it. Data and rules live
/// together here instead, as a value type with no AppKit and no main-actor
/// isolation, which also makes the rules testable on their own.
struct SoundPreferences: Equatable {
    /// Sound name that means "play nothing". Deliberately not an NSSound name:
    /// nothing on the system is called this, and the player checks for it before
    /// asking AppKit for anything.
    static let silent = "None"

    /// ToolSoundCategory.rawValue -> sound name. Absent means the category default.
    private(set) var perTool: [String: String] = [:]
    /// SoundEvent.rawValue -> sound name. Absent means the event's own default.
    private(set) var perEvent: [String: String] = [:]

    init(perTool: [String: String] = [:], perEvent: [String: String] = [:]) {
        self.perTool = perTool
        self.perEvent = perEvent
    }

    // MARK: - Events

    /// What this event plays: its override, its own default, or, for the events
    /// that never had a sound of their own, the alert sound they borrow.
    func sound(for event: SoundEvent, alertSound: String) -> String {
        if let override = perEvent[event.rawValue] { return override }
        return event.defaultSound ?? alertSound
    }

    /// Storing an explicit "None" is the point: silence is a choice the user
    /// made, not the absence of one, so it must survive a relaunch. Choosing the
    /// event's own default again clears the entry, since there is then nothing
    /// to remember.
    mutating func set(_ event: SoundEvent, _ sound: String) {
        if let own = event.defaultSound, sound == own {
            perEvent.removeValue(forKey: event.rawValue)
        } else {
            perEvent[event.rawValue] = sound
        }
    }

    func isSilenced(_ event: SoundEvent) -> Bool {
        perEvent[event.rawValue] == Self.silent
    }

    // MARK: - Tool categories

    func sound(for category: ToolSoundCategory) -> String {
        perTool[category.rawValue] ?? category.defaultSound
    }

    mutating func set(_ category: ToolSoundCategory, _ sound: String) {
        if sound == category.defaultSound {
            perTool.removeValue(forKey: category.rawValue)
        } else {
            perTool[category.rawValue] = sound
        }
    }
}
