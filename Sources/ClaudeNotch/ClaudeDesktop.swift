import AppKit
import Foundation

/// Hands a Claude Code session to the Claude desktop app.
///
/// Since CLI 2.1.285, `claude --desktop --resume <id>` opens that session in
/// Claude Desktop's Code tab instead of the terminal. The CLI does the hand
/// off, so this only finds the CLI and runs it from the session's folder
/// (`--resume` is scoped to the project directory, the same as in a terminal).
enum ClaudeDesktop {
    static let bundleID = "com.anthropic.claudefordesktop"

    /// Is the desktop app on this Mac? The menu item only shows when it is.
    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// The CLI arguments, or nil for an id that is not safe to pass.
    ///
    /// A session id reaches here from a transcript filename or a hook
    /// payload. It goes in an argument array, never a shell line, so quoting
    /// is not the risk; an id starting with `-` being read as another flag is.
    /// Real ids are UUIDs, so anything outside letters, digits and dashes, or
    /// starting with a dash, is refused.
    nonisolated static func arguments(sessionId: String) -> [String]? {
        guard !sessionId.isEmpty, !sessionId.hasPrefix("-"),
              sessionId.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" })
        else { return nil }
        return ["--desktop", "--resume", sessionId]
    }

    /// Open the session in Claude Desktop. Runs off the main thread; the CLI
    /// exits once the app has it, and is stopped after 30 seconds if it does not.
    static func open(sessionId: String, in directory: String) {
        guard let args = arguments(sessionId: sessionId) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let claude = TerminalAutomator.resolveClaudePath() else {
                DebugLog.append("desktop", "claude CLI not found")
                return
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: claude)
            p.arguments = args
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue {
                p.currentDirectoryURL = URL(fileURLWithPath: directory)
            }
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                DebugLog.append("desktop", "could not run claude --desktop: \(error.localizedDescription)")
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if p.isRunning { p.terminate() } }
        }
    }
}
