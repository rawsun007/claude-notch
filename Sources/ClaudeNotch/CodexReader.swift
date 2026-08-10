import Foundation

/// Reads OpenAI Codex CLI session rollouts from `~/.codex/sessions/**/rollout-*.jsonl`.
///
/// Codex's format differs from Claude's: each line is `{type, timestamp, payload}`,
/// where `session_meta` carries the cwd/session id/context window, `turn_context`
/// carries the model, and `event_msg` of type `token_count` carries cumulative
/// token usage in `info.total_token_usage`. We surface context/token usage
/// (factual) but deliberately NOT a dollar cost, since reliable gpt pricing
/// isn't known and a fabricated cost would mislead on a flat-fee plan.
enum CodexReader {

    struct CodexUsage {
        var contextTokens: Int      // input-side tokens in the context now
        var totalTokens: Int        // cumulative tokens this session
        var contextWindow: Int      // model window (0 = unknown)
        var model: String
    }

    /// One usage window off Codex's own `rate_limits` block, which rides along
    /// on every `token_count` line. Codex plans do not all share a shape: a Go
    /// plan reports a single 30-day window, others report a short window plus a
    /// longer one, so the window length is data rather than something to
    /// hardcode. `windowMinutes` is what names it.
    struct CodexLimit: Equatable {
        var usedPercent: Double     // 0...100
        var windowMinutes: Int      // 300 = 5-hour, 10080 = weekly, 43200 = monthly
        var resetsAt: Date?
        var isPrimary: Bool

        /// "Weekly limit", "5-hour limit", "Monthly limit" — derived from the
        /// window itself so a plan shape we have never seen still reads as
        /// something true rather than as whichever label was hardcoded.
        var label: String { CodexReader.limitLabel(windowMinutes: windowMinutes) }
    }

    struct CodexLimits: Equatable {
        var limits: [CodexLimit]
        var planType: String?       // "go", "plus", "pro"…
        var hasCredits: Bool
        var unlimitedCredits: Bool
        var creditBalance: Double?
        var isEmpty: Bool { limits.isEmpty }
    }

    private static var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// Every resumable Codex session on disk, newest first. Reuses the
    /// ResumableSession shape so the notch resume UI can show Codex sessions
    /// alongside Claude ones; `model` marks it as Codex.
    nonisolated static func allSessions(limit: Int = 200) -> [ResumableSession] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: sessionsDir,
                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in en where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, m))
        }
        files.sort { $0.1 > $1.1 }
        var out: [ResumableSession] = []
        for (url, mtime) in files.prefix(limit) {
            if let s = parseSession(url: url, mtime: mtime) { out.append(s) }
        }
        return out
    }

    /// Context/token usage for a live session id, from the tail of its rollout
    /// (the last `token_count` line is cumulative). Returns nil if the rollout
    /// can't be found or has no usage yet.
    nonisolated static func usage(forSessionId sessionId: String) -> CodexUsage? {
        guard !sessionId.isEmpty, let url = rolloutURL(forSessionId: sessionId) else { return nil }
        return usage(from: url)
    }

    /// Same, for a known rollout file. Split out so it can be unit-tested
    /// against a fixture without touching ~/.codex.
    nonisolated static func usage(from url: URL) -> CodexUsage? {
        guard let tail = readTail(url, bytes: 96 * 1024) else { return nil }
        var contextTokens = 0, totalTokens = 0, window = 0
        var model = ""
        for line in tail.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { continue }
            let type = (payload["type"] as? String) ?? ""
            if type == "token_count", let info = payload["info"] as? [String: Any],
               let total = info["total_token_usage"] as? [String: Any] {
                // total_token_usage is CUMULATIVE across the whole session, so it
                // blows past the window. Current context occupancy is the LAST
                // turn's input tokens (prompt + cache for that request).
                totalTokens = (total["total_tokens"] as? Int) ?? 0
                let last = info["last_token_usage"] as? [String: Any]
                contextTokens = (last?["input_tokens"] as? Int) ?? (total["input_tokens"] as? Int) ?? 0
                if window == 0 {
                    window = ((payload["info"] as? [String: Any])?["model_context_window"] as? Int) ?? 0
                }
                break
            }
        }
        // Window + model from the head if the tail didn't carry them.
        if window == 0 || model.isEmpty {
            if let head = readHead(url, bytes: 32 * 1024) {
                for line in head.split(separator: "\n") {
                    guard let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let p = obj["payload"] as? [String: Any] else { continue }
                    if window == 0 { window = (p["model_context_window"] as? Int) ?? (p["context_window"] as? Int) ?? window }
                    if model.isEmpty, let m = p["model"] as? String { model = m }
                    if window > 0 && !model.isEmpty { break }
                }
            }
        }
        guard contextTokens > 0 || totalTokens > 0 else { return nil }
        return CodexUsage(contextTokens: contextTokens, totalTokens: totalTokens,
                          contextWindow: window, model: model)
    }

    // MARK: - Rate limits

    /// Name a usage window by its length. Matched with tolerance because the
    /// numbers come from someone else's API: a window a few minutes either side
    /// of a week is still the weekly one.
    nonisolated static func limitLabel(windowMinutes: Int) -> String {
        switch windowMinutes {
        case 0:                 return "Usage limit"
        case ..<120:            return "\(max(1, windowMinutes / 60))-hour limit"
        case 120..<1_380:       return "\(windowMinutes / 60)-hour limit"
        case 1_380..<1_500:     return "Daily limit"
        case 1_500..<11_000:    return "Weekly limit"
        case 11_000..<50_000:   return "Monthly limit"
        default:                return "\(windowMinutes / 1_440)-day limit"
        }
    }

    /// The newest rate-limit reading for a session, from the last `token_count`
    /// line in its rollout. Codex sends this on every turn, so the tail is
    /// current. Returns nil when the rollout carries no rate_limits block
    /// (older Codex builds, or an API-key session with no plan attached).
    nonisolated static func limits(from url: URL) -> CodexLimits? {
        guard let tail = readTail(url, bytes: 96 * 1024) else { return nil }
        for line in tail.split(separator: "\n").reversed() {
            guard line.contains("rate_limits"),
                  let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let p = obj["payload"] as? [String: Any],
                  let rl = p["rate_limits"] as? [String: Any]
            else { continue }
            return parseLimits(rl)
        }
        return nil
    }

    /// Split out so the shape can be tested without a rollout on disk. Every
    /// field is optional: this is another program's payload, so a key that
    /// changes name upstream has to read as a missing row, never a crash.
    nonisolated static func parseLimits(_ rl: [String: Any]) -> CodexLimits? {
        var out: [CodexLimit] = []
        for (key, isPrimary) in [("primary", true), ("secondary", false)] {
            guard let w = rl[key] as? [String: Any],
                  let pct = numberValue(w["used_percent"]) else { continue }
            let resets = numberValue(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            out.append(CodexLimit(usedPercent: min(100, max(0, pct)),
                                  windowMinutes: Int(numberValue(w["window_minutes"]) ?? 0),
                                  resetsAt: resets,
                                  isPrimary: isPrimary))
        }
        let credits = rl["credits"] as? [String: Any]
        let limits = CodexLimits(
            limits: out,
            planType: (rl["plan_type"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            hasCredits: (credits?["has_credits"] as? Bool) ?? false,
            unlimitedCredits: (credits?["unlimited"] as? Bool) ?? false,
            creditBalance: numberValue(credits?["balance"]))
        // A reading with no windows and no plan says nothing worth a row.
        return limits.isEmpty && limits.planType == nil ? nil : limits
    }

    /// Numbers arrive as Int, Double or String depending on the field.
    nonisolated static func numberValue(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// The newest rate-limit reading across all Codex rollouts. The limits are
    /// per account, not per session, so the most recently touched rollout that
    /// carries a reading is the current one.
    nonisolated static func latestLimits(searchLimit: Int = 12) -> CodexLimits? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: sessionsDir,
                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else { return nil }
        var files: [(URL, Date)] = []
        for case let url as URL in en
            where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, m))
        }
        files.sort { $0.1 > $1.1 }
        for (url, _) in files.prefix(searchLimit) {
            if let l = limits(from: url) { return l }
        }
        return nil
    }

    struct CodexTotals {
        var todayTokens = 0, weekTokens = 0
        var sessionsToday = 0, sessionsWeek = 0
        /// Every rollout still on disk, however old. Not "everything Codex has
        /// ever done": Codex prunes its own session files, and anything it has
        /// removed cannot be counted.
        var allTimeTokens = 0, allTimeSessions = 0
        /// Empty when there is nothing to show at all. A week with no Codex work
        /// still has a history worth a row, so the all-time figure counts too.
        var isEmpty: Bool { weekTokens == 0 && sessionsWeek == 0 && allTimeTokens == 0 }
    }

    /// Token totals for today, the last 7 days, and every rollout on disk.
    /// Tokens only, no dollar cost (gpt pricing unknown). Approximate: a
    /// session's cumulative token total is attributed to its last-modified day.
    nonisolated static func tokenTotals() -> CodexTotals {
        let fm = FileManager.default
        var totals = CodexTotals()
        guard let en = fm.enumerator(at: sessionsDir,
                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else { return totals }
        let cal = Calendar.current
        let now = Date()
        let weekAgo = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now)) ?? now
        for case let url as URL in en
            where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            // Read every rollout, not only this week's: the all-time figure
            // needs the old ones too. Each read is a bounded tail, and the
            // walk itself already visited them.
            let tokens = finalTotalTokens(url)
            guard tokens > 0 else { continue }
            totals.allTimeTokens += tokens
            totals.allTimeSessions += 1
            guard mtime >= weekAgo else { continue }
            totals.weekTokens += tokens
            totals.sessionsWeek += 1
            if cal.isDateInToday(mtime) {
                totals.todayTokens += tokens
                totals.sessionsToday += 1
            }
        }
        return totals
    }

    /// Cumulative total_tokens for a rollout, from its last token_count line.
    private nonisolated static func finalTotalTokens(_ url: URL) -> Int {
        guard let tail = readTail(url, bytes: 64 * 1024) else { return 0 }
        for line in tail.split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let p = obj["payload"] as? [String: Any],
                  (p["type"] as? String) == "token_count",
                  let info = p["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any] else { continue }
            return (total["total_tokens"] as? Int) ?? 0
        }
        return 0
    }

    /// The last assistant reply in a Codex rollout, for the resume-row preview.
    /// Codex writes the clean text as an `event_msg` of type `agent_message`
    /// (payload.message); we scan the tail for the newest one.
    nonisolated static func lastReply(from url: URL, tailBytes: Int = 96 * 1024) -> String? {
        guard let tail = readTail(url, bytes: tailBytes) else { return nil }
        for line in tail.split(separator: "\n").reversed() {
            guard line.contains("agent_message"),
                  let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let p = obj["payload"] as? [String: Any],
                  (p["type"] as? String) == "agent_message",
                  let msg = p["message"] as? String else { continue }
            let cleaned = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            if !cleaned.isEmpty { return String(cleaned.prefix(160)) }
        }
        return nil
    }

    /// Current git branch for a directory, read straight from `.git/HEAD`
    /// (no status line needed). Walks up to find the repo. Returns "" when not
    /// a repo or detached HEAD.
    nonisolated static func gitBranch(forCwd cwd: String) -> String {
        Git.branch(forCwd: cwd)
    }

    /// The current plan progress for a live Codex session, parsed from the most
    /// recent `update_plan` call in its rollout. Codex tracks tasks by calling
    /// `tools.update_plan({plan:[{step,status}...]})` inside an `exec` tool, so
    /// the plan lives in the command string. Returns (total, done) or nil.
    nonisolated static func latestPlan(forSessionId sessionId: String) -> (total: Int, done: Int)? {
        guard !sessionId.isEmpty, let url = rolloutURL(forSessionId: sessionId) else { return nil }
        return latestPlan(from: url)
    }

    /// Same, for a known rollout file (unit-testable against a fixture).
    nonisolated static func latestPlan(from url: URL) -> (total: Int, done: Int)? {
        guard let tail = readTail(url, bytes: 128 * 1024) else { return nil }
        for line in tail.split(separator: "\n").reversed() {
            guard line.contains("update_plan"),
                  let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let p = obj["payload"] as? [String: Any],
                  let input = p["input"] as? String, input.contains("update_plan")
            else { continue }
            return planCounts(from: input)
        }
        return nil
    }

    /// Count plan steps and completed steps in an update_plan JS argument
    /// string. Keys are unquoted JS: `{step:"…",status:"completed"}`.
    ///
    /// Counted off the `status` key rather than raw substrings. Every step
    /// carries exactly one status, so statuses count the steps, and a step
    /// whose own text happens to contain "step:" no longer inflates the total
    /// (`{step:"Problem 1: redo step: two"}` used to count as two steps).
    /// Whitespace around the colon is allowed, which the old literal
    /// `status:"completed"` match would have missed entirely.
    nonisolated static func planCounts(from js: String) -> (total: Int, done: Int)? {
        let statuses = matches(in: js, pattern: #"(?:^|[{,])\s*status\s*:\s*"([A-Za-z_]+)""#)
        if !statuses.isEmpty {
            return (statuses.count, statuses.filter { $0 == "completed" }.count)
        }
        // No status keys at all: fall back to counting `step` keys, anchored to
        // a key position so free text still cannot inflate it.
        let steps = matches(in: js, pattern: #"(?:^|[{,])\s*step\s*:"#)
        guard !steps.isEmpty else { return nil }
        return (steps.count, 0)
    }

    /// Capture group 1 of every match, or the whole match when the pattern has
    /// no group. Empty when the pattern is unusable, so a caller degrades to
    /// "no plan" rather than crashing.
    private nonisolated static func matches(in s: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.matches(in: s, range: range).map { m in
            let g = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
            guard let r = Range(g, in: s) else { return "" }
            return String(s[r])
        }
    }

    // MARK: - Parsing

    private nonisolated static func parseSession(url: URL, mtime: Date) -> ResumableSession? {
        guard let head = readHead(url, bytes: 128 * 1024) else { return nil }
        var cwd = "", model = "", sessionId = "", title = ""
        for line in head.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let p = obj["payload"] as? [String: Any] else { continue }
            let type = (obj["type"] as? String) ?? ""
            if type == "session_meta" {
                cwd = (p["cwd"] as? String) ?? cwd
                sessionId = (p["session_id"] as? String) ?? (p["id"] as? String) ?? sessionId
            }
            if type == "turn_context", model.isEmpty { model = (p["model"] as? String) ?? "" }
            if title.isEmpty, type == "response_item", (p["role"] as? String) == "user" {
                title = firstUserText(p["content"]) ?? ""
            }
            if !cwd.isEmpty && !model.isEmpty && !title.isEmpty && !sessionId.isEmpty { break }
        }
        // Session id also lives in the filename: rollout-<ts>-<uuid>.jsonl
        if sessionId.isEmpty {
            let stem = url.deletingPathExtension().lastPathComponent
            if let r = stem.range(of: "-", options: .backwards) { sessionId = String(stem[r.upperBound...]) }
        }
        guard !cwd.isEmpty, !sessionId.isEmpty else { return nil }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        // Codex is marked as a Codex session via its model id (gpt-*).
        return ResumableSession(
            id: sessionId,
            cwd: cwd,
            project: (cwd as NSString).lastPathComponent,
            title: cleaned.isEmpty ? "(no prompt yet)" : String(cleaned.prefix(120)),
            lastActive: mtime,
            model: model.isEmpty ? "gpt" : model,
            fileURL: url)
    }

    /// First real user prompt, skipping Codex's injected environment_context and
    /// developer/system blocks.
    private nonisolated static func firstUserText(_ content: Any?) -> String? {
        guard let parts = content as? [[String: Any]] else {
            return content as? String
        }
        for p in parts where (p["type"] as? String)?.contains("text") == true {
            if let t = p["text"] as? String, !t.hasPrefix("<environment_context"), !t.hasPrefix("<") {
                return t
            }
        }
        return nil
    }

    /// Find the rollout file whose name contains this session id. Walks the
    /// whole `~/.codex/sessions` tree, so a caller that needs several readings
    /// for one session should resolve the URL ONCE and use the `from:` variants
    /// rather than paying for the walk per reading.
    nonisolated static func rolloutURL(forSessionId id: String) -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: sessionsDir, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in en
            where url.pathExtension == "jsonl" && url.lastPathComponent.contains(id) {
            return url
        }
        return nil
    }

    private nonisolated static func readHead(_ url: URL, bytes: Int) -> String? {
        FileSlice.head(url, bytes: bytes)
    }

    private nonisolated static func readTail(_ url: URL, bytes: Int) -> String? {
        FileSlice.tail(url, bytes: bytes)
    }
}
