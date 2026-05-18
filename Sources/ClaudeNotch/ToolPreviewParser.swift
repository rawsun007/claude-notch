import Foundation

/// Pure functions that turn a tool's `tool_input` dict into:
///   - a `ToolPreview` (diff hunk for Edit, head for Write, etc.)
///   - a `dangerReasons` array (non-empty when the command pattern-matches
///     something destructive enough to warrant a hold-to-confirm)
///
/// Called from EventServer when building the PermissionRequest, so the
/// PermissionCard can render the preview/warning without re-parsing.
enum ToolPreviewParser {

    static let maxDiffLines = 10
    static let maxWriteLines = 12

    /// Build a preview block from the tool's input payload, or nil if the
    /// tool has nothing useful to show beyond its detail string.
    static func preview(for tool: String, input: [String: Any]) -> ToolPreview? {
        switch tool {
        case "Edit":
            let old = (input["old_string"] as? String) ?? ""
            let new = (input["new_string"] as? String) ?? ""
            guard !(old.isEmpty && new.isEmpty) else { return nil }
            return .diff(hunk(old: old, new: new, maxLines: maxDiffLines))

        case "MultiEdit":
            let edits = (input["edits"] as? [[String: Any]]) ?? []
            guard let firstEdit = edits.first else { return nil }
            let old = (firstEdit["old_string"] as? String) ?? ""
            let new = (firstEdit["new_string"] as? String) ?? ""
            return .multiDiff(
                count: edits.count,
                first: hunk(old: old, new: new, maxLines: 8)
            )

        case "Write":
            let content = (input["content"] as? String) ?? ""
            guard !content.isEmpty else { return nil }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            let head = lines.prefix(maxWriteLines).joined(separator: "\n")
            return .write(head: head, totalLines: lines.count)

        case "NotebookEdit":
            // NotebookEdit `new_source` is the cell content for insert/replace.
            let content = (input["new_source"] as? String) ?? ""
            guard !content.isEmpty else { return nil }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            let head = lines.prefix(maxWriteLines).joined(separator: "\n")
            return .write(head: head, totalLines: lines.count)

        default:
            return nil
        }
    }

    private static func hunk(old: String, new: String, maxLines: Int) -> DiffHunk {
        let oldRaw = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newRaw = new.isEmpty ? [] : new.components(separatedBy: "\n")
        let oldTrunc = oldRaw.count > maxLines
        let newTrunc = newRaw.count > maxLines
        return DiffHunk(
            oldLines: Array(oldRaw.prefix(maxLines)),
            newLines: Array(newRaw.prefix(maxLines)),
            truncatedOld: oldTrunc,
            truncatedNew: newTrunc
        )
    }

    // MARK: - Danger flagging

    /// Pattern-match a command (Bash) against destructive operations. The
    /// returned strings are human-readable reasons rendered in the warning
    /// banner. Empty array means safe-as-far-as-we-know.
    static func dangerReasons(for tool: String, input: [String: Any]) -> [String] {
        switch tool {
        case "Bash":
            let cmd = (input["command"] as? String) ?? ""
            return bashDanger(cmd)
        case "Write":
            // Writing to system paths is suspicious; everything else is fine.
            let path = (input["file_path"] as? String) ?? ""
            return pathDanger(path)
        case "Edit", "MultiEdit", "NotebookEdit":
            let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? ""
            return pathDanger(path)
        default:
            return []
        }
    }

    private static func bashDanger(_ command: String) -> [String] {
        guard !command.isEmpty else { return [] }
        var reasons: [String] = []

        // Test in (rough) order of severity. Each entry: regex (case-
        // insensitive where it makes sense) → reason string.
        let patterns: [(String, NSRegularExpression.Options, String)] = [
            (#"\brm\s+-[a-zA-Z]*[rR][a-zA-Z]*[fF]"#, [],
             "rm -rf — deletes files recursively without prompting"),
            (#"\brm\s+-[a-zA-Z]*[fF][a-zA-Z]*[rR]"#, [],
             "rm -rf — deletes files recursively without prompting"),
            (#"\bsudo\b"#, [],
             "sudo — runs with root privileges"),
            (#"\bgit\s+push\b.*(--force\b|--force-with-lease\b|\s-f\b)"#, [],
             "git push --force — can overwrite remote history"),
            (#"\b(curl|wget)\b[^|]*\|\s*(sh|bash|zsh|fish)\b"#, [],
             "curl | sh — pipes remote code into a shell"),
            (#"\bchmod\s+-?R\s+777"#, [],
             "chmod -R 777 — makes files world-writable"),
            (#"\bdd\s+if="#, [],
             "dd — raw block-device write, can wipe disks"),
            (#"\bmkfs(\.\w+)?\b"#, [],
             "mkfs — formats a filesystem"),
            (#":\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#, [],
             "fork bomb"),
            (#">\s*/dev/(sd|disk|hd|nvme)\w"#, [],
             "writes raw bytes to a disk device"),
            (#"\bmv\s+/(etc|usr|System|var|bin|sbin|opt|Library)\b"#, [],
             "moves a system directory"),
            (#"\b(npm|yarn|pnpm)\s+publish\b"#, [],
             "publishes a package to a registry — irrevocable"),
            (#"\btwine\s+upload\b"#, [],
             "uploads to PyPI — irrevocable"),
            (#"\bcargo\s+publish\b"#, [],
             "publishes to crates.io — irrevocable"),
            (#"\bgit\s+clean\s+-[a-zA-Z]*[fd][a-zA-Z]*x?"#, [],
             "git clean -fd[x] — deletes untracked files (incl. ignored)"),
            (#"\b(drop|truncate)\s+(table|database)\b"#, [.caseInsensitive],
             "drops a database table"),
            (#"\bdocker\s+system\s+prune\s+.*(-a|--all)"#, [],
             "docker system prune -a — removes all images and containers"),
        ]

        for (pattern, opts, reason) in patterns {
            if matches(pattern, in: command, options: opts) {
                reasons.append(reason)
            }
        }
        return reasons
    }

    private static func pathDanger(_ path: String) -> [String] {
        let systemDirs = ["/etc/", "/usr/", "/System/", "/var/", "/bin/", "/sbin/", "/opt/", "/Library/"]
        for dir in systemDirs where path.hasPrefix(dir) {
            return ["writes inside \(dir) — a system directory"]
        }
        if path == "/etc/hosts" || path == "/etc/sudoers" {
            return ["modifies a sensitive system file"]
        }
        return []
    }

    private static func matches(_ pattern: String, in string: String, options: NSRegularExpression.Options) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return re.firstMatch(in: string, range: range) != nil
    }
}
