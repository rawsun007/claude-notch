import Foundation
import AppKit

extension NSPasteboard {
    /// Replace the general pasteboard's contents with a single string. Every
    /// copy button did the clear + setString dance by hand; this keeps it in one
    /// place.
    static func copyString(_ s: String) {
        general.clearContents()
        general.setString(s, forType: .string)
    }
}

/// Thin wrapper around Process for the two shapes the app actually uses: capture
/// a command's stdout, or just check whether it exited cleanly. Keeps the
/// Process + Pipe + waitUntilExit boilerplate in one place instead of being
/// re-typed (and subtly varied) at every call site. Both calls block until the
/// process exits, so invoke them off the main thread.
enum Shell {
    /// POSIX single-quote a string for safe embedding in a shell command line:
    /// wrap in single quotes and escape any embedded single quote as '\''.
    /// The one implementation behind every shell-quoting call in the app.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Run `path args` and return stdout as a string (stderr discarded). Nil
    /// only when the process could not be launched.
    static func output(_ path: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        // Drain the pipe before waiting: a large payload can fill the pipe
        // buffer and deadlock a child that blocks on write while we block on
        // exit. For our tiny outputs it doesn't matter, but the safe order is
        // free.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Run `path args` and report whether it exited 0 (all output discarded).
    static func succeeds(_ path: String, _ args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run(); task.waitUntilExit() } catch { return false }
        return task.terminationStatus == 0
    }
}
