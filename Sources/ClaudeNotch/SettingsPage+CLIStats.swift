import SwiftUI

// Claude Code's own lifetime statistics, shown next to the app's.
//
// These come from ~/.claude/stats-cache.json, the file behind the CLI's /stats
// screen, and they are here because for lifetime questions they are simply
// better than anything this app can work out: the CLI computes them across all
// history, while ClaudeUsageReader parses recent transcripts within a bounded
// window.
//
// They do not replace the figures above them, and the section says so. The file
// carries no cost at all (every model's costUSD is 0), so money remains the
// app's own estimate, and it is recomputed at most once a day, so it excludes
// today. Presenting a stale lifetime figure as live would be the one way to
// make accurate numbers misleading, hence the "as of" line.

extension SettingsView {

    /// Compact token counts: 11.5b rather than 11 513 402 118.
    ///
    /// Lifetime token totals run to eleven figures, and at that size the digits
    /// stop carrying information: nobody reads the units column of a billion.
    static func compactTokens(_ n: Int) -> String {
        let v = Double(n)
        switch abs(n) {
        case 1_000_000_000...: return String(format: "%.2fb", v / 1e9)
        case 1_000_000...:     return String(format: "%.1fm", v / 1e6)
        case 1_000...:         return String(format: "%.1fk", v / 1e3)
        default:               return "\(n)"
        }
    }

    /// "26d 5h 10m", dropping the parts that are zero so a nine-minute session
    /// does not read as "0d 0h 9m".
    static func compactDuration(seconds: Int) -> String {
        guard seconds > 0 else { return "0m" }
        let d = seconds / 86400
        let h = (seconds % 86400) / 3600
        let m = (seconds % 3600) / 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d)d") }
        if h > 0 { parts.append("\(h)h") }
        if m > 0 || parts.isEmpty { parts.append("\(m)m") }
        return parts.joined(separator: " ")
    }

    /// A model id as the CLI writes it in this file, shortened for display.
    static func statsModelLabel(_ id: String) -> String {
        let short = ClaudeUsageReader.shortModel(id)
        guard !short.isEmpty, short != id else { return id }
        return short.prefix(1).uppercased() + short.dropFirst()
    }

    @ViewBuilder
    var cliLifetimeStats: some View {
        if let s = cliStats, s.totalSessions > 0 {
            let today = Date()
            let (longestStreak, currentStreak) = ClaudeStatsCache.streaks(s.daily,
                                                                         today: Self.isoToday(today))
            sectionLabel(L("All time, from Claude Code", comment: "Settings section heading"))
            Text(L("Claude Code keeps its own running totals across every session you have ever had, which is what its /stats screen shows. These are those numbers, not the app's: they reach back further than the transcripts read above, and they carry no cost figure, so the money on this page stays an estimate made here.", comment: "Settings explanation for the CLI's own statistics"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    churnStat(L("Sessions", comment: "Stat label: how many sessions ever"),
                              "\(s.totalSessions)", .primary)
                    churnStat(L("Total tokens", comment: "Stat label: lifetime token count"),
                              Self.compactTokens(s.totalTokens), .primary)
                    churnStat(L("Messages", comment: "Stat label: lifetime message count"),
                              Self.compactTokens(s.totalMessages), .primary)
                }
                HStack(spacing: 12) {
                    churnStat(L("Active days", comment: "Stat label: days with any activity"),
                              "\(s.activeDays)/\(s.spanDays(today: today))", .primary)
                    churnStat(L("Current streak", comment: "Stat label: consecutive active days now"),
                              currentStreak == 1
                                ? L("1 day", comment: "Streak of exactly one day")
                                : String(format: L("%d days", comment: "Streak length in days"), currentStreak),
                              currentStreak > 0 ? .green : .secondary)
                    churnStat(L("Longest streak", comment: "Stat label: longest run of consecutive active days"),
                              longestStreak == 1
                                ? L("1 day", comment: "Streak of exactly one day")
                                : String(format: L("%d days", comment: "Streak length in days"), longestStreak),
                              .primary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let fav = s.favouriteModel {
                        statRow(L("Most used model", comment: "Stat label: the model with the most tokens"),
                                Self.statsModelLabel(fav))
                    }
                    if s.longestSessionSeconds > 0 {
                        statRow(L("Longest session", comment: "Stat label: longest single session"),
                                Self.compactDuration(seconds: s.longestSessionSeconds))
                    }
                    if let busiest = s.mostActiveDay, busiest.messages > 0 {
                        statRow(L("Busiest day", comment: "Stat label: the day with the most messages"),
                                Self.friendlyDay(busiest.date))
                    }
                    if !s.firstSessionDate.isEmpty {
                        statRow(L("First session", comment: "Stat label: date of the earliest session"),
                                Self.friendlyDay(String(s.firstSessionDate.prefix(10))))
                    }
                }
                .padding(.vertical, 10).padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardChrome()

                // Per-model split. The point of showing cache separately is that
                // it dwarfs everything else and is billed at a fraction, which
                // is the whole reason the token total looks so large next to the
                // cost estimate above.
                if s.perModel.contains(where: { $0.value.total > 0 }) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(s.perModel.sorted { $0.value.total > $1.value.total }, id: \.key) { entry in
                            if entry.value.total > 0 {
                                statRow(Self.statsModelLabel(entry.key),
                                        String(format: L("%1$@ in, %2$@ out, %3$@ cached", comment: "Per-model token split. %1$@ input, %2$@ output, %3$@ cache read"),
                                               Self.compactTokens(entry.value.input),
                                               Self.compactTokens(entry.value.output),
                                               Self.compactTokens(entry.value.cacheRead)))
                            }
                        }
                    }
                    .padding(.vertical, 10).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardChrome()
                }

                if !s.lastComputedDate.isEmpty {
                    Text(String(format: L("Claude Code last recomputed these on %@, so today is not included yet.", comment: "Note under the CLI statistics. %@ is a date"),
                                Self.friendlyDay(s.lastComputedDate)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    static func isoToday(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// "17 May 2026" in the user's own format, falling back to the raw ISO
    /// string rather than showing nothing if it cannot be parsed.
    static func friendlyDay(_ iso: String) -> String {
        guard let d = ClaudeStatsCache.isoDay(iso) else { return iso }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .none
        return out.string(from: d)
    }
}
