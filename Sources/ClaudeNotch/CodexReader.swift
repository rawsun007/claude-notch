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

    struct CodexTotals {
        var todayTokens = 0, weekTokens = 0
        var sessionsToday = 0, sessionsWeek = 0
        var isEmpty: Bool { weekTokens == 0 && sessionsWeek == 0 }
    }

    /// Token totals for today and the last 7 days across Codex rollouts. Tokens
    /// only, no dollar cost (gpt pricing unknown). Approximate: a session's
    /// cumulative token total is attributed to its last-modified day.
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
            guard mtime >= weekAgo else { continue }
            let tokens = finalTotalTokens(url)
            guard tokens > 0 else { continue }
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
        guard !cwd.isEmpty else { return "" }
        var dir = URL(fileURLWithPath: cwd)
        for _ in 0..<8 {
            let head = dir.appendingPathComponent(".git/HEAD")
            if let s = try? String(contentsOf: head, encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = "ref: refs/heads/"
                return t.hasPrefix(prefix) ? String(t.dropFirst(prefix.count)) : ""
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return ""
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
    /// string. Keys are unquoted JS (`step:`, `status:"completed"`).
    nonisolated static func planCounts(from js: String) -> (total: Int, done: Int)? {
        let total = js.components(separatedBy: "step:").count - 1
        guard total > 0 else { return nil }
        let done = js.components(separatedBy: "status:\"completed\"").count - 1
        return (total, min(done, total))
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

    /// Find the rollout file whose name contains this session id.
    private nonisolated static func rolloutURL(forSessionId id: String) -> URL? {
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
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: bytes)) ?? Data()
        guard var s = String(data: data, encoding: .utf8) else { return nil }
        if data.count == bytes, let nl = s.lastIndex(of: "\n") { s = String(s[..<nl]) }
        return s
    }

    private nonisolated static func readTail(_ url: URL, bytes: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        guard var s = String(data: data, encoding: .utf8) else { return nil }
        if start > 0, let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
        return s
    }
}
