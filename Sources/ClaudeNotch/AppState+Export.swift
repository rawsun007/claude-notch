import Foundation
import AppKit

// Exporting history and sessions as CSV/JSON, and the standup summary.

extension AppState {
    func refreshProjectSpend() {
        Task { [weak self] in
            let usage = await Task.detached { ClaudeUsageReader.compute() }.value
            self?.weekCostByProject = usage.weekByProject.mapValues(\.costUSD)
            self?.weekCostByDay = usage.dailyCostUSD
        }
    }

    func closeHistory() {
        isHistoryOpen = false
        recompute()
        returnToPreviousApp()
    }

    func clearHistory() {
        history.removeAll()
        schedulePersist()
        if isHistoryOpen { closeHistory() }
    }

    /// Save the full activity log to a user-chosen file. Writes CSV when the
    /// chosen name ends in `.csv`, otherwise pretty JSON. The app is an
    /// LSUIElement (no Dock icon), so we activate first or the save panel
    /// never comes forward.
    func exportHistory() {
        guard !history.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export Activity History"
        panel.nameFieldStringValue = "claudenotch-history.json"
        panel.allowedContentTypes = [.json, .commaSeparatedText]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            returnToPreviousApp()
            return
        }
        let csv = url.pathExtension.lowercased() == "csv"
        let data = csv ? Self.historyCSV(history) : Self.historyJSON(history)
        try? data.write(to: url, options: .atomic)
        returnToPreviousApp()
    }

    private static func outcomeString(_ o: HistoryEntry.Outcome) -> String {
        switch o {
        case .allowed:          return "allowed"
        case .denied:           return "denied"
        case .dismissed:        return "dismissed"
        case .answered(let n):  return "answered(\(n))"
        case .info:             return "info"
        case .dangerous:        return "dangerous"
        }
    }

    private static func historyJSON(_ entries: [HistoryEntry]) -> Data {
        let iso = AppState.iso8601
        let rows: [[String: String]] = entries.map { e in
            ["timestamp": iso.string(from: e.timestamp),
             "kind": e.kind.rawValue,
             "tool": e.toolName,
             "title": e.title,
             "detail": e.detail,
             "project": e.project,
             "outcome": outcomeString(e.outcome)]
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(rows)) ?? Data()
    }

    /// Quote a CSV field when it contains a comma, quote, or newline (doubling
    /// any embedded quotes), per RFC 4180. Shared by the CSV exporters.
    ///
    /// Also neutralizes spreadsheet formula injection: exported fields carry
    /// agent-supplied tool commands, file paths, and session notes (untrusted),
    /// and a field a spreadsheet evaluates as a formula (leading =, +, -, @,
    /// tab, or CR) could run on open in Excel/Sheets. Prefix such a field with a
    /// single quote so it is treated as literal text.
    /// https://owasp.org/www-community/attacks/CSV_Injection
    nonisolated static func csvEscape(_ s: String) -> String {
        var field = s
        if let first = field.first, "=+-@\t\r".contains(first) {
            field = "'" + field
        }
        guard field.contains(",") || field.contains("\"")
                || field.contains("\n") || field.contains("\r") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func historyCSV(_ entries: [HistoryEntry]) -> Data {
        let iso = AppState.iso8601
        let esc = csvEscape
        var lines = ["timestamp,kind,tool,title,detail,project,outcome"]
        for e in entries {
            lines.append([iso.string(from: e.timestamp), e.kind.rawValue, e.toolName,
                          e.title, e.detail, e.project, outcomeString(e.outcome)]
                .map(esc).joined(separator: ","))
        }
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    /// Save the session history to a user-chosen file. CSV when the chosen
    /// name ends in `.csv`, otherwise pretty JSON — same pattern as
    /// exportHistory above.
    func exportSessionHistory() {
        guard !sessionHistory.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export Session History"
        panel.nameFieldStringValue = "claudenotch-sessions.csv"
        panel.allowedContentTypes = [.commaSeparatedText, .json]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            returnToPreviousApp()
            return
        }
        let json = url.pathExtension.lowercased() == "json"
        let data = json ? Self.sessionsJSON(sessionHistory) : Self.sessionsCSV(sessionHistory)
        try? data.write(to: url, options: .atomic)
        returnToPreviousApp()
    }

    private static func sessionsJSON(_ records: [SessionRecord]) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(records)) ?? Data()
    }

    private static func sessionsCSV(_ records: [SessionRecord]) -> Data {
        let iso = AppState.iso8601
        let esc = csvEscape
        var lines = ["started,ended,project,cwd,duration_s,tokens,cost_usd,tool_calls,model"]
        for r in records {
            lines.append([
                iso.string(from: r.startedAt),
                r.endedAt.map(iso.string(from:)) ?? "",
                r.project, r.cwd,
                r.duration.map { String(Int($0)) } ?? "",
                String(r.contextTokens),
                String(format: "%.4f", r.costUSD),
                String(r.toolCallCount),
                r.model,
            ].map(esc).joined(separator: ","))
        }
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    /// Build a "what I shipped" standup from the archived session digests over
    /// the last `days` days, grouped by project: the session summaries, the code
    /// churn and cost, and the actual git commit subjects from each project dir.
    /// Nonisolated + async because it shells out to `git log` per project; call
    /// it off the main actor and put the result on the clipboard.
    nonisolated static func standupText(records: [SessionRecord],
                                        extraDirs: [String] = [],
                                        days: Int) -> String {
        let cal = Calendar.current
        let since = cal.date(byAdding: .day, value: -(max(days, 1) - 1),
                             to: cal.startOfDay(for: Date())) ?? Date()
        let recent = records.filter { $0.startedAt >= since }
        let header: String = {
            let df = DateFormatter(); df.dateFormat = "EEE MMM d"
            if days <= 1 { return "Standup, \(df.string(from: Date()))" }
            return "What I shipped, last \(days) days"
        }()

        // Group session records by project dir (cwd is the stable key), then
        // fold in recent project dirs that have no archived session in the
        // window but DO have commits shipped — otherwise a project you worked on
        // all day but never formally ended a session in goes missing.
        var order: [String] = []
        var byCwd: [String: [SessionRecord]] = [:]
        for r in recent {
            let key = r.cwd.isEmpty ? r.project : r.cwd
            if byCwd[key] == nil { order.append(key) }
            byCwd[key, default: []].append(r)
        }
        for dir in extraDirs where !dir.isEmpty && byCwd[dir] == nil {
            byCwd[dir] = []
            order.append(dir)
        }

        var blocks: [String] = []
        for key in order {
            let rs = byCwd[key] ?? []
            // Session summaries (deduped, non-empty).
            var lines: [String] = []
            var seen = Set<String>()
            for s in rs.compactMap({ $0.summary }) where !s.isEmpty {
                if seen.insert(s.lowercased()).inserted { lines.append("  • \(s)") }
            }
            // Actual commits shipped from this project dir in the window.
            let commits = gitCommits(inDir: key, since: since)
            for c in commits.prefix(8) { lines.append("  · \(c)") }
            // Nothing to say about this project: skip it entirely.
            guard !lines.isEmpty else { continue }

            let label = rs.first?.project ?? (key as NSString).lastPathComponent
            let add = rs.reduce(0) { $0 + ($1.linesAdded ?? 0) }
            let rem = rs.reduce(0) { $0 + ($1.linesRemoved ?? 0) }
            let cost = rs.reduce(0.0) { $0 + $1.costUSD }

            var block = [label] + lines
            var meta: [String] = []
            if add + rem > 0 { meta.append("+\(add) / -\(rem)") }
            if !rs.isEmpty { meta.append("\(rs.count) session\(rs.count == 1 ? "" : "s")") }
            if cost > 0 { meta.append(String(format: "~$%.2f", cost)) }
            if !meta.isEmpty { block.append("  (\(meta.joined(separator: ", ")))") }
            blocks.append(block.joined(separator: "\n"))
        }

        guard !blocks.isEmpty else {
            return header + "\n\nNo sessions or commits in this window."
        }
        return header + "\n\n" + blocks.joined(separator: "\n\n")
    }

    /// Commit subjects authored in `dir` since a date (`git log --since`), merges
    /// excluded. Empty when not a repo or git is unavailable.
    nonisolated private static func gitCommits(inDir dir: String, since: Date) -> [String] {
        guard !dir.isEmpty,
              FileManager.default.fileExists(atPath: dir + "/.git") else { return [] }
        let iso = AppState.iso8601
        // The dir may be an untrusted repo (anything the user opened). Override
        // the config keys that would let a repo's .git/config run a command off a
        // plain `git log`: signature verification spawns gpg, and fsmonitor spawns
        // a hook process on index refresh. -c on the command line wins over repo
        // config, so these can't be re-enabled by the repo.
        guard let out = Shell.output("/usr/bin/git",
                                     ["-c", "log.showSignature=false",
                                      "-c", "core.fsmonitor=false",
                                      "-C", dir, "log", "--no-merges",
                                      "--since=\(iso.string(from: since))",
                                      "--pretty=format:%s"]) else { return [] }
        return out.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
