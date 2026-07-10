import Foundation

/// Which sessions have finished their turn, so late hooks from that turn can be
/// ignored.
///
/// Claude Code's hooks are not ordered with respect to each other. A `Bash` with
/// `run_in_background: true` returns its `PostToolUse` a second or two after the
/// turn's `Stop` has already fired:
///
///     13:28:44  PreToolUse
///     13:28:46  Stop          <- turn ended, notch goes idle
///     13:28:47  PostToolUse   <- arrives 1.1s late
///
/// `PostToolUse` means "Claude is thinking between tools", so honouring that late
/// one flips a finished session back to a pulsing "thinking" — and nothing else
/// is coming to clear it, because Claude is idle waiting for the user. The notch
/// stays stuck until the next turn starts.
///
/// The rule: once a turn ends, that state is absorbing. Hooks for it are dropped
/// until real new work starts — a user prompt, or the next `PreToolUse`.
struct TurnGate: Equatable {
    private var endedTurns: Set<String> = []

    /// The key a session is filed under: its id, or its (normalised) working
    /// directory when the hook didn't carry one.
    static func key(sessionId: String, cwd: String) -> String {
        if !sessionId.isEmpty { return sessionId }
        var normalised = cwd
        while normalised.count > 1, normalised.hasSuffix("/") { normalised.removeLast() }
        return normalised
    }

    /// Stop fired: everything still in flight for this turn is now stale.
    mutating func turnEnded(_ key: String) {
        guard !key.isEmpty else { return }
        endedTurns.insert(key)
    }

    /// A user prompt or a tool starting: the session is live again.
    mutating func workStarted(_ key: String) {
        endedTurns.remove(key)
    }

    /// True when this hook belongs to a turn that has already ended.
    func isLate(_ key: String) -> Bool {
        endedTurns.contains(key)
    }

    mutating func reset() {
        endedTurns.removeAll()
    }
}
