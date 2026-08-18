import Foundation

// Is this thing actually working?
//
// Everything the notch shows arrives over a loopback socket from hooks that
// Claude Code fires, and none of that is visible. When it works you see cards;
// when it does not you see nothing, and nothing looks the same as a quiet
// afternoon. The app can now say when the server failed to start, but a server
// that is listening and simply never hears from anyone looks healthy from the
// inside and is just as useless.
//
// So: one line, in Settings, that answers the question a person actually has.
// Pure, because "what does the app say about itself" is exactly the kind of
// thing that should be pinned by tests rather than checked by squinting at a
// running app.
enum HookHealth {

    enum State: Equatable {
        /// Hooks are arriving.
        case healthy(lastHookAgo: TimeInterval)
        /// Installed and listening, but nothing has come in yet this launch.
        case waiting
        /// Listening, hooks were arriving, and then they stopped for a long time.
        case quiet(lastHookAgo: TimeInterval)
        /// The hooks are not in settings.json at all.
        case notInstalled
        /// The server itself is not listening. The worst case, and the one the
        /// menu bar already shouts about.
        case serverDown
    }

    /// How long without a hook before "quiet" stops meaning "you went to lunch".
    /// A session fires hooks constantly, but nobody is at the keyboard all day,
    /// so this is deliberately generous: it is looking for broken, not idle.
    static let quietAfter: TimeInterval = 6 * 3600

    nonisolated static func state(serverHealthy: Bool, installed: Bool,
                                  lastHookAt: Date?, now: Date = Date()) -> State {
        guard serverHealthy else { return .serverDown }
        guard installed else { return .notInstalled }
        guard let lastHookAt else { return .waiting }
        let ago = now.timeIntervalSince(lastHookAt)
        // A clock that jumped, or a hook stamped in the future: not evidence of
        // anything wrong, so read it as just-arrived rather than as an age.
        return ago > quietAfter ? .quiet(lastHookAgo: ago) : .healthy(lastHookAgo: max(0, ago))
    }

    /// The line itself.
    nonisolated static func summary(_ state: State) -> String {
        switch state {
        case .healthy(let ago):
            return String(format: L("Receiving events. Last one %@ ago.",
                                    comment: "Settings row: hooks are arriving. %@ is a duration such as \"4s\""),
                          duration(ago))
        case .waiting:
            return L("Installed and listening. Nothing has come in since this app started.",
                     comment: "Settings row: hooks are installed but none have arrived yet")
        case .quiet(let ago):
            return String(format: L("Nothing has come in for %@. If a session has been running, the hooks may have been removed from your settings.",
                                    comment: "Settings row: hooks stopped arriving. %@ is a duration such as \"2 days\""),
                          duration(ago))
        case .notInstalled:
            return L("The hooks are not in your Claude Code settings, so nothing will ever appear here. Run setup to put them back.",
                     comment: "Settings row: the hooks are not installed")
        case .serverDown:
            return L("Not listening, so nothing can reach this app. See the menu bar.",
                     comment: "Settings row: the hook server is not running")
        }
    }

    /// Whether the row should read as a problem rather than as a status.
    nonisolated static func isProblem(_ state: State) -> Bool {
        switch state {
        case .healthy, .waiting: return false
        case .quiet, .notInstalled, .serverDown: return true
        }
    }

    /// Rounded the way a person would say it. Seconds up to a minute, then
    /// minutes, then hours, then days: nobody wants "172800 seconds".
    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return String(format: L("%ds", comment: "Short duration in seconds"), s) }
        if s < 3600 {
            let m = s / 60
            return m == 1 ? L("1 minute", comment: "Duration: exactly one minute")
                          : String(format: L("%d minutes", comment: "Duration in minutes"), m)
        }
        if s < 86_400 {
            let h = s / 3600
            return h == 1 ? L("1 hour", comment: "Duration: exactly one hour")
                          : String(format: L("%d hours", comment: "Duration in hours"), h)
        }
        let d = s / 86_400
        return d == 1 ? L("1 day", comment: "Duration: exactly one day")
                      : String(format: L("%d days", comment: "Duration in days"), d)
    }
}
