import Foundation

/// What stands between a destructive command and Allow on its card.
///
/// By default a destructive command takes a deliberate gesture: Touch ID when
/// the Mac has it and the user asked for it, press-and-hold otherwise. Some
/// people approve everything themselves anyway and want the one click back,
/// so "Skip confirmation for destructive commands" drops the gesture. It only
/// drops the gesture: the card is still red and still says Destructive, Allow
/// All still leaves destructive commands behind, a notification still cannot
/// allow one, and nothing is ever approved without a press. Turning the
/// setting on is itself locked behind the Mac's owner authentication, every
/// time, so a borrowed unlocked Mac cannot quietly switch it on.
enum DestructiveGate: Equatable {
    /// Touch ID (or the Mac's password) before the command is allowed.
    case biometric
    /// Press and hold the button.
    case hold
    /// A plain Allow button, because the user switched confirmation off.
    case none

    /// The gate for a destructive card. Pure, for tests.
    nonisolated static func gate(requireTouchID: Bool, biometricsAvailable: Bool, skipConfirmation: Bool) -> DestructiveGate {
        if skipConfirmation { return .none }
        return requireTouchID && biometricsAvailable ? .biometric : .hold
    }

    /// May Return allow this card? Never for a budget block, which needs an
    /// explicit choice; for a destructive command only when there is no
    /// gesture to skip.
    nonisolated static func returnAllows(isDangerous: Bool, budgetBlocked: Bool, skipConfirmation: Bool) -> Bool {
        if budgetBlocked { return false }
        return !isDangerous || skipConfirmation
    }

    /// Does changing the setting from `current` to `next` need the owner to
    /// authenticate first? Only switching it on: turning the safety back on
    /// is never something to put a lock in front of.
    nonisolated static func needsAuthentication(from current: Bool, to next: Bool) -> Bool {
        !current && next
    }
}
