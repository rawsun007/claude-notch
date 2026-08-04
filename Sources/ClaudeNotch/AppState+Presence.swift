import Foundation
import AppKit

// Whether anyone is actually at the machine.
//
// Completion cards already survive being missed: they queue up and wait. What
// does not survive is the chime, which plays to an empty room, and the pile you
// come back to, which arrives with no sense of what happened while you were
// gone. Both of those need the app to know you were away, which it can tell
// from how long it has been since the keyboard or mouse last moved. No
// permission needed for that, and no timer the user has to start.

extension AppState {
    /// Away after this long without a keypress or a mouse move. Long enough
    /// that reading a diff is not "away"; short enough that a coffee is.
    static let awayAfter: TimeInterval = 3 * 60

    /// Seconds since the last input event of any kind, system-wide.
    /// Overridable so the away logic can be tested without waiting.
    nonisolated static func systemIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .init(rawValue: ~0)!)
    }

    /// Pure so the threshold is testable: everything else here is a clock.
    nonisolated static func isAway(idleSeconds: TimeInterval,
                                   threshold: TimeInterval = AppState.awayAfter) -> Bool {
        idleSeconds >= threshold
    }

    var userIsAway: Bool {
        Self.isAway(idleSeconds: idleSecondsProvider())
    }

    /// A task finished while nobody was here. Counted rather than announced,
    /// so the announcement can happen once, when someone is back to hear it.
    func noteCompletedWhileAway() {
        completedWhileAway += 1
    }

    /// Called from the timer that was already running. Returns true when the
    /// user has just come back to something that happened without them.
    @discardableResult
    func checkReturnFromAway() -> Bool {
        guard !userIsAway, completedWhileAway > 0 else { return false }
        let count = completedWhileAway
        completedWhileAway = 0

        // One chime for the whole stretch. The alternative is the pile chiming
        // itself in as you sit down, which is the noise this exists to avoid.
        play(.completed)
        Announcer.say(count == 1
            ? "One task finished while you were away."
            : "\(count) tasks finished while you were away.")
        return true
    }
}
