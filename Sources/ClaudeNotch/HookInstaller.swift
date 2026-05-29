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

    /// True when settings.json references our dispatcher AND the script
    /// actually exists on disk. Either alone isn't enough — a wired entry
    /// pointing at a missing script will just fail silently per-hook.
    static var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: hookEntryPoint) else { return false }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains("claudenotch-hook.sh")
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
        appendHook(to: "PostToolUse", in: &hooks, matcher: ".*")
        appendHook(to: "UserPromptSubmit", in: &hooks, matcher: nil)
        appendHook(to: "Notification", in: &hooks, matcher: nil)
        appendHook(to: "Stop", in: &hooks, matcher: nil)
        appendHook(to: "SessionEnd", in: &hooks, matcher: ".*")
        // Task lifecycle drives the per-session progress meter. These events
        // take no matcher (they always fire on every occurrence).
        appendHook(to: "TaskCreated", in: &hooks, matcher: nil)
        appendHook(to: "TaskCompleted", in: &hooks, matcher: nil)
        settings["hooks"] = hooks

        do {
            let out = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: settingsURL, options: .atomic)
        } catch {
            throw InstallError.settingsWriteFailed(error.localizedDescription)
        }
    }

    /// Append our hook into an event's rule list without clobbering anything
    /// the user already has there. Idempotent: any previous ClaudeNotch entry
    /// for this event is removed first so reinstalling doesn't duplicate it.
    private static func appendHook(to eventName: String, in hooks: inout [String: Any], matcher: String?) {
        let cmd: [String: Any] = ["type": "command", "command": shellQuote(hookEntryPoint)]
        var ourRule: [String: Any] = ["hooks": [cmd]]
        if let m = matcher { ourRule["matcher"] = m }

        var existingList = (hooks[eventName] as? [[String: Any]]) ?? []
        existingList.removeAll { rule in
            let subHooks = (rule["hooks"] as? [[String: Any]]) ?? []
            return subHooks.contains { sub in
                if sub["type"] as? String == "command",
                   let c = sub["command"] as? String {
                    return c.contains("claudenotch-hook.sh")
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
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
