import Foundation

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
    }

    struct Usage {
        var today = Tokens()
        var week = Tokens()
        var weekByModel: [String: Tokens] = [:]
        var weekByProject: [String: Tokens] = [:]   // keyed by cwd
        var sessionsToday = 0
        var sessionsWeek = 0
        var computedAt = Date()
        var hasData: Bool { week.total > 0 }

        /// Fraction of input-side tokens served from the prompt cache (0...1).
        var cacheHitRate: Double {
            let inputSide = week.input + week.cacheCreation + week.cacheRead
            return inputSide > 0 ? Double(week.cacheRead) / Double(inputSide) : 0
        }
    }

    // Public per-million-token pricing, used only to estimate cost.
    private static func price(for model: String) -> (input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        let m = model.lowercased()
        if m.contains("opus")  { return (15, 75, 18.75, 1.5) }
        if m.contains("haiku") { return (1, 5, 1.25, 0.1) }
        return (3, 15, 3.75, 0.3)   // default to Sonnet pricing
    }

    private static func cost(input: Int, output: Int, cacheRead: Int, cacheCreation: Int, model: String) -> Double {
        let p = price(for: model)
        return Double(input) / 1_000_000 * p.input
             + Double(output) / 1_000_000 * p.output
             + Double(cacheCreation) / 1_000_000 * p.cacheWrite
             + Double(cacheRead) / 1_000_000 * p.cacheRead
    }

    /// Last path component of a working directory, e.g. ".../claude mac app" → "claude mac app".
    static func projectName(_ cwd: String) -> String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    static func shortModel(_ model: String) -> String {
        let m = model.lowercased()
        if m.contains("opus")   { return "opus" }
        if m.contains("sonnet") { return "sonnet" }
        if m.contains("haiku")  { return "haiku" }
        return model
    }

    /// Parse recent transcripts. Reads files off disk, so call off the main thread.
    static func compute() -> Usage {
        var usage = Usage()
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)

        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let weekAgo = cal.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday

        guard let en = fm.enumerator(at: projects, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return usage
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        var sessionsTodaySet = Set<String>()
        var sessionsWeekSet = Set<String>()

        for case let url as URL in en {
            guard url.pathExtension == "jsonl" else { continue }
            // Skip files untouched in the last 7 days — they can't hold recent usage.
            if let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               mod < weekAgo {
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }

            for line in text.split(separator: "\n") {
                guard let ld = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
                      let msg = obj["message"] as? [String: Any],
                      (msg["role"] as? String) == "assistant",
                      let u = msg["usage"] as? [String: Any],
                      let tsStr = obj["timestamp"] as? String,
                      let ts = iso.date(from: tsStr) ?? isoPlain.date(from: tsStr),
                      ts >= weekAgo
                else { continue }

                let model = (msg["model"] as? String) ?? "unknown"
                let input = (u["input_tokens"] as? Int) ?? 0
                let output = (u["output_tokens"] as? Int) ?? 0
                let cacheRead = (u["cache_read_input_tokens"] as? Int) ?? 0
                let cacheCreation = (u["cache_creation_input_tokens"] as? Int) ?? 0
                let c = cost(input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation, model: model)
                let t = Tokens(input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation, costUSD: c)
                let key = shortModel(model)
                let sid = obj["sessionId"] as? String
                let cwd = (obj["cwd"] as? String) ?? ""

                usage.week = usage.week + t
                usage.weekByModel[key, default: Tokens()] = usage.weekByModel[key, default: Tokens()] + t
                if !cwd.isEmpty {
                    usage.weekByProject[cwd, default: Tokens()] = usage.weekByProject[cwd, default: Tokens()] + t
                }
                if let sid { sessionsWeekSet.insert(sid) }
                if ts >= startOfToday {
                    usage.today = usage.today + t
                    if let sid { sessionsTodaySet.insert(sid) }
                }
            }
        }

        usage.sessionsToday = sessionsTodaySet.count
        usage.sessionsWeek = sessionsWeekSet.count
        usage.computedAt = Date()
        return usage
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
