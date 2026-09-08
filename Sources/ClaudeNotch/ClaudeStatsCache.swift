import Foundation

/// Claude Code's own lifetime statistics, read from `~/.claude/stats-cache.json`.
///
/// This is the file behind the CLI's `/stats` screen: session count, per-model
/// token splits, daily activity, the longest session. It is worth reading
/// because it is computed across the WHOLE history and kept for us, while
/// `ClaudeUsageReader` parses recent transcripts within a bounded window. For
/// "how many sessions have I ever run" the two are not comparable, and this one
/// is right.
///
/// Two things it is NOT, both established by reading the file rather than
/// assuming:
///
///   - It carries no cost. Every model's `costUSD` is 0, so the app's own
///     estimate remains the only source of a money figure. This complements
///     that rather than replacing it.
///   - It is not live. `lastComputedDate` was yesterday's date on a machine
///     used all morning, so it lags by up to a day and does not include today.
///     Anything that has to be current still comes from the transcripts.
///
/// So: lifetime totals from here, today and cost from ClaudeUsageReader.
enum ClaudeStatsCache {

    struct ModelTokens: Equatable {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0

        /// What the CLI's "Total tokens" adds up, cache included. Cache reads
        /// dominate it by two orders of magnitude, which is why the figure looks
        /// implausible next to a cost estimate: they are billed at a fraction.
        var total: Int { input + output + cacheRead + cacheWrite }
    }

    struct DayActivity: Equatable {
        let date: String        // ISO yyyy-MM-dd, as written in the file
        let messages: Int
        let sessions: Int
        let toolCalls: Int
    }

    struct Stats: Equatable {
        /// The day the CLI last recomputed this. Shown, not hidden: a lifetime
        /// figure that silently excludes today is worse than one labelled.
        var lastComputedDate = ""
        var totalSessions = 0
        var totalMessages = 0
        var firstSessionDate = ""
        var longestSessionSeconds = 0
        var longestSessionMessages = 0
        var perModel: [String: ModelTokens] = [:]
        var daily: [DayActivity] = []

        var totalTokens: Int { perModel.values.reduce(0) { $0 + $1.total } }

        /// The model with the most tokens through it, which is what the CLI
        /// calls the favourite. Ties broken by name so the answer is stable
        /// rather than depending on dictionary order.
        var favouriteModel: String? {
            perModel
                .filter { $0.value.total > 0 }
                .max { a, b in
                    a.value.total == b.value.total ? a.key > b.key : a.value.total < b.value.total
                }?.key
        }

        var activeDays: Int { daily.filter { $0.messages > 0 || $0.sessions > 0 }.count }

        /// Calendar days from the first session up to and including `today`,
        /// which is the denominator the CLI shows active days against ("63/145").
        ///
        /// Deliberately NOT `daily.count`. The file only records days that had
        /// activity, so counting its entries makes the fraction 62/62 and says
        /// nothing. The interesting number is how much of the elapsed time was
        /// active, so the span has to come from the calendar.
        func spanDays(today: Date = Date()) -> Int {
            guard let first = ClaudeStatsCache.isoDay(String(firstSessionDate.prefix(10))) else {
                return daily.count
            }
            let cal = Calendar(identifier: .gregorian)
            let a = cal.startOfDay(for: first)
            let b = cal.startOfDay(for: today)
            let days = cal.dateComponents([.day], from: a, to: b).day ?? 0
            return max(1, days + 1)
        }

        /// The busiest day by message count, as a raw ISO string.
        var mostActiveDay: DayActivity? {
            daily.max { a, b in
                a.messages == b.messages ? a.date < b.date : a.messages < b.messages
            }
        }
    }

    static var path: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/stats-cache.json")
    }

    /// Reads disk. Call off the main thread.
    nonisolated static func load(from path: String = ClaudeStatsCache.path) -> Stats? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return parse(data)
    }

    /// Parsed with JSONSerialization rather than Codable on purpose. The file
    /// carries a `version` (5 at the time of writing) and is Claude Code's
    /// private format: a renamed or added key must degrade to a missing figure,
    /// not throw away every other figure in the file, which is what a strict
    /// Decodable would do.
    nonisolated static func parse(_ data: Data) -> Stats? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        var s = Stats()
        s.lastComputedDate = root["lastComputedDate"] as? String ?? ""
        s.totalSessions = intValue(root["totalSessions"])
        s.totalMessages = intValue(root["totalMessages"])
        s.firstSessionDate = root["firstSessionDate"] as? String ?? ""

        if let longest = root["longestSession"] as? [String: Any] {
            // Milliseconds in the file: 2_265_008_853 reads as 26d 5h in the
            // CLI, which is only true if this is ms.
            s.longestSessionSeconds = intValue(longest["duration"]) / 1000
            s.longestSessionMessages = intValue(longest["messageCount"])
        }

        if let models = root["modelUsage"] as? [String: Any] {
            for (name, raw) in models {
                guard let m = raw as? [String: Any] else { continue }
                var t = ModelTokens()
                t.input = intValue(m["inputTokens"])
                t.output = intValue(m["outputTokens"])
                t.cacheRead = intValue(m["cacheReadInputTokens"])
                t.cacheWrite = intValue(m["cacheCreationInputTokens"])
                s.perModel[name] = t
            }
        }

        if let days = root["dailyActivity"] as? [[String: Any]] {
            s.daily = days.compactMap { d in
                guard let date = d["date"] as? String, !date.isEmpty else { return nil }
                return DayActivity(date: date,
                                   messages: intValue(d["messageCount"]),
                                   sessions: intValue(d["sessionCount"]),
                                   toolCalls: intValue(d["toolCallCount"]))
            }.sorted { $0.date < $1.date }
        }
        return s
    }

    /// The file mixes Int and Double for counts big enough to lose precision as
    /// a Double, so both are accepted and anything else reads as zero.
    private nonisolated static func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }

    // MARK: - Streaks

    /// Longest and current run of consecutive active days.
    ///
    /// `today` is passed in rather than read from the clock so this is testable
    /// and so the caller can decide what "current" means. A streak that ended
    /// yesterday still counts as current: the cache is recomputed at most once
    /// a day, so requiring today's date would report every streak as broken
    /// every morning until the CLI catches up.
    nonisolated static func streaks(_ days: [DayActivity],
                                    today: String) -> (longest: Int, current: Int) {
        let active = days
            .filter { $0.messages > 0 || $0.sessions > 0 }
            .map(\.date)
            .sorted()
        guard !active.isEmpty else { return (0, 0) }

        var longest = 1
        var run = 1
        for i in 1..<max(active.count, 1) {
            if isNextDay(active[i - 1], active[i]) {
                run += 1
                longest = max(longest, run)
            } else {
                run = 1
            }
        }
        if active.count == 1 { longest = 1 }

        // Walk back from the end while the days are consecutive, then keep it
        // only if that run reaches today or yesterday.
        var current = 1
        var i = active.count - 1
        while i > 0, isNextDay(active[i - 1], active[i]) {
            current += 1
            i -= 1
        }
        let last = active[active.count - 1]
        let reachesNow = last == today || isNextDay(last, today)
        return (longest, reachesNow ? current : 0)
    }

    /// Whether `b` is the calendar day immediately after `a`, both ISO
    /// yyyy-MM-dd. Done through DateComponents rather than string arithmetic so
    /// month ends and leap days are the calendar's problem, not ours.
    nonisolated static func isNextDay(_ a: String, _ b: String) -> Bool {
        guard let da = isoDay(a), let db = isoDay(b) else { return false }
        guard let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: da) else {
            return false
        }
        return Calendar(identifier: .gregorian).isDate(next, inSameDayAs: db)
    }

    nonisolated static func isoDay(_ s: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}
