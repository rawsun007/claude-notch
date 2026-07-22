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

    /// True when settings.json already registers the hook events added in
    /// recent releases. Lets the app auto-migrate existing installs when an
    /// update starts listening to new events, without a manual reinstall.
    static var hooksCurrent: Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains("\"StopFailure\"") && s.contains("\"SessionStart\"")
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
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["sh", "-c", "command -v jq >/dev/null 2>&1"]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
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
    # ClaudeNotch <- Codex hook forwarder (beta). Surfaces the Codex event in the
    # notch and returns nothing, so Codex never waits on us or sees an output
    # shape it rejects. Fires the POST in the background; fails open if the notch
    # is not running.
    set -u
    input=$(cat)
    if nc -z 127.0.0.1 53127 2>/dev/null; then
      printf '%s' "$input" | curl -s --max-time 10 -X POST \\
        -H 'Content-Type: application/json' --data-binary @- \\
        http://127.0.0.1:53127/hook >/dev/null 2>&1 &
    fi
    exit 0
    """

    /// Install the Codex forwarder + hooks.json. The user must approve the
    /// one-time "trust hooks" review the next time they start Codex.
    static func installCodexHooks() throws {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: installDir, withIntermediateDirectories: true)
        // Forwarder script.
        do {
            try codexForwarderBody.write(toFile: codexForwardScript, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexForwardScript)
        } catch {
            throw InstallError.scriptCopyFailed("codex forwarder: \(error.localizedDescription)")
        }
        // hooks.json. Informational events only (no PreToolUse): Codex's
        // PreToolUse fires for shell only and expects a decision enum we do not
        // emit yet, so blocking permission stays a later phase.
        let cmd = codexForwardScript
        let events = ["UserPromptSubmit", "PostToolUse", "SessionStart", "SessionEnd", "Notification", "Stop"]
        var hooks: [String: Any] = [:]
        for ev in events {
            let handler: [String: Any] = ["type": "command", "command": cmd, "timeout": ev == "SessionEnd" ? 3 : 5]
            let group: [String: Any] = ev == "PostToolUse"
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

        do {
            try fm.createDirectory(atPath: installDir, withIntermediateDirectories: true)
        } catch {
            throw InstallError.scriptCopyFailed(error.localizedDescription)
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
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
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
        if let existing = try? Data(contentsOf: settingsURL) {
            if let obj = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
                settings = obj
            }
            // Stash a backup whether the JSON parsed or not — paranoid wins.
            let ts = Int(Date().timeIntervalSince1970)
            let backupURL = URL(fileURLWithPath: settingsPath + ".before-claudenotch.\(ts)")
            try? existing.write(to: backupURL)
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
        // Context compaction cue for the context meter.
        appendHook(to: "PreCompact", in: &hooks, matcher: nil)
        // Subagent lifecycle: show spawned agents in the activity strip.
        appendHook(to: "SubagentStart", in: &hooks, matcher: nil)
        appendHook(to: "SubagentStop", in: &hooks, matcher: nil)
        settings["hooks"] = hooks

        // StatusLine: the only local source of authoritative context-% and real
        // 5h/weekly plan-limit usage. We point it at our forwarder, preserving
        // (chaining to) whatever the user already had so their terminal status
        // line is unchanged.
        wireStatusLine(in: &settings)

        do {
            let out = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: settingsURL, options: .atomic)
        } catch {
            throw InstallError.settingsWriteFailed(error.localizedDescription)
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
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
