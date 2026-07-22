import Foundation

/// One past Claude Code session found on disk, resumable via `claude --resume`.
///
/// Claude Code writes every session to
/// `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. The filename is the
/// `session_id` you pass to `--resume`; the real working directory and a title
/// live inside the file (the directory name is a lossy dash-encoding of the
/// path, so we never trust it for the cwd).
struct ResumableSession: Identifiable, Equatable {
    let id: String            // session_id == filename stem, passed to --resume
    let cwd: String           // real working directory, read from the transcript
    let project: String       // basename of cwd
    let title: String         // first user prompt, trimmed to one line
    let lastActive: Date      // file modification time
    let model: String         // most recent model id seen in the head
    let fileURL: URL          // transcript path, for lazy preview / delete

    var relativeLastActive: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: lastActive, relativeTo: Date())
    }
}

/// Reads the on-disk Claude Code session transcripts so the app can offer to
/// resume one after a terminal was closed. All work is `nonisolated` and meant
/// to run off the main thread — the project directory can hold hundreds of
/// multi-megabyte files, so each is parsed from a bounded head chunk only.
enum SessionResumer {

    private static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Every resumable session on disk, newest first. Sessions whose transcript
    /// carries no real cwd (scratch/stub files) are skipped — they can't be
    /// meaningfully resumed in a project directory.
    nonisolated static func allSessions(limit: Int = 400) -> [ResumableSession] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var files: [(url: URL, mtime: Date)] = []
        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let entries = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]) else { continue }
            for f in entries where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                files.append((f, m))
            }
        }

        // Newest first, and cap the number we actually parse.
        files.sort { $0.mtime > $1.mtime }
        var out: [ResumableSession] = []
        for (url, mtime) in files.prefix(limit) {
            if let s = parse(url: url, mtime: mtime) { out.append(s) }
        }
        return out
    }

    /// Sessions grouped by cwd, each group newest-first, groups ordered by their
    /// most-recent session. Drives the "expand a project to its sessions" UI.
    nonisolated static func sessionsByProject(limit: Int = 400) -> [(cwd: String, project: String, sessions: [ResumableSession])] {
        group(allSessions(limit: limit))
    }

    /// Resumable sessions grouped by project. Codex sessions are merged in only
    /// when Codex support is enabled, so a Claude-only user's list stays pure
    /// Claude.
    nonisolated static func allAgentSessionsByProject(limit: Int = 400, includeCodex: Bool) -> [(cwd: String, project: String, sessions: [ResumableSession])] {
        var merged = allSessions(limit: limit)
        if includeCodex { merged += CodexReader.allSessions() }
        return group(merged.sorted { $0.lastActive > $1.lastActive })
    }

    /// Group sessions by cwd, groups ordered by their most-recent session.
    nonisolated static func group(_ sessions: [ResumableSession]) -> [(cwd: String, project: String, sessions: [ResumableSession])] {
        var order: [String] = []
        var byCwd: [String: [ResumableSession]] = [:]
        for s in sessions {
            if byCwd[s.cwd] == nil { order.append(s.cwd) }
            byCwd[s.cwd, default: []].append(s)
        }
        return order.map { cwd in
            (cwd, (cwd as NSString).lastPathComponent, byCwd[cwd] ?? [])
        }
    }

    /// The single most recent resumable session overall, if any. Powers a
    /// one-click "resume where I left off" after an accidental terminal close.
    nonisolated static func mostRecent() -> ResumableSession? {
        allSessions(limit: 40).first
    }

    /// A coarse recency bucket for grouping the session list by day. Pure and
    /// deterministic given `asOf`, so it is unit-tested.
    nonisolated static func dayBucket(_ date: Date, asOf: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: asOf) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: asOf),
           calendar.isDate(date, inSameDayAs: y) { return "Yesterday" }
        let startToday = calendar.startOfDay(for: asOf)
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: startToday), date >= weekAgo {
            return "Earlier this week"
        }
        return "Older"
    }

    /// Move a session transcript to the Trash (recoverable — never a hard
    /// delete). Returns true on success.
    @discardableResult
    nonisolated static func trash(_ url: URL) -> Bool {
        (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
    }

    // MARK: - Parsing

    /// Pull cwd, first user prompt and model from the head of a transcript.
    /// Only the first ~256 KB is read — enough to reach the first real message
    /// without loading a huge file.
    private nonisolated static func parse(url: URL, mtime: Date) -> ResumableSession? {
        guard let head = readHead(url, bytes: 256 * 1024) else { return nil }

        var cwd: String?
        var title: String?
        var model: String?

        for line in head.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }

            if let msg = obj["message"] as? [String: Any] {
                if let m = msg["model"] as? String, !m.isEmpty, m != "<synthetic>" { model = m }
                if title == nil, (msg["role"] as? String) == "user" {
                    title = firstText(from: msg["content"])
                }
            }
            // Stop early once we have everything worth showing.
            if cwd != nil, title != nil, model != nil { break }
        }

        guard let realCwd = cwd else { return nil }   // stub/scratch session
        let id = url.deletingPathExtension().lastPathComponent
        let cleaned = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return ResumableSession(
            id: id,
            cwd: realCwd,
            project: (realCwd as NSString).lastPathComponent,
            title: cleaned.isEmpty ? "(no prompt yet)" : String(cleaned.prefix(120)),
            lastActive: mtime,
            model: model ?? "",
            fileURL: url)
    }

    /// The last assistant reply in a transcript, trimmed to one short line, so a
    /// row can preview what the session was doing before you resume it. Reads
    /// only the tail of the file, scanning lines from the end for the newest
    /// assistant text.
    nonisolated static func lastReply(from url: URL, tailBytes: Int = 128 * 1024) -> String? {
        guard let tail = readTail(url, bytes: tailBytes) else { return nil }
        for line in tail.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  (msg["role"] as? String) == "assistant",
                  let text = firstText(from: msg["content"])
            else { continue }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            if cleaned.isEmpty { continue }
            return String(cleaned.prefix(160))
        }
        return nil
    }

    /// Read at most `bytes` from the END of a file as UTF-8, dropping a leading
    /// partial line so the parser only sees whole JSON objects.
    private nonisolated static func readTail(_ url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        guard var s = String(data: data, encoding: .utf8) else { return nil }
        if start > 0, let nl = s.firstIndex(of: "\n") {
            s = String(s[s.index(after: nl)...])
        }
        return s
    }

    /// Extract the first text fragment from a message `content`, which is either
    /// a plain string or an array of typed parts.
    private nonisolated static func firstText(from content: Any?) -> String? {
        if let s = content as? String { return s }
        if let parts = content as? [[String: Any]] {
            for p in parts where (p["type"] as? String) == "text" {
                if let t = p["text"] as? String { return t }
            }
        }
        return nil
    }

    /// Read at most `bytes` from the start of a file as UTF-8. Truncated at the
    /// last newline so no partial JSON line is handed to the parser.
    private nonisolated static func readHead(_ url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: bytes)) ?? Data()
        guard var s = String(data: data, encoding: .utf8) else { return nil }
        if data.count == bytes, let nl = s.lastIndex(of: "\n") {
            s = String(s[..<nl])
        }
        return s
    }
}
