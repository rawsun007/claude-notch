import Foundation

/// What Strict Mode will approve on your behalf.
///
/// `ToolPreviewParser.dangerReasons` is a denylist: it names what it knows to
/// be destructive, and anything it has not been taught about comes back clean.
/// That is the right default, because a warning on every command is a warning
/// nobody reads. But a denylist is never finished, which SECURITY.md says in as
/// many words, and an unflagged command is eligible for Auto-Approve and for a
/// tool-wide allow rule.
///
/// Strict Mode inverts the question. Not "is this known to be bad" but "is this
/// known to be harmless", and only a yes may skip the card. It blocks nothing
/// and runs nothing; it decides whether a decision gets made for you, or by you.
///
/// The rule is one sentence: **a safe command looks at things and changes
/// nothing.** No building, no testing, no running a script, no reaching the
/// network. Those are all ordinary and mostly fine, and they all execute code
/// somebody else wrote, so in Strict Mode they are worth a click.
///
/// Being wrong in the strict direction costs a card. Being wrong in the other
/// direction costs what the command did. The list stays short.
enum SafeCommand {

    /// Tools that cannot change anything, whatever their arguments.
    ///
    /// `Read` is absent on purpose: Claude Code prompts for it in directories
    /// you have not trusted yet, so it is a real question about a real
    /// boundary, and answering that for you is what Strict Mode exists to stop.
    /// `WebFetch` and `WebSearch` are absent too. Reaching the network changes
    /// no file, but it is how a prompt injection arrives and how data leaves.
    static let readOnlyTools: Set<String> = [
        "Grep", "Glob", "LS", "BashOutput", "TaskList", "TaskGet",
        // Codex vocabulary for the same things.
        "read_file", "list_dir",
    ]

    /// Shell commands that read and report, whatever flags they are given.
    ///
    /// Absent, and worth saying why: `make`, whose default target can do
    /// anything; `python`, `node`, `ruby` and friends, which run a file or an
    /// inline program; `curl` and `wget`, which are the network; `find`, which
    /// takes `-delete` and `-exec`.
    private static let safeVerbs: Set<String> = [
        "ls", "pwd", "cat", "head", "tail", "wc", "file", "stat", "du", "df",
        "grep", "rg", "ag", "which", "whoami", "hostname", "date", "uname",
        "echo", "printf", "printenv", "true", "false",
        "basename", "dirname", "realpath", "readlink",
        "sort", "uniq", "cut", "tr", "column", "jq", "yq",
        "diff", "cmp", "shasum", "md5",
        "type", "man",
    ]

    /// Where the first word is not the whole story. `git` reads with `status`
    /// and rewrites history with `reset`, so what gets listed is the pair.
    ///
    /// Every entry here has to be read-only *with any flags*, which is stricter
    /// than it looks and rules out a lot. `git branch` lists, but `git branch
    /// -D` deletes. `git config` prints, but `git config user.email x` writes.
    /// `git stash` moves your working tree. `gh pr` reads, but `gh pr create`
    /// publishes. None of those are here.
    private static let safeSubcommands: [String: Set<String>] = [
        "git": ["status", "log", "diff", "show", "blame", "shortlog",
                "rev-parse", "ls-files", "describe", "whatchanged"],
        "npm": ["list", "ls", "view", "outdated", "why"],
        "pnpm": ["list", "ls", "why", "outdated"],
        "yarn": ["list", "why", "outdated"],
        "pip": ["list", "show", "freeze"],
        "pip3": ["list", "show", "freeze"],
        "cargo": ["tree"],
        "go": ["list", "version", "env"],
        "docker": ["ps", "images", "logs", "version", "info", "inspect"],
        "kubectl": ["get", "describe", "logs", "version"],
        "brew": ["list", "info", "outdated", "config"],
    ]

    /// Anything that makes a command line more than a single call, so the verb
    /// at the front stops being the whole story. A pipe can end in a shell, a
    /// redirect writes, a substitution runs, a separator hides a second command
    /// behind a harmless first one.
    private static let compoundMarkers: Set<Character> = [";", "|", "&", ">", "<", "`", "\n"]

    /// Whether a tool call may skip the card in Strict Mode. `detail` is the
    /// string the card would show, which for a shell tool is the command. Pure,
    /// so the policy is testable without a UI.
    static func isSafe(tool: String, detail: String) -> Bool {
        if readOnlyTools.contains(tool) { return true }
        guard isShellTool(tool) else { return false }
        return isSafeShellCommand(detail)
    }

    private static func isShellTool(_ tool: String) -> Bool {
        tool == "Bash"
            || ["shell", "local_shell", "exec", "exec_command", "unified_exec"].contains(tool)
    }

    /// Safe when it is one call, its verb only reads, and nothing in it turns
    /// the line into something else.
    static func isSafeShellCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 400 else { return false }

        // Belt and braces. The structural checks below should catch anything the
        // danger scan dislikes, but if the two ever disagree, the answer is no.
        guard ToolPreviewParser.dangerReasons(for: "Bash", input: ["command": trimmed]).isEmpty else {
            return false
        }

        guard !trimmed.contains(where: { compoundMarkers.contains($0) }) else { return false }
        guard !trimmed.contains("$(") else { return false }

        var words = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // A leading VAR=value is an environment prefix, not the command itself.
        while let first = words.first, !first.hasPrefix("-"), first.contains("=") {
            words.removeFirst()
        }
        guard let verb = words.first.map(lastPathComponent), !verb.isEmpty else { return false }

        guard let subcommands = safeSubcommands[verb] else {
            return safeVerbs.contains(verb)
        }
        // Leading flags are skipped, so `git --no-pager log` is judged on `log`.
        // A flag that takes its own argument (`git -C dir status`) defeats this:
        // `dir` is read as the subcommand and fails the check, so the card is
        // shown. That is the direction to be wrong in.
        guard let sub = words.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
            // Bare `git` or `npm` prints usage and changes nothing.
            return true
        }
        return subcommands.contains(sub)
    }

    /// `/usr/bin/git` → `git`, so an absolute path is judged on the same list.
    private static func lastPathComponent(_ s: String) -> String {
        s.contains("/") ? String(s.split(separator: "/").last ?? "") : s
    }
}
