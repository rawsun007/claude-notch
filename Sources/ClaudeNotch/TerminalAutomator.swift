import AppKit
import ApplicationServices
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
        guard !text.isEmpty else { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        // Escape backslashes and double-quotes for the AppleScript string literal.
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let source = """
        tell application id "\(bundleID)" to activate
        delay \(prePromptDelay)
        tell application "System Events"
            keystroke "\(escaped)"
            delay 0.05
            key code 36
        end tell
        """

        DispatchQueue.global(qos: .userInitiated).async {
            guard let script = NSAppleScript(source: source) else { return }
            var err: NSDictionary?
            script.executeAndReturnError(&err)
            if let err { NSLog("ClaudeNotch sendText AppleScript error: \(err)") }
        }
    }

    /// Open a new Terminal.app window in the given directory and run `claude`.
    static func startClaude(in directory: String) {
        // Use AppleScript to open a fresh Terminal window and run the command.
        let escapedDir = directory
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let source = """
        tell application "Terminal"
            activate
            do script "cd \\"\(escapedDir)\\" && claude"
        end tell
        """

        DispatchQueue.global(qos: .userInitiated).async {
            guard let script = NSAppleScript(source: source) else { return }
            var err: NSDictionary?
            script.executeAndReturnError(&err)
            if let err { NSLog("ClaudeNotch startClaude AppleScript error: \(err)") }
        }
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
