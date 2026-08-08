import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Types digits + Enter into a target app to answer Claude Code's AskUserQuestion
/// prompts. Needs macOS Accessibility permission for "System Events" keystrokes.
@MainActor
enum TerminalAutomator {

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Opens the system Accessibility settings + the macOS prompt asking the
    /// user to add ClaudeNotch to the trusted list.
    static func requestAccessibility() {
        let opts: NSDictionary = ["AXTrustedCheckOptionPrompt" as NSString: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    /// Activate `bundleID`, type the given text, then press Return.
    /// Used by "Send message to Claude" — types whatever you wrote into the
    /// terminal where Claude Code is running.
    static func sendText(_ text: String, toBundleID bundleID: String, prePromptDelay: Double = 0.25) {
        guard !text.isEmpty else {
            debugLog("sendText: refused, empty text")
            return
        }
        debugLog("sendText start: bid=\(bundleID) len=\(text.count) accessibility=\(isAccessibilityTrusted)")

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate(options: [.activateIgnoringOtherApps])
            debugLog("sendText: activated \(app.localizedName ?? bundleID)")
        } else {
            debugLog("sendText: WARNING, no running app with bid=\(bundleID)")
        }

        // Type via synthesized CGEvents rather than AppleScript "tell System
        // Events". CGEvent posting needs only Accessibility (which we have),
        // NOT the separate Automation/Apple-Events permission — AppleScript was
        // failing with -1743 "Not authorized to send Apple events to System
        // Events". This also sidesteps AppleScript string escaping entirely.
        DispatchQueue.main.asyncAfter(deadline: .now() + prePromptDelay) {
            postUnicodeText(text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                postKeyCode(0x24)   // Return / Enter
                debugLog("sendText: posted \(text.count) chars + Return via CGEvent")
            }
        }
    }

    /// Inject a string as synthetic key events into the frontmost app. Chunked
    /// because a single event's unicode payload can be capped by the receiver.
    nonisolated private static func postUnicodeText(_ s: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let units = Array(s.utf16)
        guard !units.isEmpty else { return }
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                up.post(tap: .cghidEventTap)
            }
            i += 20
        }
    }

    nonisolated private static func postKeyCode(_ code: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) {
            up.post(tap: .cghidEventTap)
        }
    }

    nonisolated private static func debugLog(_ msg: String) { DebugLog.append("automator", msg) }

    /// Open a new Terminal.app window in the given directory and run `claude`.
    /// Resolve the absolute path to the `claude` CLI by asking an interactive
    /// login shell (so PATH additions from .zshrc/.zprofile are honoured —
    /// e.g. ~/.local/bin). Returns nil if it can't be found.
    nonisolated static func resolveClaudePath() -> String? { resolveCLIPath("claude") }

    /// Resolve the absolute path to a CLI named `name` by asking an interactive
    /// login shell (`zsh -ilc "command -v <name>"`), so PATH additions from
    /// .zshrc/.zprofile are honoured (e.g. ~/.local/bin). The interactive shell
    /// can print session noise, so we take the last line that looks like an
    /// absolute path to the binary. Returns nil if it can't be found.
    nonisolated static func resolveCLIPath(_ name: String) -> String? {
        guard let out = Shell.output("/bin/zsh", ["-ilc", "command -v \(name)"]) else { return nil }
        for line in out.split(separator: "\n").reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("/"), t.hasSuffix(name) { return t }
        }
        return nil
    }

    /// Open a new terminal window, cd into the folder, and launch the Claude
    /// CLI — optionally with an initial `message` passed as the first prompt
    /// (`claude "message"`). Uses a temp `.command` file (run by the user's
    /// default terminal) rather than AppleScript — so it needs NO Automation
    /// permission and the full claude path works regardless of shell PATH.
    /// Open a background agent in a terminal (`claude attach <short-id>`).
    ///
    /// A background agent has no terminal of its own — that is the whole point of
    /// it — so attaching is the only way to see what it is doing or answer it.
    static func attachAgent(id: String, in directory: String) {
        let claude = resolveClaudePath() ?? "claude"
        runInTerminal(dir: directory,
                      exec: "\(shellQuote(claude)) attach \(shellQuote(id))",
                      label: "attach \(id)")
    }

    /// cd into a directory and `exec` a command in a fresh terminal window. The
    /// cd / clear / exec skeleton is identical for every launcher (start/resume,
    /// Claude/Codex, attach); centralising it is how they stop drifting apart.
    /// `exec` is the already-quoted command line to run (this adds `exec`).
    nonisolated private static func runInTerminal(dir: String, exec: String, label: String) {
        openInTerminal("""
        #!/bin/zsh
        cd \(shellQuote(dir)) || exit 1
        clear
        exec \(exec)
        """, label: label)
    }

    /// Write a script and hand it to Terminal. Both entry points do the same
    /// thing, and doing it twice is how they drift apart.
    nonisolated private static func openInTerminal(_ body: String, label: String) {
        sweepStaleCommandFiles()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeNotch-start-\(UUID().uuidString).command")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            // 0o700, not 0o755: these scripts embed the working directory and any
            // message the user is sending to the agent. The temp dir is already
            // per-user, but there is no reason for the file to be group/other
            // readable on top of that.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            // activates=false: open the .command WITHOUT bringing the terminal
            // app to the front. Activating it made macOS jump to whatever Space
            // the terminal's frontmost (often fullscreen) window was on, while
            // the new window opened back on the drop Space. Not activating keeps
            // the new window on the current Space; the user clicks to focus it.
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            NSWorkspace.shared.open(url, configuration: cfg) { _, err in
                if let err { debugLog("openInTerminal: open failed, \(err)") }
            }
            debugLog("openInTerminal: \(label) → \(url.lastPathComponent)")
        } catch {
            debugLog("openInTerminal: failed to write/open .command, \(error)")
        }
    }

    /// Delete leftover launcher scripts from earlier launches. Each `exec`s and
    /// so never removes itself, and each embeds a cwd and possibly a prompt, so
    /// without this they pile up in the temp dir indefinitely. Only touch our own
    /// files, and only ones older than an hour so a script still being read by a
    /// just-opened terminal is never yanked out from under it.
    nonisolated private static func sweepStaleCommandFiles() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for url in items where url.lastPathComponent.hasPrefix("ClaudeNotch-start-")
            && url.pathExtension == "command" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: url) }
        }
    }

    static func startClaude(in directory: String, message: String? = nil) {
        // resolveClaudePath() spawns an interactive login shell and blocks on
        // waitUntilExit(), which can take a second or more (it sources .zshrc).
        // On the main thread that freezes the UI — after a drag-and-drop the
        // dragged file image and the drop panel stayed frozen on screen until
        // the shell finally returned. Do the blocking work off the main thread
        // so the drop completes and the panel clears immediately.
        DispatchQueue.global(qos: .userInitiated).async {
            let claude = resolveClaudePath() ?? "claude"
            let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let cmd = trimmed.isEmpty
                ? shellQuote(claude)
                : "\(shellQuote(claude)) \(shellQuote(trimmed))"
            runInTerminal(dir: directory, exec: cmd, label: "start in \(directory)")
        }
    }

    /// Resume a past session, dispatching to the right CLI by the session's
    /// model. Single entry point so callers stop re-deriving the Claude-vs-Codex
    /// branch every time they want to resume something.
    static func resume(model: String, sessionId: String, in directory: String) {
        if AgentKind.infer(fromModel: model) == .codex {
            resumeCodex(sessionId: sessionId, in: directory)
        } else {
            resumeClaude(sessionId: sessionId, in: directory)
        }
    }

    /// The shell command a user would type to resume this session themselves.
    nonisolated static func resumeCommand(model: String, sessionId: String) -> String {
        AgentKind.infer(fromModel: model) == .codex
            ? "codex resume \(sessionId)"
            : "claude --resume \(sessionId)"
    }

    /// Reopen a past Claude Code session in a fresh terminal
    /// (`claude --resume <session-id>`), run from its original working
    /// directory — `--resume` is scoped to the project dir, so the cd matters.
    /// This is the recovery path after a terminal was closed by accident.
    static func resumeClaude(sessionId: String, in directory: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let claude = resolveClaudePath() ?? "claude"
            runInTerminal(dir: directory,
                          exec: "\(shellQuote(claude)) --resume \(shellQuote(sessionId))",
                          label: "resume \(sessionId)")
        }
    }

    /// Reopen a past Codex session (`codex resume <session-id>`) in a fresh
    /// terminal, from its original directory.
    static func resumeCodex(sessionId: String, in directory: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let codex = resolveCodexPath() ?? "codex"
            runInTerminal(dir: directory,
                          exec: "\(shellQuote(codex)) resume \(shellQuote(sessionId))",
                          label: "codex resume \(sessionId)")
        }
    }

    /// Open a new terminal and launch Codex in a directory.
    static func startCodex(in directory: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let codex = resolveCodexPath() ?? "codex"
            runInTerminal(dir: directory, exec: shellQuote(codex),
                          label: "start codex in \(directory)")
        }
    }

    /// Resolve the absolute path to the `codex` CLI via an interactive login
    /// shell (honours ~/.local/bin etc.). Returns nil if not found.
    nonisolated static func resolveCodexPath() -> String? { resolveCLIPath("codex") }

    // MARK: - Self-update

    /// The bundled updater, installed next to the hook scripts.
    nonisolated static var updateScriptPath: String {
        (HookInstaller.installDir as NSString).appendingPathComponent("claudenotch-update.sh")
    }

    /// True when the updater is on disk, i.e. when Update Now can do anything.
    nonisolated static var canSelfUpdate: Bool {
        FileManager.default.isExecutableFile(atPath: updateScriptPath)
    }

    /// Run the updater in a terminal window.
    ///
    /// Until now the About page printed this command and offered to copy it,
    /// which meant every update went: read the box, copy, find a terminal,
    /// paste, return. Downloads per release say how well that worked. The
    /// script was already on disk and already did the whole job.
    ///
    /// In a terminal rather than as a child process, for two reasons. The
    /// script quits ClaudeNotch and replaces the bundle, so its parent would be
    /// the app it is deleting. And it verifies the DMG against the checksum
    /// published with the release, which is worth watching happen rather than
    /// taking on trust from a progress bar.
    @discardableResult
    static func runUpdater() -> Bool {
        guard canSelfUpdate else { return false }
        runInTerminal(dir: NSHomeDirectory(),
                      exec: shellQuote(updateScriptPath),
                      label: "self-update")
        return true
    }

    nonisolated private static func shellQuote(_ s: String) -> String { Shell.quote(s) }
}
