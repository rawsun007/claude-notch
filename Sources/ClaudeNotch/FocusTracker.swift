import Foundation

/// How long you have been at it without a break.
///
/// The most-asked-for thing on every notch app's tracker is some version of a
/// pomodoro, and every one of them makes you start a timer. This app does not
/// need you to: Claude Code's hooks say precisely when work is happening, so the
/// stretch can be measured rather than declared. You never start it, and it is
/// never wrong about whether you were actually working.
///
/// Pure and clock-injected, so a four-hour session can be tested in a
/// millisecond instead of being waited out.
struct FocusTracker: Equatable {

    /// A gap this long ends the stretch. Long enough that reading a diff, or
    /// thinking, does not count as a break; short enough that lunch does.
    var breakAfter: TimeInterval = 8 * 60

    /// Nudge once a stretch passes this. Not a pomodoro's 25 minutes: this counts
    /// real working time, and being interrupted every 25 minutes of real work is
    /// how a reminder becomes something you turn off.
    var nudgeAfter: TimeInterval = 55 * 60

    /// When the current unbroken stretch began, and the last activity in it.
    private(set) var stretchStart: Date?
    private(set) var lastActivity: Date?
    /// The stretch we have already nudged for, so one long session nudges once.
    private(set) var nudgedStretchStart: Date?

    /// Work happened. Continues the stretch, or starts a new one if you have been
    /// away long enough to have had a break.
    mutating func noteActivity(at now: Date) {
        defer { lastActivity = now }
        guard let last = lastActivity, let start = stretchStart else {
            stretchStart = now
            return
        }
        if now.timeIntervalSince(last) >= breakAfter {
            // You were away. That was the break.
            stretchStart = now
        } else {
            stretchStart = start
        }
    }

    /// Seconds of unbroken work, or 0 when the stretch has lapsed into a break.
    func stretch(now: Date) -> TimeInterval {
        guard let start = stretchStart, let last = lastActivity else { return 0 }
        guard now.timeIntervalSince(last) < breakAfter else { return 0 }
        return max(0, now.timeIntervalSince(start))
    }

    /// True exactly once per stretch, the first time it passes `nudgeAfter`.
    ///
    /// Mutating on purpose: a nudge that can fire twice for the same stretch is a
    /// nag, and a nag gets switched off, which costs you every later nudge too.
    mutating func shouldNudge(now: Date) -> Bool {
        guard let start = stretchStart else { return false }
        guard stretch(now: now) >= nudgeAfter else { return false }
        guard nudgedStretchStart != start else { return false }
        nudgedStretchStart = start
        return true
    }
}
