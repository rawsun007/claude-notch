import Foundation

/// What today and this month are going to cost, from what they have cost so far.
///
/// The Budget page could only say what you had already spent, which is the
/// number you can do nothing about. A cap warning at 100% arrives at the moment
/// it stops being useful. These two projections answer the questions people
/// actually ask a spend meter: "am I going to blow today's cap", and "what is
/// this month going to come to".
///
/// Pure and `nonisolated` throughout, so it is unit-tested rather than eyeballed.
enum CostForecast {

    // MARK: - The month

    struct Month: Equatable {
        /// Spend so far this calendar month, today included.
        var spentSoFar: Double
        /// Mean spend across the completed days we have data for.
        var dailyAverage: Double
        /// spentSoFar plus dailyAverage for each day still to come.
        var projectedTotal: Double
        /// Completed days the average is built from. Small means "treat this
        /// loosely", and the UI says so rather than presenting a number built
        /// from one Tuesday as a forecast.
        var daysMeasured: Int
        /// Days left after today.
        var daysRemaining: Int
    }

    /// Project the month from the per-day cost map (`yyyy-MM-dd` → USD).
    ///
    /// Today is deliberately kept out of the average: at 9am it is a fraction of
    /// a day and would drag the mean down, making the projection cheerful and
    /// wrong. It still counts towards `spentSoFar`, because it is money spent.
    ///
    /// Nil when the month has no completed day with any spend on it — there is
    /// then nothing to project from, and inventing a number would be worse than
    /// the page staying quiet.
    nonisolated static func month(dailyCostUSD: [String: Double],
                                  asOf now: Date = Date(),
                                  calendar: Calendar = .current) -> Month? {
        let startOfToday = calendar.startOfDay(for: now)
        guard let range = calendar.range(of: .day, in: .month, for: now) else { return nil }
        let daysInMonth = range.count
        let dayOfMonth = calendar.component(.day, from: now)

        var spentSoFar = 0.0
        var completedTotal = 0.0
        var daysMeasured = 0
        for day in 1..<(dayOfMonth + 1) {
            guard let date = calendar.date(byAdding: .day, value: day - dayOfMonth, to: startOfToday) else { continue }
            let cost = dailyCostUSD[dayKey(date, calendar: calendar)] ?? 0
            spentSoFar += cost
            // A day with no spend is a real data point (a weekend counts), but
            // only for days the map actually reaches back to: the transcript
            // scan keeps four weeks, so an earlier day is missing rather than
            // free, and counting it as zero would halve the average.
            guard day < dayOfMonth, dayOfMonth - day <= coveredDays else { continue }
            completedTotal += cost
            daysMeasured += 1
        }

        guard daysMeasured > 0, completedTotal > 0 else { return nil }
        let average = completedTotal / Double(daysMeasured)
        let remaining = daysInMonth - dayOfMonth
        return Month(spentSoFar: spentSoFar,
                     dailyAverage: average,
                     projectedTotal: spentSoFar + average * Double(remaining),
                     daysMeasured: daysMeasured,
                     daysRemaining: remaining)
    }

    /// How far back `ClaudeUsageReader.compute()` fills the per-day map. Days
    /// older than this are absent, not zero.
    static let coveredDays = 28

    // MARK: - Today against the cap

    struct DayAgainstCap: Equatable {
        /// Spend projected for the whole day at the rate so far.
        var projectedTotal: Double
        /// When the cap is projected to be crossed, if it is.
        var crossesAt: Date?
    }

    /// Project today's finishing spend from the rate since midnight.
    ///
    /// The straight-line assumption is crude but honest for a working day, and
    /// it is the only assumption available without modelling when someone
    /// stops. The projection is withheld before `minimumHours` have passed: a
    /// £2 spend by 00:20 extrapolates to a fortune, and a warning built on that
    /// is one you learn to dismiss.
    ///
    /// Nil when there is no cap, nothing spent, or the day is too young.
    nonisolated static func today(spent: Double, cap: Double,
                                  asOf now: Date = Date(),
                                  calendar: Calendar = .current) -> DayAgainstCap? {
        guard cap > 0, spent > 0 else { return nil }
        let startOfDay = calendar.startOfDay(for: now)
        let elapsed = now.timeIntervalSince(startOfDay)
        guard elapsed >= minimumHours * 3600 else { return nil }

        let perSecond = spent / elapsed
        let dayLength: TimeInterval = 24 * 3600
        let projected = perSecond * dayLength

        // Already over: the cap alert has fired, there is nothing left to
        // forecast.
        guard spent < cap else { return DayAgainstCap(projectedTotal: projected, crossesAt: nil) }
        let secondsToCap = (cap - spent) / perSecond
        let crossing = now.addingTimeInterval(secondsToCap)
        let endOfDay = startOfDay.addingTimeInterval(dayLength)
        return DayAgainstCap(projectedTotal: projected,
                             crossesAt: crossing < endOfDay ? crossing : nil)
    }

    /// How much of the day has to have passed before a projection means
    /// anything.
    static let minimumHours: Double = 2

    /// A one-line warning for the notch, or nil when there is nothing worth
    /// saying: no crossing today, or one so far off that it will have changed
    /// several times before it matters.
    static let worthWarningWithin: TimeInterval = 4 * 3600

    nonisolated static func warning(_ forecast: DayAgainstCap?, cap: Double,
                                    asOf now: Date = Date()) -> String? {
        guard let crossesAt = forecast?.crossesAt else { return nil }
        let seconds = crossesAt.timeIntervalSince(now)
        guard seconds > 0, seconds <= worthWarningWithin else { return nil }
        let clock = DateFormatter()
        clock.dateStyle = .none
        clock.timeStyle = .short
        return String(format: L("At this rate you pass your %1$@ daily cap around %2$@.",
                                comment: "Budget forecast warning. %1$@ is a money cap, %2$@ is a clock time"),
                      ClaudeUsageReader.fmtMoney(cap), clock.string(from: crossesAt))
    }

    // MARK: - Helpers

    nonisolated static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        return f.string(from: date)
    }
}
