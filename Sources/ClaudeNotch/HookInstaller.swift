import Foundation

/// Self-install for Claude Code hooks. Copies bundled hook scripts to a
/// stable absolute path (~/.claudenotch/bin) and merges the hook
/// events into ~/.claude/settings.json. Pure Swift — no shell-out, so it
/// works from inside the .app without needing the user to open a terminal.
enum HookInstaller {
    static let installDir: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claudenotch/bin")
    }()

    static let settingsPath: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
    }()

    static let hookEntryPoint: String = {
        (installDir as NSString).appendingPathComponent("claudenotch-hook.sh")
    }()

    /// Installed as Claude Code's `statusLine.command`. Forwards the
    /// authoritative context-window + plan-limit usage to the app, then chains
    /// to the user's previous status line (stored in `statusLineInnerCmd`).
    static let statusLineScript: String = {
        (installDir as NSString).appendingPathComponent("claudenotch-statusline.sh")
    }()

    /// Sidecar holding the user's original `statusLine.command` (a shell string)
    /// so the forwarder can re-emit it and uninstall can restore it.
    static let statusLineInnerCmd: String = {
        (installDir as NSString).appendingPathComponent("statusline-inner.cmd")
    }()

    /// True when settings.json contains our HTTP hook URL (new-style) or our
    /// dispatcher script (legacy command-hook style). HTTP hooks need no script
    /// on disk — the server is the entry point.
    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let s = String(data: data, encoding: .utf8) else { return false }
        if s.contains("127.0.0.1:53127") { return true }
        return FileManager.default.fileExists(atPath: hookEntryPoint) && s.contains("claudenotch-hook.sh")
    }

    /// True when our statusLine forwarder is wired into settings.json. Lets the
    /// app auto-migrate already-installed users (whose hooks predate the
    /// statusLine integration) without a manual reinstall.
    static var statusLineWired: Bool {
        guard FileManager.default.fileExists(atPath: statusLineScript) else { return false }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains("claudenotch-statusline.sh")
    }

    /// When the app last wrote `~/.claude/settings.json` itself.
    ///
    /// Every running session fires a `ConfigChange` hook when that file
    /// changes — including when WE change it, installing hooks or merging
    /// allow rules. Without this the app announces its own edits, once per
    /// live session. Not `@MainActor`: the writers are static and the reader
    /// is on the hook path.
    private nonisolated(unsafe) static var selfWriteAt = Date.distantPast
    private static let selfWriteLock = NSLock()

    static var lastSelfWriteAt: Date {
        selfWriteLock.withLock { selfWriteAt }
    }

    /// Call right after writing settings.json from inside the app.
    static func noteSelfWrite() {
        selfWriteLock.withLock { selfWriteAt = Date() }
    }

    /// True when settings.json already registers the hook events added in
    /// recent releases. Lets the app auto-migrate existing installs when an
    /// update starts listening to new events, without a manual reinstall.
    static var hooksCurrent: Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains("\"StopFailure\"") && s.contains("\"SessionStart\"")
            && s.contains("\"DirectoryAdded\"") && s.contains("\"CwdChanged\"")
            && s.contains("\"PermissionDenied\"") && s.contains("\"ConfigChange\"")
            && s.contains("\"PostCompact\"") && s.contains("\"Elicitation\"")
            && s.contains("\"PostToolUseFailure\"") && s.contains("\"InstructionsLoaded\"") && s.contains("\"FileChanged\"")
    }

    /// `jq` is required by posttool.sh to forward payload fields to the
    /// notch. Without it, PostToolUse forwarding silently no-ops.
    static var hasJq: Bool {
        let candidates = [
            "/opt/homebrew/bin/jq",   // Apple Silicon Homebrew
            "/usr/local/bin/jq",      // Intel Homebrew / manual install
            "/usr/bin/jq",            // system (rare)
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return true
        }
        // Fall back to PATH lookup via /usr/bin/env
        return Shell.succeeds("/usr/bin/env", ["sh", "-c", "command -v jq >/dev/null 2>&1"])
    }

    /// Create (or tighten) ~/.claudenotch/bin and its parent to 0700.
    ///
    /// Everything in here is executed: Claude Code runs the hook scripts on
    /// every event, and the status line `eval`s statusline-inner.cmd on every
    /// redraw. Creating the directory without a mode left it at whatever the
    /// umask happened to be, which on a permissive umask is a directory anyone
    /// on the machine can drop a file into. Persistence already forces 0700 on
    /// the same parent for the state file; this makes the half of ~/.claudenotch
    /// that actually runs code agree with it.
    @discardableResult
    static func prepareInstallDir() -> Bool {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: installDir)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            guard fm.fileExists(atPath: installDir) else { return false }
        }
        // Also applied when the directory already existed, so an install that
        // predates this hardening is tightened rather than left as it was.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installDir)
        try? fm.setAttributes([.posixPermissions: 0o700],
                              ofItemAtPath: dir.deletingLastPathComponent().path)
        return true
    }

    /// 0600 for a file we wrote, 0700 when it is meant to be executed. Applied
    /// after every write: `.atomic` replaces the inode with a fresh temp file
    /// that would otherwise land at the umask default.
    private static func restrict(_ path: String, executable: Bool = false) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: path)
    }

    enum InstallError: LocalizedError {
        case missingBundledHooks
        case scriptCopyFailed(String)
        case settingsWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingBundledHooks:
                return "Bundled hook scripts not found. Rebuild the app with ./build.sh."
            case .scriptCopyFailed(let s):
                return "Couldn't copy hook scripts: \(s)"
            case .settingsWriteFailed(let s):
                return "Couldn't update ~/.claude/settings.json: \(s)"
            }
        }
    }

    static func install() throws {
        try copyScripts()
        try mergeSettings()
    }

    // MARK: - Integrity

    /// A script that is installed but no longer matches the one this build
    /// ships, reported by file name.
    ///
    /// Claude Code runs these on every hook, so whatever is in that directory
    /// runs as you, dozens of times an hour. The directory is 0700 now, which
    /// stops another account writing into it, but nothing noticed if something
    /// already had, or if a well-meaning edit left a forwarder behind after an
    /// update changed it. Comparing bytes against what is in the bundle answers
    /// both, and it is the only claim that can be made without a signing story:
    /// this is drift detection, not authentication.
    ///
    /// Only files the bundle actually ships are compared. The Codex forwarder
    /// is written by the app rather than copied, and anything a user has put
    /// there themselves is theirs.
    /// Both directories are parameters so the comparison is testable without an
    /// app bundle, the same way transcriptRoots and pathDanger take theirs.
    static func driftedScripts(shippedDir: URL? = Bundle.main.resourceURL?.appendingPathComponent("hooks"),
                               installedDir: String = installDir) -> [String] {
        let fm = FileManager.default
        guard let sourceDir = shippedDir,
              let shipped = try? fm.contentsOfDirectory(atPath: sourceDir.path) else { return [] }

        var drifted: [String] = []
        for name in shipped.sorted() where name.hasSuffix(".sh") {
            let installed = (installedDir as NSString).appendingPathComponent(name)
            // Not installed at all is a different problem, and `isInstalled`
            // already speaks to it. Silence here rather than a false alarm.
            guard fm.fileExists(atPath: installed) else { continue }
            let a = try? Data(contentsOf: sourceDir.appendingPathComponent(name))
            let b = try? Data(contentsOf: URL(fileURLWithPath: installed))
            if a != b { drifted.append(name) }
        }
        return drifted
    }

    /// Put the shipped copies back. The repair for `driftedScripts`, and the
    /// same code path an install uses, so there is one way to write these.
    static func repairScripts() throws {
        try copyScripts()
    }

    // MARK: - Codex (beta)

    /// Codex reads hooks from ~/.codex/hooks.json. Codex hook payloads are
    /// snake_case and match Claude's schema, so they flow through the same
    /// server endpoint; only the transport differs (Codex runs a command hook,
    /// not an HTTP hook). We install a tiny forwarder that POSTs the event to
    /// the ClaudeNotch server and returns nothing, so Codex never blocks on us
    /// or sees a response shape it rejects.
    static let codexHooksPath: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/hooks.json")
    }()
    static let codexForwardScript: String = {
        (installDir as NSString).appendingPathComponent("claudenotch-codex-forward.sh")
    }()

    static var isCodexInstalled: Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: codexHooksPath)),
              let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains("claudenotch-codex-forward.sh")
    }

    private static let codexForwarderBody = """
    #!/bin/bash
    # ClaudeNotch <- Codex hook forwarder (beta). PreToolUse -> /extpretool (pops
    # a running-command card); every other event -> /hook. Fire-and-forget,
    # returns nothing, so Codex owns permission and never waits on us. Fails
    # open if the notch is not running.
    set -u
    input=$(cat)
    event=$(printf '%s' "$input" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)
    ep="/hook"; [ "$event" = "PreToolUse" ] && ep="/extpretool"
    if nc -z 127.0.0.1 53127 2>/dev/null; then
      printf '%s' "$input" | curl -s --max-time 10 -X POST \\
        -H 'Content-Type: application/json' --data-binary @- \\
        "http://127.0.0.1:53127$ep" >/dev/null 2>&1 &
    fi
    exit 0
    """

    /// Install the Codex forwarder + hooks.json. The user must approve the
    /// one-time "trust hooks" review the next time they start Codex.
    static func installCodexHooks() throws {
        let fm = FileManager.default
        prepareInstallDir()
        // Forwarder script. 0700, not 0755: only this user runs it, and it is
        // executed by Codex on every hook.
        do {
            try codexForwarderBody.write(toFile: codexForwardScript, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codexForwardScript)
        } catch {
            throw InstallError.scriptCopyFailed("codex forwarder: \(error.localizedDescription)")
        }
        // hooks.json. Informational events only (no PreToolUse): Codex's
        // PreToolUse fires for shell only and expects a decision enum we do not
        // emit yet, so blocking permission stays a later phase.
        let cmd = codexForwardScript
        let events = ["PreToolUse", "UserPromptSubmit", "PostToolUse", "SessionStart", "SessionEnd", "Notification", "Stop"]
        var hooks: [String: Any] = [:]
        for ev in events {
            // All events are fire-and-forget (Codex owns permission), so short
            // timeouts are fine.
            let handler: [String: Any] = ["type": "command", "command": cmd, "timeout": ev == "SessionEnd" ? 3 : 5]
            let group: [String: Any] = (ev == "PostToolUse" || ev == "PreToolUse")
                ? ["matcher": ".*", "hooks": [handler]]
                : ["hooks": [handler]]
            hooks[ev] = [group]
        }
        let root: [String: Any] = [
            "description": "ClaudeNotch: surface Codex events in the macOS notch (beta)",
            "hooks": hooks,
        ]
        let codexURL = URL(fileURLWithPath: codexHooksPath)
        try? fm.createDirectory(at: codexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        do { try data.write(to: codexURL, options: .atomic) }
        catch { throw InstallError.scriptCopyFailed("codex hooks.json: \(error.localizedDescription)") }
        restrict(codexHooksPath)
    }

    /// Remove our Codex hooks.json (only when it is ours) and the forwarder.
    static func uninstallCodexHooks() {
        if isCodexInstalled { try? FileManager.default.removeItem(atPath: codexHooksPath) }
        try? FileManager.default.removeItem(atPath: codexForwardScript)
    }

    private static func copyScripts() throws {
        guard let resourceURL = Bundle.main.resourceURL else {
            throw InstallError.missingBundledHooks
        }
        let sourceDir = resourceURL.appendingPathComponent("hooks")
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw InstallError.missingBundledHooks
        }

        guard prepareInstallDir() else {
            throw InstallError.scriptCopyFailed("could not create \(installDir)")
        }

        let dstBase = URL(fileURLWithPath: installDir)
        let scripts = (try? fm.contentsOfDirectory(atPath: sourceDir.path)) ?? []
        for name in scripts where name.hasSuffix(".sh") {
            let src = sourceDir.appendingPathComponent(name)
            let dst = dstBase.appendingPathComponent(name)
            do {
                if fm.fileExists(atPath: dst.path) {
                    try fm.removeItem(at: dst)
                }
                try fm.copyItem(at: src, to: dst)
                // 0700, not 0755: these run as the user on every hook, and
                // nobody else on the machine has business executing or
                // replacing them.
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dst.path)
            } catch {
                throw InstallError.scriptCopyFailed("\(name): \(error.localizedDescription)")
            }
        }
    }

    private static func mergeSettings() throws {
        let fm = FileManager.default
        let settingsURL = URL(fileURLWithPath: settingsPath)
        let parent = settingsURL.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)

        var settings: [String: Any] = [:]
        let existing = try? Data(contentsOf: settingsURL)
        if let existing,
           let obj = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            settings = obj
        }

        // Non-destructive merge: keep any hooks the user already had at each
        // event, drop any prior ClaudeNotch entry (so reinstalling doesn't
        // duplicate), and append ours.
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        appendHook(to: "PreToolUse", in: &hooks, matcher: ".*")
        // Permission dialogs that don't fire PreToolUse (TodoWrite, ExitPlanMode)
        // come through here so they still surface in the notch.
        appendHook(to: "PermissionRequest", in: &hooks, matcher: ".*")
        appendHook(to: "PostToolUse", in: &hooks, matcher: ".*")
        // A tool that failed. Without it, a session going in circles reads as a
        // session working.
        appendHook(to: "PostToolUseFailure", in: &hooks, matcher: ".*")
        // Which instruction files are shaping this agent. Matched on the load
        // reason, so ".*" is every kind.
        appendHook(to: "InstructionsLoaded", in: &hooks, matcher: ".*")
        // The working tree moving under an agent. Matched on the path glob.
        appendHook(to: "FileChanged", in: &hooks, matcher: ".*")
        appendHook(to: "UserPromptSubmit", in: &hooks, matcher: nil)
        appendHook(to: "Notification", in: &hooks, matcher: nil)
        appendHook(to: "Stop", in: &hooks, matcher: nil)
        // Session died from an API-level failure (rate limit, overloaded,
        // billing…) — surfaced as a red alert card so it never dies silently.
        appendHook(to: "StopFailure", in: &hooks, matcher: nil)
        // SessionStart: the session appears in the notch the moment it opens,
        // with the model name from the payload (before any transcript exists).
        appendHook(to: "SessionStart", in: &hooks, matcher: nil)
        appendHook(to: "SessionEnd", in: &hooks, matcher: ".*")
        // Task lifecycle drives the per-session progress meter. These events
        // take no matcher (they always fire on every occurrence).
        appendHook(to: "TaskCreated", in: &hooks, matcher: nil)
        appendHook(to: "TaskCompleted", in: &hooks, matcher: nil)
        // Context compaction cue for the context meter. Both ends: PreCompact
        // raises the cue, PostCompact is what ends it (matcher is the trigger,
        // "manual" or "auto"; nil takes both).
        appendHook(to: "PreCompact", in: &hooks, matcher: nil)
        appendHook(to: "PostCompact", in: &hooks, matcher: nil)
        // MCP elicitation: a server asking the user something mid-tool-call.
        // Matched on the server name, so ".*" is every server.
        appendHook(to: "Elicitation", in: &hooks, matcher: ".*")
        // And how it ended, whoever ended it: the card comes down on this.
        appendHook(to: "ElicitationResult", in: &hooks, matcher: ".*")
        // Subagent lifecycle: show spawned agents in the activity strip.
        appendHook(to: "SubagentStart", in: &hooks, matcher: nil)
        appendHook(to: "SubagentStop", in: &hooks, matcher: nil)
        // /add-dir mid-session. The notch shows what a session may touch, and
        // a directory granted after it started is exactly that changing.
        appendHook(to: "DirectoryAdded", in: &hooks, matcher: nil)
        appendHook(to: "CwdChanged", in: &hooks, matcher: nil)
        // Auto mode blocked a tool call. The notch shows what auto mode lets
        // through; without this it never shows what it stops, and a session
        // being blocked over and over looks like a session thinking.
        appendHook(to: "PermissionDenied", in: &hooks, matcher: ".*")
        // A settings file changed while sessions are running. Settings are
        // where permissions and sandboxing live, so this both refreshes what
        // the notch shows and is worth saying out loud.
        appendHook(to: "ConfigChange", in: &hooks, matcher: nil)
        settings["hooks"] = hooks

        // StatusLine: the only local source of authoritative context-% and real
        // 5h/weekly plan-limit usage. We point it at our forwarder, preserving
        // (chaining to) whatever the user already had so their terminal status
        // line is unchanged.
        wireStatusLine(in: &settings)

        do {
            let out = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            // Installing is idempotent and runs on launch whenever a release
            // adds an event, so most of these writes change nothing. Backing up
            // regardless left hundreds of copies of settings.json in ~/.claude,
            // each one a full copy of a file that can hold env values and
            // tokens, none of them ever removed. Back up what is about to be
            // replaced, only when it is about to change.
            if let existing, existing != out {
                backUp(existing)
            }
            guard existing != out else { return }   // nothing to write
            try out.write(to: settingsURL, options: .atomic)
            // Every live session is about to fire ConfigChange at us for this
            // write. Mark it as ours so the notch does not announce its own edit.
            noteSelfWrite()
        } catch {
            throw InstallError.settingsWriteFailed(error.localizedDescription)
        }
    }

    /// How many old copies of settings.json to keep. Enough to undo a bad
    /// install by hand, few enough that they are not a pile of credentials.
    static let settingsBackupsKept = 5

    /// Write a timestamped copy of the settings we are replacing, then prune.
    /// `settingsPath` is injectable so the pruning rules can be tested against
    /// a temporary directory rather than the user's real ~/.claude.
    static func backUp(_ bytes: Data, settingsPath: String = HookInstaller.settingsPath) {
        let ts = Int(Date().timeIntervalSince1970)
        let backupURL = URL(fileURLWithPath: settingsPath + ".before-claudenotch.\(ts)")
        try? bytes.write(to: backupURL)
        // A copy of the user's settings, which can hold env values and
        // tokens. It has no business being more readable than the original.
        restrict(backupURL.path)
        pruneBackups(settingsPath: settingsPath)
    }

    /// Keep the newest few and delete the rest.
    ///
    /// The name carries the timestamp, so sorting the names sorts by age
    /// without asking the filesystem for dates.
    static func pruneBackups(settingsPath: String = HookInstaller.settingsPath,
                             keeping: Int = settingsBackupsKept) {
        let dir = (settingsPath as NSString).deletingLastPathComponent
        let prefix = ((settingsPath as NSString).lastPathComponent) + ".before-claudenotch."
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let backups = names.filter { $0.hasPrefix(prefix) }.sorted()
        guard backups.count > keeping else { return }
        for name in backups.dropLast(keeping) {
            try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(name))
        }
    }

    /// Repoint `statusLine.command` at our forwarder, capturing the user's
    /// previous command into the inner sidecar so it's preserved and restorable.
    /// Idempotent: re-running won't capture our own forwarder as the "previous".
    private static func wireStatusLine(in settings: inout [String: Any]) {
        let existing = (settings["statusLine"] as? [String: Any])
        let priorCmd = (existing?["command"] as? String) ?? ""
        let ours = priorCmd.contains("claudenotch-statusline.sh")

        // Only (re)capture when the current command isn't already ours, so a
        // reinstall doesn't overwrite the saved original with our forwarder.
        if !ours {
            let data = priorCmd.data(using: .utf8) ?? Data()
            try? data.write(to: URL(fileURLWithPath: statusLineInnerCmd), options: .atomic)
            // claudenotch-statusline.sh `eval`s this on every status-line
            // redraw, so anyone who can write it can run code as the user.
            restrict(statusLineInnerCmd)
        }

        settings["statusLine"] = [
            "type": "command",
            "command": "bash \(shellQuote(statusLineScript))",
        ]
    }

    /// Append our HTTP hook into an event's rule list without clobbering anything
    /// the user already has there. Idempotent: any previous ClaudeNotch entry
    /// (either legacy command hook or new HTTP hook) is removed first.
    /// Internal (not private) so the non-destructive merge is unit-testable.
    static func appendHook(to eventName: String, in hooks: inout [String: Any], matcher: String?) {
        // Must exceed the app's own decision-wait window (285s in EventServer,
        // matching the 3-minute "waiting-on-you" nudge) — otherwise Claude Code
        // gives up on the HTTP request and falls back to its own terminal
        // prompt while the notch card sits there unable to reply to anything.
        let httpEntry: [String: Any] = ["type": "http", "url": "http://127.0.0.1:53127/hook", "timeout": 290]
        var ourRule: [String: Any] = ["hooks": [httpEntry]]
        if let m = matcher { ourRule["matcher"] = m }

        var existingList = (hooks[eventName] as? [[String: Any]]) ?? []
        existingList.removeAll { rule in
            let subHooks = (rule["hooks"] as? [[String: Any]]) ?? []
            return subHooks.contains { sub in
                if let type_ = sub["type"] as? String {
                    if type_ == "command", let c = sub["command"] as? String {
                        return c.contains("claudenotch-hook.sh")
                    }
                    if type_ == "http", let u = sub["url"] as? String {
                        return u.contains("53127")
                    }
                }
                return false
            }
        }
        existingList.append(ourRule)
        hooks[eventName] = existingList
    }

    /// Shell-quote a path for embedding in a settings.json command string.
    /// Claude Code executes the value via the user's shell, so unquoted
    /// spaces in $HOME would explode.
    static func shellQuote(_ s: String) -> String { Shell.quote(s) }
}
