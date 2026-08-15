import Foundation

/// How the context bar picks its denominator. `auto` infers the window from the
/// model (see `ClaudeUsageReader.modelHas1MWindow`); the explicit cases let the
/// user override when the guess is wrong for their plan.
enum ContextWindowMode: String, Codable, CaseIterable {
    case auto, w200k, w1M
}

/// Reads Claude Code's own transcript files (`~/.claude/projects/**/*.jsonl`)
/// to total token usage and estimate cost over the last 7 days. This is
/// Claude's API usage, separate from ClaudeNotch's own action stats (Insights).
///
/// Token counts are exact (each assistant message records its own `usage`).
/// Cost is an *estimate* from public per-token pricing — Anthropic doesn't
/// expose a real bill to subscription users, and there is no local source for
/// plan caps or session/weekly reset times, so we don't show those.
enum ClaudeUsageReader {

    struct Tokens {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheCreation = 0
        var costUSD: Double = 0
        var total: Int { input + output + cacheRead + cacheCreation }

        static func + (a: Tokens, b: Tokens) -> Tokens {
            Tokens(input: a.input + b.input,
                   output: a.output + b.output,
                   cacheRead: a.cacheRead + b.cacheRead,
                   cacheCreation: a.cacheCreation + b.cacheCreation,
                   costUSD: a.costUSD + b.costUSD)
        }
        static func += (a: inout Tokens, b: Tokens) { a = a + b }
    }

    struct Usage {
        var today = Tokens()
        var fiveHour = Tokens()   // rolling last 5 hours
        var week = Tokens()
        var weekByModel: [String: Tokens] = [:]
        var weekByProject: [String: Tokens] = [:]   // keyed by cwd
        var dailyTokens: [String: Int] = [:]         // yyyy-MM-dd → total tokens
        var dailyCostUSD: [String: Double] = [:]     // yyyy-MM-dd → estimated spend
        var hourCounts: [Int: Int] = [:]             // local hour 0...23 → message count
        var cacheSavingsUSD: Double = 0              // vs paying fresh input price
        var sessionsToday = 0
        var sessionsWeek = 0
        var computedAt = Date()
        var hasData: Bool { week.total > 0 }

        /// Fraction of input-side tokens served from the prompt cache (0...1).
        var cacheHitRate: Double {
            let inputSide = week.input + week.cacheCreation + week.cacheRead
            return inputSide > 0 ? Double(week.cacheRead) / Double(inputSide) : 0
        }
        var avgTokensPerSession: Int { sessionsWeek > 0 ? week.total / sessionsWeek : 0 }
        var activeDays: Int { dailyTokens.values.filter { $0 > 0 }.count }
        var dailyAverageTokens: Int { week.total / max(activeDays, 1) }
        var todayVsAverage: Double {
            let avg = dailyAverageTokens
            return avg > 0 ? Double(today.total) / Double(avg) : 0
        }
        // Tie-break by hour so equal-count hours don't shuffle which three show.
        var topHours: [Int] { hourCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3).map(\.key) }
    }

    // Public per-million-token pricing (input, output, cacheWrite, cacheRead),
    // used only to estimate cost. Opus 4.x is $5/$25, not the legacy $15/$75 —
    // verified against Claude Code's own /usage totals.
    private static func price(for model: String) -> (input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        let m = model.lowercased()
        if m.contains("opus")  { return (5, 25, 6.25, 0.5) }
        if m.contains("haiku") { return (1, 5, 1.25, 0.1) }
        return (3, 15, 3.75, 0.3)   // default to Sonnet pricing
    }

    /// True the first time this assistant *message* is seen, false for every
    /// later line that repeats it.
    ///
    /// Claude Code does not write one transcript line per API response — it
    /// writes one line per content block. A turn that thinks, says something and
    /// then calls a tool lands as three lines, each carrying the same
    /// `message.id` and, crucially, *the same `usage` object*. Billing every
    /// line therefore charged that one turn three times over, which is why a
    /// session could read $228 when it had really spent $123. The usage belongs
    /// to the message, so it is counted once per message id.
    ///
    /// Lines with no id (older transcripts, synthetic entries) can't be deduped
    /// and are counted as they come.
    static func isFirstLine(of message: [String: Any], seen: inout Set<String>) -> Bool {
        guard let id = message["id"] as? String, !id.isEmpty else { return true }
        return seen.insert(id).inserted
    }

    /// Bucket a day-keyed (yyyy-MM-dd) cost map into `weeks` calendar-week
    /// totals ending today, oldest first. Bucket 0 is the oldest week, the last
    /// bucket is the current 7 days. Pure and deterministic given `asOf`, so it
    /// is unit-tested rather than exercised only through the UI.
    static func weeklyCostBuckets(daily: [String: Double], weeks: Int = 4,
                                  asOf: Date, calendar: Calendar = .current) -> [(label: String, cost: Double)] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: asOf)
        var out: [(String, Double)] = []
        // Week index from newest: 0 = last 7 days, 1 = the 7 before that, ...
        for w in (0..<weeks).reversed() {
            var sum = 0.0
            for d in 0..<7 {
                let offset = -(w * 7 + d)
                guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
                sum += daily[fmt.string(from: day)] ?? 0
            }
            let label = w == 0 ? "This wk" : "\(w)w ago"
            out.append((label, sum))
        }
        return out
    }

    private static func cost(input: Int, output: Int, cacheRead: Int, cacheCreation: Int, model: String) -> Double {
        let p = price(for: model)
        return Double(input) / 1_000_000 * p.input
             + Double(output) / 1_000_000 * p.output
             + Double(cacheCreation) / 1_000_000 * p.cacheWrite
             + Double(cacheRead) / 1_000_000 * p.cacheRead
    }

    /// What the cache-read tokens would have cost at the fresh input price,
    /// minus what they actually cost — i.e. money saved by prompt caching.
    private static func cacheSavings(cacheRead: Int, model: String) -> Double {
        let p = price(for: model)
        return Double(cacheRead) / 1_000_000 * (p.input - p.cacheRead)
    }

    /// How long until a rate-limit window resets, as a glanceable string.
    ///
    /// A percentage on its own tells you that you are in trouble but not whether
    /// you can wait it out: "82%" is a very different fact at ten minutes to
    /// reset than at four hours. Claude Code reports the reset instant, so the
    /// notch can answer the question people actually have.
    ///
    /// Coarse on purpose — nobody is counting seconds down to a five-hour window.
    static func resetCountdown(until reset: Date, now: Date = Date()) -> String {
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return "now" }
        let minutes = Int((seconds / 60).rounded(.up))
        guard minutes >= 60 else { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        guard hours < 24 else {
            let days = hours / 24
            let restHours = hours % 24
            return restHours > 0 ? "\(days)d \(restHours)h" : "\(days)d"
        }
        return rest > 0 ? "\(hours)h \(rest)m" : "\(hours)h"
    }

    /// How long ago something happened, as a glanceable string.
    ///
    /// Not the same job as `resetCountdown`, which rounds UP because a window
    /// that resets in 61 seconds should not read "1m" when you are waiting on it.
    /// An age rounds DOWN: a reading taken an hour ago is "1h old", not "1h 1m
    /// old". Using the countdown for both is what made a one-hour-old reading
    /// render as "1h 1m".
    static func ageDescription(seconds: Double) -> String {
        guard seconds >= 60 else { return "just now" }
        let minutes = Int(seconds / 60)          // rounds down
        guard minutes >= 60 else { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        guard hours < 24 else {
            let days = hours / 24
            let restHours = hours % 24
            return restHours > 0 ? "\(days)d \(restHours)h" : "\(days)d"
        }
        return rest > 0 ? "\(hours)h \(rest)m" : "\(hours)h"
    }

    /// Last path component of a working directory, e.g. ".../claude mac app" → "claude mac app".
    static func projectName(_ cwd: String) -> String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    /// 12-hour clock label for an hour-of-day, e.g. 16 → "4 PM".
    static func hourLabel(_ h: Int) -> String {
        let suffix = h < 12 ? "AM" : "PM"
        let hour12 = h % 12 == 0 ? 12 : h % 12
        return "\(hour12) \(suffix)"
    }

    /// Build a 7-bar token sparkline for the last 7 days (oldest to newest),
    /// returning the bar row and an aligned narrow-weekday label row.
    static func sparkline(daily: [String: Int]) -> (bars: String, labels: String) {
        let blocks = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        let cal = Calendar.current
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"
        let labelFmt = DateFormatter()
        labelFmt.locale = Locale(identifier: "en_US_POSIX")
        labelFmt.dateFormat = "EEEEE"   // narrow weekday: M T W T F S S

        var values: [Int] = []
        var labels: [String] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            values.append(daily[dayFmt.string(from: day)] ?? 0)
            labels.append(labelFmt.string(from: day))
        }
        let maxVal = max(values.max() ?? 0, 1)
        let bars = values.map { v -> String in
            v == 0 ? blocks[0] : blocks[min(blocks.count - 1, max(1, Int((Double(v) / Double(maxVal) * 7).rounded())))]
        }
        return (bars.joined(separator: " "), labels.joined(separator: " "))
    }

    /// The version digits of a model id, dotted.
    ///
    /// Ids carry the version as hyphen-separated digits, and how many there are
    /// is not fixed: `claude-opus-4-6` is 4.6, `claude-opus-5` is just 5, and a
    /// later `claude-opus-5-1` is 5.1. Reading a fixed N-M pair, as this used
    /// to, finds nothing in a single-digit id, which is why the notch showed a
    /// bare "Opus" for Opus 5.
    ///
    /// The trailing release date has to go first or it reads as more version
    /// components: `claude-sonnet-4-5-20250929` is 4.5, not 4.5.20250929.
    /// Older ids put the version before the family name
    /// (`claude-3-5-sonnet-20241022`), which falls out of this for free.
    nonisolated static func modelVersionLabel(_ model: String) -> String {
        let stripped = model.lowercased()
            .replacingOccurrences(of: "-?\\d{6,}", with: "",
                                  options: .regularExpression)
        return stripped
            .split(separator: "-")
            .filter { $0.allSatisfy(\.isNumber) && !$0.isEmpty }
            .joined(separator: ".")
    }

    /// Family plus version, lowercase: "opus 5", "sonnet 4.6".
    ///
    /// Also the key usage is grouped by, so two versions of the same family
    /// are counted separately, which is what you want when comparing them.
    static func shortModel(_ model: String) -> String {
        let m = model.lowercased()
        let family: String
        if m.contains("opus")        { family = "opus" }
        else if m.contains("sonnet") { family = "sonnet" }
        else if m.contains("haiku")  { family = "haiku" }
        else { return model }
        let version = modelVersionLabel(model)
        return version.isEmpty ? family : "\(family) \(version)"
    }

    /// Splits a model id like `claude-sonnet-4-6` into a capitalised name
    /// ("Sonnet") and a dotted version ("4.6"). Returns ("", "") for unknown ids.
    static func modelNameVersion(_ model: String) -> (name: String, version: String) {
        let m = model.lowercased()
        let name: String
        if m.contains("opus")        { name = "Opus" }
        else if m.contains("sonnet") { name = "Sonnet" }
        else if m.contains("haiku")  { name = "Haiku" }
        else if !model.isEmpty       { name = model }
        else                         { return ("", "") }

        return (name, modelVersionLabel(model))
    }

    /// Reads the model id from `~/.claude/settings.json`. Returns "" if absent.
    static func modelFromSettings() -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = obj["model"] as? String, !model.isEmpty
        else { return "" }
        return model
    }

    /// Reads effort/thinking level from `~/.claude/settings.json`. Falls back
    /// to "Auto" when the file is absent, unreadable, or has no effort key.
    static func effortFromSettings() -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "Auto" }

        // Direct "effort" / "effortLevel" string key (Claude Code uses both across versions)
        if let effort = (obj["effort"] as? String) ?? (obj["effortLevel"] as? String), !effort.isEmpty {
            return effort.prefix(1).uppercased() + effort.dropFirst()
        }
        // "thinking" dict with budget_tokens
        if let thinking = obj["thinking"] as? [String: Any] {
            if let budget = thinking["budget_tokens"] as? Int {
                if budget <= 0    { return "Low" }
                if budget >= 8000 { return "High" }
                return "Normal"
            }
            if let type_ = thinking["type"] as? String, type_ == "disabled" {
                return "Low"
            }
        }
        return "Auto"
    }

    /// Finds the most recently used model id by checking the newest transcript files.
    /// Read a transcript whole, refusing one that is absurdly large.
    ///
    /// sessionMeter has always had this guard; parseRecords and lastUsedModel
    /// did not, and compute() runs parseRecords over every transcript touched
    /// in the last four weeks, on a thirty-second timer. One oversized file
    /// meant a full Data plus a full String plus an array of substrings for it,
    /// repeatedly. The size is asked of the filesystem first so an oversized
    /// file is never opened at all.
    static func transcriptText(_ url: URL) -> String? {
        if let size = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size]) as? Int,
           size > maxTranscriptBytes { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Reads disk — call off the main thread. Returns "" if nothing found.
    static func lastUsedModel() -> String {
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let en = fm.enumerator(at: projects,
                                      includingPropertiesForKeys: [.contentModificationDateKey]) else { return "" }
        var files: [(url: URL, mod: Date)] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            if let mod = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]).contentModificationDate {
                files.append((url, mod))
            }
        }
        files.sort { $0.mod > $1.mod }
        for (url, _) in files.prefix(3) {
            guard let text = transcriptText(url) else { continue }
            for raw in text.split(separator: "\n").reversed() {
                guard let ld = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
                      let msg = obj["message"] as? [String: Any],
                      (msg["role"] as? String) == "assistant",
                      let model = msg["model"] as? String, !model.isEmpty else { continue }
                return model
            }
        }
        return ""
    }

    /// One assistant turn's usage, parsed once and kept so the file it came from
    /// need not be read and JSON-parsed again while it is unchanged. Bucketing
    /// these into the rolling day/week/5h windows is cheap and still happens every
    /// call, because those windows move with the clock; the read and the parse are
    /// the expensive part, and that is what the cache skips.
    struct UsageRecord {
        let ts: Date
        let model: String
        let tokens: Tokens
        let sessionId: String?
        let cwd: String
    }

    private struct CachedFile { let mod: Date; let size: Int; let records: [UsageRecord] }
    private static var fileCache: [String: CachedFile] = [:]
    private static let fileCacheLock = NSLock()

    private static let recordISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let recordISOPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    /// Parse one transcript into its billable usage records. Dedupes within the
    /// file (a turn is written as several lines that repeat the same usage), which
    /// is enough: message ids are unique to a session, and a session is one file.
    private static func parseRecords(_ url: URL) -> [UsageRecord] {
        guard let text = transcriptText(url) else { return [] }
        var billed = Set<String>()
        var out: [UsageRecord] = []
        for line in text.split(separator: "\n") {
            guard let ld = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  (msg["role"] as? String) == "assistant",
                  let u = msg["usage"] as? [String: Any],
                  let tsStr = obj["timestamp"] as? String,
                  let ts = recordISO.date(from: tsStr) ?? recordISOPlain.date(from: tsStr),
                  isFirstLine(of: msg, seen: &billed)
            else { continue }
            let model = (msg["model"] as? String) ?? "unknown"
            let input = (u["input_tokens"] as? Int) ?? 0
            let output = (u["output_tokens"] as? Int) ?? 0
            let cacheRead = (u["cache_read_input_tokens"] as? Int) ?? 0
            let cacheCreation = (u["cache_creation_input_tokens"] as? Int) ?? 0
            let c = cost(input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation, model: model)
            out.append(UsageRecord(
                ts: ts,
                model: model,
                tokens: Tokens(input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation, costUSD: c),
                sessionId: obj["sessionId"] as? String,
                cwd: (obj["cwd"] as? String) ?? ""))
        }
        return out
    }

    /// Parse recent transcripts. Reads files off disk, so call off the main thread.
    static func compute() -> Usage {
        var usage = Usage()
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)

        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        // Last 7 days INCLUDING today: today plus the six days before it. Using
        // -7 here spanned eight day-buckets (day-7 through today), which made the
        // "this week" totals disagree with the 7-day trend chart that sums seven.
        let weekAgo = cal.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        // Daily cost/token maps reach back four weeks for the trend chart; every
        // other total stays week-scoped. Files older than this can't contribute.
        let monthAgo = cal.date(byAdding: .day, value: -28, to: startOfToday) ?? startOfToday
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)

        guard let en = fm.enumerator(at: projects,
                                     includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return usage
        }

        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"

        var sessionsTodaySet = Set<String>()
        var sessionsWeekSet = Set<String>()
        var seenPaths = Set<String>()

        for case let url as URL in en {
            guard url.pathExtension == "jsonl" else { continue }
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mod = vals?.contentModificationDate ?? .distantPast
            let size = vals?.fileSize ?? 0
            // Skip files untouched in the last four weeks — they can't hold data
            // for either the week totals or the trend chart.
            if mod < monthAgo { continue }
            seenPaths.insert(url.path)

            // Reuse the parse if the file is byte-for-byte the same as last time.
            let cached = fileCacheLock.withLock { fileCache[url.path] }
            let records: [UsageRecord]
            if let cached, cached.mod == mod, cached.size == size {
                records = cached.records
            } else {
                records = parseRecords(url)
                fileCacheLock.withLock { fileCache[url.path] = CachedFile(mod: mod, size: size, records: records) }
            }

            for r in records where r.ts >= monthAgo {
                let t = r.tokens
                // Daily maps span the full four weeks (drive the trend chart).
                let day = dayFmt.string(from: r.ts)
                usage.dailyTokens[day, default: 0] += t.total
                usage.dailyCostUSD[day, default: 0] += t.costUSD

                // Everything else stays week-scoped, exactly as before, so no
                // existing total changes when the scan window widened.
                guard r.ts >= weekAgo else { continue }
                usage.week = usage.week + t
                usage.weekByModel[shortModel(r.model), default: Tokens()] += t
                if !r.cwd.isEmpty { usage.weekByProject[r.cwd, default: Tokens()] += t }
                usage.hourCounts[cal.component(.hour, from: r.ts), default: 0] += 1
                usage.cacheSavingsUSD += cacheSavings(cacheRead: t.cacheRead, model: r.model)
                if let sid = r.sessionId { sessionsWeekSet.insert(sid) }
                if r.ts >= startOfToday {
                    usage.today = usage.today + t
                    if let sid = r.sessionId { sessionsTodaySet.insert(sid) }
                }
                if r.ts >= fiveHoursAgo { usage.fiveHour = usage.fiveHour + t }
            }
        }

        // Drop cache entries for files that have aged out or been removed, so the
        // cache tracks the working set rather than growing without bound.
        fileCacheLock.withLock { fileCache = fileCache.filter { seenPaths.contains($0.key) } }

        usage.sessionsToday = sessionsTodaySet.count
        usage.sessionsWeek = sessionsWeekSet.count
        usage.computedAt = Date()
        return usage
    }

    /// Live per-session meter for the notch: how full the context window is right
    /// now and how much the session has cost so far.
    struct SessionMeter {
        var contextTokens = 0          // input-side tokens of the most recent turn
        var contextPercent: Double = 0 // contextTokens / contextWindow (0...1)
        var costUSD: Double = 0         // cumulative across the whole session
        var model = ""                 // most recent model id
    }

    // Standard context window for Opus/Sonnet 4.x. The 1M-token window is a
    // separate mode the transcript doesn't flag, so we infer it from the model
    // (and escalate if we ever observe more than the standard window).
    static let contextWindow = 200_000
    static let contextWindow1M = 1_000_000

    /// True for models whose default window is 1M on the plans this app targets
    /// (Max). Haiku and older frontier models are 200k.
    ///
    /// This used to be a list of model names, which went stale the moment
    /// Anthropic shipped the next one: Opus 4.8 landed with a 1M window, was not
    /// in the list, and so a session sitting at 161k of a 1M window was drawn as
    /// 161k/200k with the bar in the red — a 16%-full context reported as nearly
    /// full. (The transcript settles it: this session ran past 600k tokens before
    /// it compacted, which a 200k window cannot do.)
    ///
    /// So the version is parsed rather than matched. Frontier models from Sonnet
    /// 4.6 and Opus 4.6 onward carry the 1M window, and anything newer than
    /// those inherits it instead of silently falling back to 200k. `.auto` also
    /// escalates on evidence — see `contextWindow(forModel:tokens:mode:)` — so
    /// even a model this rule guesses wrong about corrects itself in use.
    static func modelHas1MWindow(_ model: String) -> Bool {
        let m = model.lowercased()
        // Haiku is the small, fast model and stays on 200k however new it gets.
        if m.contains("haiku") { return false }
        // Everything else frontier, from the 4.6 generation on, carries 1M — and
        // that includes families that did not exist when this was written, which
        // is the whole point. A model id we can't read a version out of keeps the
        // conservative 200k.
        guard let version = modelVersion(m) else { return false }
        return version >= 4.6
    }

    /// The version out of a model id: "claude-opus-4-8" → 4.8, "claude-sonnet-5" → 5.
    static func modelVersion(_ model: String) -> Double? {
        // Take the digit groups after the family name: 4-8 → 4.8, 5 → 5.0.
        let parts = model.split(separator: "-").drop { !$0.allSatisfy(\.isNumber) }
        let numbers = parts.prefix { $0.allSatisfy(\.isNumber) }.compactMap { Int($0) }
        guard let major = numbers.first else { return nil }
        let minor = numbers.count > 1 ? numbers[1] : 0
        // A date stamp (claude-haiku-4-5-20251001) is not a minor version.
        return Double(major) + (minor < 10 ? Double(minor) / 10 : 0)
    }

    /// Pick the context-window denominator for a session given the user's mode,
    /// the model, and the largest occupancy observed (which forces 1M if it ever
    /// exceeds the standard window, regardless of model guess).
    static func contextWindow(forModel model: String, tokens: Int, mode: ContextWindowMode) -> Int {
        switch mode {
        case .w200k: return contextWindow
        case .w1M:   return contextWindow1M
        case .auto:
            if tokens > contextWindow { return contextWindow1M }
            return modelHas1MWindow(model) ? contextWindow1M : contextWindow
        }
    }

    /// Context occupancy as 0...1 for the given mode/model. Authoritative %
    /// computation lives here so callers (transcript meter, header mirror) agree.
    static func contextPercent(tokens: Int, model: String, mode: ContextWindowMode) -> Double {
        let window = contextWindow(forModel: model, tokens: tokens, mode: mode)
        return min(1, Double(tokens) / Double(window))
    }

    /// Parse ONE session transcript: sum cost across every assistant message and
    /// take the latest turn's input-side tokens as the live context occupancy.
    /// Reads the file off disk — call off the main thread. Returns nil if the
    /// file can't be read or has no assistant usage yet.
    /// A transcript this big is not a real session — it is either broken or a
    /// path the app was pointed at to make it read something huge into memory.
    /// (`transcriptPath` arrives on the hook, so it is not fully under our
    /// control.) Real transcripts run to tens of megabytes; a quarter of a
    /// gigabyte is a comfortable ceiling that still refuses the abuse case.
    static let maxTranscriptBytes = 256 * 1024 * 1024

    static func sessionMeter(transcriptPath path: String) -> SessionMeter? {
        guard !path.isEmpty else { return nil }
        guard let text = transcriptText(URL(fileURLWithPath: path)) else { return nil }

        var meter = SessionMeter()
        var sawUsage = false
        var billed = Set<String>()   // message.id — see `isFirstLine(of:seen:)`
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let ld = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any]
            else { continue }

            // The compaction boundary. Everything above it is no longer in the
            // window: the session now holds a summary of it. The occupancy of
            // the last turn before a compaction is the single most misleading
            // number the meter can show — it is the reading that made the bar
            // sit in the red immediately after the compaction that emptied it.
            //
            // How full the window is now cannot be known until the next turn
            // reports its own usage, and 0 is the honest stand-in: it is what
            // the session is closest to, and the next turn corrects it.
            if (obj["isCompactSummary"] as? Bool) == true {
                meter.contextTokens = 0
                continue
            }

            guard let msg = obj["message"] as? [String: Any],
                  (msg["role"] as? String) == "assistant",
                  let u = msg["usage"] as? [String: Any]
            else { continue }

            let model = (msg["model"] as? String) ?? meter.model
            let input = (u["input_tokens"] as? Int) ?? 0
            let output = (u["output_tokens"] as? Int) ?? 0
            let cacheRead = (u["cache_read_input_tokens"] as? Int) ?? 0
            let cacheCreation = (u["cache_creation_input_tokens"] as? Int) ?? 0

            sawUsage = true
            // Subagent (Task) turns are real spend, so their cost counts — the
            // 7-day project/usage totals include them, and the session meter has
            // to agree or the notch's per-session cost never sums to the project
            // figure. (This skip used to swallow their cost entirely.)
            //
            // Charged once per message, not once per line: one API response is
            // written out as several lines that all repeat the same usage.
            if isFirstLine(of: msg, seen: &billed) {
                meter.costUSD += cost(input: input, output: output,
                                      cacheRead: cacheRead, cacheCreation: cacheCreation, model: model)
            }

            // But subagents run in their own small, fresh context (shared in the
            // transcript as `isSidechain: true`), so the live context/model
            // readings must come only from the MAIN thread's latest turn —
            // treating a subagent turn as "latest" would crater the occupancy.
            if (obj["isSidechain"] as? Bool) == true { continue }
            meter.model = model
            meter.contextTokens = input + cacheRead + cacheCreation
        }
        guard sawUsage else { return nil }
        // Self-consistent default; callers with the user's ContextWindowMode
        // recompute via `contextPercent(tokens:model:mode:)`.
        meter.contextPercent = contextPercent(tokens: meter.contextTokens, model: meter.model, mode: .auto)
        return meter
    }

    static func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1_000_000_000) }
        if n >= 1_000_000     { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000         { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    static func fmtMoney(_ d: Double) -> String {
        d >= 100 ? String(format: "$%.0f", d) : String(format: "$%.2f", d)
    }
}
