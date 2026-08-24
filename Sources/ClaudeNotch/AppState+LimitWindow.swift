import Foundation

// MARK: - A usage window that has already ended

extension AppState {

    /// Forget a plan-limit reading once the window it measured has reset.
    ///
    /// Claude Code only pushes a status line while a session is redrawing, so
    /// between sessions the newest reading can be many hours old. Nothing ever
    /// invalidated it. From this machine's own log:
    ///
    ///     2026-08-13 07:37:58  5h=82%  reset=2026-08-13 07:40:00
    ///     2026-08-14 05:28:52  5h=58%  reset=2026-08-14 08:20:00
    ///
    /// Nothing in between. For twenty-two hours the app held a reset instant
    /// that had passed at 07:40, and went on describing a window that no longer
    /// existed. `resetCountdown` renders a past date as the word "now", so the
    /// rate-limit card said "resets in now" about a window that had reset hours
    /// earlier, which is precisely the wrong thing to tell somebody deciding
    /// whether to wait it out.
    ///
    /// Both halves of the reading are dropped, not just the date. The
    /// percentage was measured inside that window and says nothing about the
    /// one running now, and leaving it behind while clearing the date would
    /// promote a stale number to a current-looking one. `-1` is the existing
    /// "no reading" sentinel; the bars already render it as an em dash, so an
    /// expired window reads as unknown, which is what it is.
    ///
    /// The reading's age is deliberately untouched: `limitsUpdatedAt` describes
    /// when the app last heard anything, and that is still true.
    @discardableResult
    func expireStaleLimitWindows(now: Date = Date()) -> Bool {
        var changed = false
        if let reset = fiveHourResetAt, reset <= now {
            fiveHourResetAt = nil
            fiveHourLimitPercent = -1
            fiveHourForecast = nil
            fiveHourAnchor = nil
            changed = true
        }
        if let reset = weeklyResetAt, reset <= now {
            weeklyResetAt = nil
            weeklyLimitPercent = -1
            weeklyForecast = nil
            weeklyAnchor = nil
            changed = true
        }
        return changed
    }
}
