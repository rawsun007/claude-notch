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

        case "ExitPlanMode":
            // Show the proposed plan markdown right in the card so the user
            // can read what Claude wants to do before approving.
            let plan = (input["plan"] as? String) ?? ""
            guard !plan.isEmpty else { return nil }
            let lines = plan.split(separator: "\n", omittingEmptySubsequences: false)
            let head = lines.prefix(maxWriteLines).joined(separator: "\n")
            return .write(head: head, totalLines: lines.count)

        case "TodoWrite":
            // Render the todo list as a checkbox preview (□ pending / ▣ doing
            // / ✓ done) so the user can see what's about to change.
            let todos = (input["todos"] as? [[String: Any]]) ?? []
            guard !todos.isEmpty else { return nil }
            let rendered = todos.prefix(maxWriteLines).map { todo -> String in
                let status = (todo["status"] as? String) ?? "pending"
                let text   = (todo["content"] as? String) ?? (todo["activeForm"] as? String) ?? ""
                let icon: String
                switch status {
                case "in_progress": icon = "▣"
                case "completed":   icon = "✓"
                default:            icon = "□"
                }
                return "\(icon) \(text)"
            }.joined(separator: "\n")
            return .write(head: rendered, totalLines: todos.count)

        case "apply_patch":
            // Codex's patch envelope is already diff-shaped text; show its head
            // so the card says which file and roughly what changes.
            let patch = CodexToolInput.patchText(input)
            guard !patch.isEmpty else { return nil }
            let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
            let head = lines.prefix(maxWriteLines).joined(separator: "\n")
            return .write(head: head, totalLines: lines.count)

        case "update_plan":
            let plan = (input["plan"] as? [[String: Any]]) ?? []
            guard !plan.isEmpty else { return nil }
            let rendered = plan.prefix(maxWriteLines).map { item -> String in
                let status = (item["status"] as? String) ?? "pending"
                let text   = (item["step"] as? String) ?? (item["content"] as? String) ?? ""
                let icon: String
                switch status {
                case "in_progress": icon = "▣"
                case "completed":   icon = "✓"
                default:            icon = "□"
                }
                return "\(icon) \(text)"
            }.joined(separator: "\n")
            return .write(head: rendered, totalLines: plan.count)

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
        case "shell", "local_shell", "exec", "exec_command", "unified_exec":
            // Codex passes argv arrays; scan the same patterns as Bash.
            return bashDanger(CodexToolInput.command(input))
        case "apply_patch":
            let files = CodexToolInput.patchFiles(CodexToolInput.patchText(input))
            for path in files {
                let reasons = pathDanger(path)
                if !reasons.isEmpty { return reasons }
            }
            return []
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
        // Strip quoted strings, heredoc bodies and trailing comments. Without
        // this, a commit message like `git commit -m "fix the rm -rf bug"`
        // matches every destructive pattern just because the words appear
        // in user-controlled text.
        let scrubbed = stripQuotedAndHeredocs(command)
        var reasons: [String] = []

        // Catch `rm` with recursive + force flags in any combination — combined
        // (`-rf`), split (`-r -f`), or long (`--recursive --force`). Split on
        // command separators first so flags from one command in a chain don't
        // count toward another (e.g. `git push -f && rm -r foo` shouldn't fire).
        if matches(#"\brm\s+"#, in: scrubbed, options: []) {
            for cmd in scrubbed.components(separatedBy: CharacterSet(charactersIn: ";|&")) {
                guard matches(#"\brm\s+"#, in: cmd, options: []) else { continue }
                let hasR = matches(#"\s-[a-zA-Z]*[rR]"#, in: cmd, options: []) || matches(#"\s--recursive\b"#, in: cmd, options: [])
                let hasF = matches(#"\s-[a-zA-Z]*[fF]"#, in: cmd, options: []) || matches(#"\s--force\b"#, in: cmd, options: [])
                if hasR && hasF {
                    reasons.append("rm -rf, deletes files recursively without prompting")
                    break
                }
            }
        }

        // Test in (rough) order of severity. Each entry: regex (case-
        // insensitive where it makes sense) → reason string.
        let patterns: [(String, NSRegularExpression.Options, String)] = [
            (#"\bsudo\b"#, [],
             "sudo, runs with root privileges"),
            (#"\bgit\s+push\b.*(--force\b|--force-with-lease\b|\s-f\b)"#, [],
             "git push --force, can overwrite remote history"),
            (#"\b(curl|wget)\b[^|]*\|\s*(sh|bash|zsh|fish)\b"#, [],
             "curl | sh, pipes remote code into a shell"),
            (#"\bchmod\s+-?R\s+777"#, [],
             "chmod -R 777, makes files world-writable"),
            (#"\bdd\s+if="#, [],
             "dd, raw block-device write, can wipe disks"),
            (#"\bmkfs(\.\w+)?\b"#, [],
             "mkfs, formats a filesystem"),
            (#":\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#, [],
             "fork bomb"),
            (#">\s*/dev/(sd|disk|hd|nvme)\w"#, [],
             "writes raw bytes to a disk device"),
            (#"\bmv\s+/(etc|usr|System|var|bin|sbin|opt|Library)\b"#, [],
             "moves a system directory"),
            (#"\b(npm|yarn|pnpm)\s+publish\b"#, [],
             "publishes a package to a registry, irrevocable"),
            (#"\btwine\s+upload\b"#, [],
             "uploads to PyPI, irrevocable"),
            (#"\bcargo\s+publish\b"#, [],
             "publishes to crates.io, irrevocable"),
            (#"\bgit\s+clean\s+-[a-zA-Z]*[fd][a-zA-Z]*x?"#, [],
             "git clean -fd[x], deletes untracked files (incl. ignored)"),
            (#"\b(drop|truncate)\s+(table|database)\b"#, [.caseInsensitive],
             "drops a database table"),
            (#"\bdocker\s+system\s+prune\s+.*(-a|--all)"#, [],
             "docker system prune -a, removes all images and containers"),
            // The same files pathDanger holds a Write for. A redirect reaches
            // them just as well as an Edit does, and only this list sees it.
            (#"(>>?|\btee\b)[^|;&\n]*(/\.ssh/|/\.gnupg/|/\.aws/|/\.kube/|/Library/LaunchAgents/|/\.claude/|/\.codex/|/\.claudenotch/|/\.git/hooks/|/\.(zshrc|zshenv|zprofile|zlogin|bashrc|bash_profile|profile|gitconfig|netrc)\b)"#, [],
             "writes into a credential, shell-startup or agent-config file"),
            (#"\b(cp|mv|ln)\b[^|;&\n]*/Library/LaunchAgents/"#, [],
             "installs a LaunchAgent, which runs at every login"),
            (#"\blaunchctl\s+(load|bootstrap|submit|enable)\b"#, [],
             "launchctl, installs or starts a background job"),
            (#"\bcrontab\s+[^-]"#, [],
             "crontab, schedules a recurring command"),
        ]

        for (pattern, opts, reason) in patterns {
            if matches(pattern, in: scrubbed, options: opts) {
                reasons.append(reason)
            }
        }
        return reasons
    }

    /// Replace contents of single/double-quoted strings and heredoc bodies
    /// with placeholder text. The point is that user-supplied free-text
    /// (commit messages, echo arguments, sed replacements) shouldn't fire
    /// danger rules — only the actual shell tokens around them should.
    private static func stripQuotedAndHeredocs(_ command: String) -> String {
        var s = command

        // Heredocs first — they can contain anything including quotes.
        // <<TAG, <<-TAG, <<'TAG', <<"TAG" — capture TAG, replace up to a
        // line that contains just TAG (optionally indented for <<-).
        s = replaceRegex(in: s,
                         pattern: #"<<-?\s*['"]?(\w+)['"]?[^\n]*\n[\s\S]*?\n\s*\1\b"#,
                         options: [],
                         replacement: "<<HEREDOC>>")

        // $(...) and `...` — command substitutions often hold the heredoc
        // openers we just collapsed; their *outer* commands should still
        // be checked, but inner free-text shouldn't trigger.
        // Single-quoted strings: literal, no expansion.
        s = replaceRegex(in: s, pattern: #"'[^']*'"#, options: [], replacement: "''")
        // Double-quoted strings: best-effort (doesn't track \" but that's
        // fine for our risk-scan use case).
        s = replaceRegex(in: s, pattern: #""[^"]*""#, options: [], replacement: "\"\"")
        // Comments after whitespace.
        s = replaceRegex(in: s, pattern: #"\s+#[^\n]*"#, options: [], replacement: "")

        return s
    }

    private static func replaceRegex(
        in input: String,
        pattern: String,
        options: NSRegularExpression.Options,
        replacement: String
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return re.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: replacement)
    }

    /// Whether writing to `path` is destructive or dangerous enough to hold the
    /// card. `home` is a parameter so the classification is testable without
    /// depending on whose machine the test runs on.
    ///
    /// A system directory was the whole of this check, which meant the writes
    /// that actually take a machine over went through ungated: nothing in
    /// `/etc` is as reachable as `~/.ssh/authorized_keys`, a LaunchAgent plist,
    /// a repo's `.git/hooks/pre-commit`, or the agent's own settings file. And
    /// because `dangerReasons` is the single gate on auto-approve, on
    /// always-allow rules, on allow-all, and on the hold-to-confirm, "not
    /// dangerous" here means "may be written silently, with no card at all".
    static func pathDanger(_ path: String, home: String = NSHomeDirectory()) -> [String] {
        guard !path.isEmpty else { return [] }
        // Expands ~, collapses `..` and duplicate separators, so a path dressed
        // up as `~/.ssh/../.ssh/authorized_keys` is classified as what it is.
        let p = (path as NSString).standardizingPath
        // Exactly one trailing slash, so a prefix check cannot match a sibling
        // like "/Users/aliceXYZ". Built by hand: appendingPathComponent("")
        // returns the path unchanged, which silently made every check below
        // compare against "/Users/alice.ssh/" and match nothing.
        let base = (home as NSString).standardizingPath
        let h = (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/"

        func underHome(_ suffix: String) -> String { h + suffix }

        // Checked before the system directories so the reason names the actual
        // file rather than "somewhere in /Library".
        let sensitiveDirs: [(String, String)] = [
            (underHome(".ssh/"),            "writes inside ~/.ssh, where your SSH keys and authorized_keys live"),
            (underHome(".gnupg/"),          "writes inside ~/.gnupg, your GPG keyring"),
            (underHome(".aws/"),            "writes inside ~/.aws, your cloud credentials"),
            (underHome(".kube/"),           "writes inside ~/.kube, your cluster credentials"),
            (underHome(".config/gcloud/"),  "writes inside ~/.config/gcloud, your cloud credentials"),
            // A plist here runs at every login, which is how a one-off write
            // becomes a permanent process.
            (underHome("Library/LaunchAgents/"), "installs a LaunchAgent, which runs at every login"),
            // The agent's own permission config, and ours. Editing either is how
            // a single approved write turns into blanket approval afterwards.
            (underHome(".claude/"),         "writes inside ~/.claude, the agent's own settings and hooks"),
            (underHome(".codex/"),          "writes inside ~/.codex, the agent's own settings and hooks"),
            (underHome(".claudenotch/"),    "writes inside ~/.claudenotch, this app's allowlist and settings"),
        ]
        for (dir, reason) in sensitiveDirs where p.hasPrefix(dir) {
            return [reason]
        }

        // Anything git will execute on the next ordinary git command. Matched by
        // `contains` rather than a prefix so it fires for a relative path too,
        // which is the shape most in-repo edits arrive as.
        if p.contains("/.git/hooks/") || p.hasPrefix(".git/hooks/") {
            return ["writes a git hook, which runs on the next commit or checkout"]
        }
        if p.hasSuffix("/.git/config") || p == ".git/config" {
            return ["writes .git/config, where an alias or fsmonitor entry runs commands"]
        }

        // Shell startup files: a line here runs in every terminal you open.
        let startupFiles = [".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout",
                            ".bashrc", ".bash_profile", ".bash_login", ".profile",
                            ".gitconfig", ".netrc"]
        for name in startupFiles where p == underHome(name) {
            return ["writes ~/\(name), which is read every time a shell starts"]
        }

        let systemDirs = ["/etc/", "/usr/", "/System/", "/var/", "/bin/", "/sbin/", "/opt/", "/Library/"]
        for dir in systemDirs where p.hasPrefix(dir) {
            return ["writes inside \(dir), a system directory"]
        }
        return []
    }

    private static func matches(_ pattern: String, in string: String, options: NSRegularExpression.Options) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return re.firstMatch(in: string, range: range) != nil
    }
}
