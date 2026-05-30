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
            debugLog("sendText: refused — empty text")
            return
        }
        debugLog("sendText start: bid=\(bundleID) len=\(text.count) accessibility=\(isAccessibilityTrusted)")

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate(options: [.activateIgnoringOtherApps])
            debugLog("sendText: activated \(app.localizedName ?? bundleID)")
        } else {
            debugLog("sendText: WARNING — no running app with bid=\(bundleID)")
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

    nonisolated private static func debugLog(_ msg: String) {
        let url = URL(fileURLWithPath: "/tmp/claudenotch-debug.log")
        let line = "[\(Date())] automator: \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Open a new Terminal.app window in the given directory and run `claude`.
    /// Resolve the absolute path to the `claude` CLI by asking an interactive
    /// login shell (so PATH additions from .zshrc/.zprofile are honoured —
    /// e.g. ~/.local/bin). Returns nil if it can't be found.
    static func resolveClaudePath() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-ilc", "command -v claude"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        // The interactive shell may print session noise; take the last line
        // that looks like an absolute path to a `claude` binary.
        for line in out.split(separator: "\n").reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("/"), t.hasSuffix("claude") { return t }
        }
        return nil
    }

    /// Open a new terminal window, cd into the folder, and launch the Claude
    /// CLI — optionally with an initial `message` passed as the first prompt
    /// (`claude "message"`). Uses a temp `.command` file (run by the user's
    /// default terminal) rather than AppleScript — so it needs NO Automation
    /// permission and the full claude path works regardless of shell PATH.
    static func startClaude(in directory: String, message: String? = nil) {
        let claude = resolveClaudePath() ?? "claude"
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let launch = trimmed.isEmpty
            ? "exec \(shellQuote(claude))"
            : "exec \(shellQuote(claude)) \(shellQuote(trimmed))"
        let body = """
        #!/bin/zsh
        cd \(shellQuote(directory)) || exit 1
        clear
        \(launch)
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeNotch-start-\(UUID().uuidString).command")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
            debugLog("startClaude: opened \(url.lastPathComponent) → cd \(directory) && claude \(trimmed.isEmpty ? "" : "<msg>")")
        } catch {
            debugLog("startClaude: failed to write/open .command — \(error)")
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Activates the target app and sends 1-based option indexes as
    /// `<digit><return>` for each question. Runs the AppleScript on a
    /// background queue so the caller doesn't block.
    ///
    /// - Parameters:
    ///   - indexes: 1-based option numbers, one per question.
    ///   - bundleID: bundle id of the terminal/IDE hosting Claude Code.
    ///   - prePromptDelay: seconds to wait *inside* the script before typing,
    ///     to let Claude Code render the prompt after the hook returns.
    static func sendAnswers(_ indexes: [Int], toBundleID bundleID: String, prePromptDelay: Double = 0.45) {
        guard !indexes.isEmpty else { return }

        // Activate the target app from the main thread so it's already
        // coming forward while AppleScript spins up.
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate(options: [.activateIgnoringOtherApps])
        }

        let keystrokes = indexes.map { idx in
            """
                keystroke "\(idx)"
                key code 36
                delay 0.18
            """
        }.joined(separator: "\n")

        let source = """
        tell application id "\(bundleID)" to activate
        delay \(prePromptDelay)
        tell application "System Events"
        \(keystrokes)
        end tell
        """

        DispatchQueue.global(qos: .userInitiated).async {
            guard let script = NSAppleScript(source: source) else {
                NSLog("ClaudeNotch automator: failed to compile script")
                return
            }
            var err: NSDictionary?
            script.executeAndReturnError(&err)
            if let err {
                NSLog("ClaudeNotch automator: AppleScript error \(err)")
            }
        }
    }
}
