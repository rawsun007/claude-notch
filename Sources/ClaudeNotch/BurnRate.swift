import Foundation

/// Predicts when a usage limit runs out, from how fast it is being spent.
///
/// The existing warnings fire at 80% and 95%, which tells you where you are but
/// not how long you have. Those are different questions: 80% with four hours
/// left on the window is fine, and 80% with forty minutes of work at the
/// current rate means the run you just started will not finish.
///
/// Deliberately conservative. It only speaks when the projection lands inside
/// the window and comfortably before the reset, because a forecast that keeps
/// being wrong is one you learn to ignore, and being ignored is the same as
/// being absent.
enum BurnRate {

    /// Two readings of the same limit window.
    struct Sample: Equatable {
        var percent: Double     // 0...1 of the cap used
        var at: Date
    }

    struct Forecast: Equatable {
        /// When the cap is projected to be reached.
        var exhaustedAt: Date
        /// Seconds from the later sample to that point.
        var secondsRemaining: TimeInterval
        /// True when the window resets before the cap would be hit, so the
        /// forecast is a curiosity rather than a warning.
        var resetsFirst: Bool
    }

    /// The smallest gap between readings worth trusting. Two samples ten
    /// seconds apart across a percentage reported in whole numbers produce a
    /// rate with enormous error bars, and extrapolating that to hours is how
    /// you end up promising someone forty minutes they do not have.
    static let minimumInterval: TimeInterval = 120

    /// Project when `percent` reaches 1, or nil when there is nothing useful to
    /// say: usage flat or falling, samples too close together, already at the
    /// cap, or a window that resets before it matters.
    nonisolated static func project(from earlier: Sample, to later: Sample,
                                    resetAt: Date? = nil) -> Forecast? {
        let elapsed = later.at.timeIntervalSince(earlier.at)
        guard elapsed >= minimumInterval else { return nil }

        let used = later.percent - earlier.percent
        guard used > 0 else { return nil }                 // flat or reset
        guard later.percent > 0, later.percent < 1 else { return nil }

        let perSecond = used / elapsed
        let remaining = (1 - later.percent) / perSecond
        guard remaining.isFinite, remaining > 0 else { return nil }

        let exhausted = later.at.addingTimeInterval(remaining)
        let resetsFirst = resetAt.map { $0 <= exhausted } ?? false
        return Forecast(exhaustedAt: exhausted,
                        secondsRemaining: remaining,
                        resetsFirst: resetsFirst)
    }

    /// The forecast as a line for the notch, or nil when it is not worth
    /// showing. Silent when the window resets first, and when the runway is
    /// long enough that nobody needs telling.
    static let worthWarningWithin: TimeInterval = 45 * 60

    nonisolated static func warning(_ forecast: Forecast?, limitName: String) -> String? {
        guard let forecast, !forecast.resetsFirst else { return nil }
        guard forecast.secondsRemaining <= worthWarningWithin else { return nil }
        return "At this rate you hit your \(limitName) in \(humanDuration(forecast.secondsRemaining))."
    }

    /// Rounded the way someone reads a countdown, not to the second.
    nonisolated static func humanDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "under a minute" }
        let minutes = total / 60
        if minutes < 60 {
            // Round to 5 minutes past a quarter hour: the projection is not
            // precise enough to justify "in 37 minutes".
            if minutes <= 15 { return "\(minutes) min" }
            return "\(Int((Double(minutes) / 5).rounded()) * 5) min"
        }
        let hours = Double(minutes) / 60
        if hours < 2 { return "about an hour" }
        return "about \(Int(hours.rounded())) hours"
    }
}
