import Foundation

// A session that stopped because you ran out of usage, and what happens next.
//
// Claude Code 2.1.234 changed what this means. It used to be the end of the
// turn: the session stopped, and picking it up again was your job, whenever you
// next looked. Now the CLI waits for the limit to reset and carries on by
// itself, unless you turned that off in /config.
//
// Which leaves a gap this app is exactly the right shape to fill. The whole
// point of a usage limit is that it lands while you are working and hands you
// several hours of not working; you go and do something else, and the moment
// the session picks up again is the moment you would want to know, and the one
// moment you are guaranteed not to be looking at the terminal.
//
// Pure: what the app says about a pause, and when it decides the pause is over,
// are both decided here so they can be tested without waiting five hours.
enum UsageLimitPause {

    /// The setting Claude Code keeps for this, and the files it can live in.
    /// Absent means on: that is the CLI's own default.
    static let settingKey = "autoContinueAtUsageLimit"

    /// Reasons a turn dies that mean "out of usage" rather than "broken".
    static let limitReasons: Set<String> = ["rate_limit", "usage_limit", "rate_limited"]

    nonisolated static func isLimitStop(reason: String) -> Bool {
        limitReasons.contains(reason.lowercased())
    }

    /// Whether Claude Code will resume this by itself.
    ///
    /// Read from the user's own settings rather than assumed, because the two
    /// cases need opposite things from this app: if the CLI is going to
    /// continue, the useful message is "it came back". If it is not, the
    /// session is sitting on a dialog waiting for a human, and that is worth
    /// saying much sooner and much louder.
    nonisolated static func autoContinues(settingsPaths: [String]) -> Bool {
        for path in settingsPaths {
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            if let value = boolValue(obj[settingKey]) { return value }
            // It also travels inside a nested settings object in some layouts.
            for nested in ["settings", "config"] {
                if let inner = obj[nested] as? [String: Any],
                   let value = boolValue(inner[settingKey]) { return value }
            }
        }
        return true   // absent means on, matching the CLI
    }

    /// The default places to look.
    nonisolated static var defaultSettingsPaths: [String] {
        let home = NSHomeDirectory() as NSString
        return [home.appendingPathComponent(".claude.json"),
                home.appendingPathComponent(".claude/settings.json")]
    }

    /// What the card says while the session is waiting.
    nonisolated static func pausedTitle(autoContinues: Bool) -> String {
        autoContinues
            ? L("Out of usage, waiting for the reset",
                comment: "Card title when a session paused on a usage limit and will continue by itself")
            : L("Out of usage, waiting for you",
                comment: "Card title when a session paused on a usage limit and needs a human to continue it")
    }

    nonisolated static func pausedDetail(autoContinues: Bool, resumesAt: Date?,
                                         now: Date = Date()) -> String {
        let when = resumesAt.map { clockTime($0) }
        switch (autoContinues, when) {
        case (true, let when?):
            return String(format: L("Claude Code will pick the task up on its own at about %@. Nothing for you to do.",
                                    comment: "Card body for an auto-continuing usage-limit pause. %@ is a time of day"),
                          when)
        case (true, nil):
            return L("Claude Code will pick the task up on its own when the limit resets. Nothing for you to do.",
                     comment: "Card body for an auto-continuing usage-limit pause with no known reset time")
        case (false, let when?):
            return String(format: L("The limit resets at about %@, and continuing is switched off, so the session is holding a dialog until you answer it.",
                                    comment: "Card body when auto-continue is off. %@ is a time of day"),
                          when)
        case (false, nil):
            return L("Continuing automatically is switched off, so the session is holding a dialog until you answer it.",
                     comment: "Card body when auto-continue is off and the reset time is unknown")
        }
    }

    /// And what it says when the work starts again. This is the one the user
    /// asked for, and the one they will read on a phone.
    nonisolated static func resumedTitle(project: String) -> String {
        project.isEmpty
            ? L("Your task has been resumed",
                comment: "Card title when a paused session started working again")
            : String(format: L("Your task in %@ has been resumed",
                               comment: "Card title when a paused session started working again. %@ is a project name"),
                     project)
    }

    nonisolated static func resumedDetail(pausedFor: TimeInterval) -> String {
        String(format: L("The usage limit lifted and the session picked up where it stopped, after %@.",
                         comment: "Card body when a paused session resumed. %@ is how long it was paused, such as \"3 hours\""),
               HookHealth.duration(pausedFor))
    }

    /// Whether an event arriving now means the session is working again.
    ///
    /// A pause ends when the session does something, not when the clock says it
    /// may. A couple of seconds of grace keeps the hooks that trail the stop
    /// itself from counting as the restart.
    static let restartGrace: TimeInterval = 5

    nonisolated static func isRestart(pausedAt: Date, eventAt: Date) -> Bool {
        eventAt.timeIntervalSince(pausedAt) > restartGrace
    }

    /// How long past the reset to wait before saying nothing has happened.
    ///
    /// The reset time is approximate and the CLI does not restart on the second,
    /// so a few minutes of grace keeps this from crying wolf at a session that
    /// is about to wake up on its own.
    static let stalledAfter: TimeInterval = 10 * 60

    /// Whether a paused session should have restarted by now and has not.
    nonisolated static func looksStalled(resumesAt: Date?, now: Date = Date()) -> Bool {
        guard let resumesAt else { return false }   // no known reset: nothing to be late for
        return now.timeIntervalSince(resumesAt) > stalledAfter
    }

    nonisolated static func stalledTitle(project: String) -> String {
        project.isEmpty
            ? L("The usage limit lifted, but nothing restarted",
                comment: "Card title when a paused session did not resume after its limit reset")
            : String(format: L("%@ has not restarted since the limit lifted",
                               comment: "Card title when a paused session did not resume. %@ is a project name"),
                     project)
    }

    nonisolated static func stalledDetail(since: TimeInterval) -> String {
        String(format: L("The limit reset %@ ago and this session has done nothing since. Claude Code may have been closed, or continuing automatically may be switched off, in which case the terminal is holding a dialog for you.",
                         comment: "Card body when a paused session did not resume. %@ is a duration"),
               HookHealth.duration(since))
    }

    /// "3:40 PM", in the user's own clock format.
    nonisolated static func clockTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    nonisolated private static func boolValue(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        if let s = any as? String {
            if s == "true" || s == "1" { return true }
            if s == "false" || s == "0" { return false }
        }
        return nil
    }
}
