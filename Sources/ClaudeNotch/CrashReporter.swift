import Foundation
import AppKit
import Darwin

/// Catch an uncaught Swift/ObjC exception or a fatal signal and leave a local
/// crash report behind, so when someone hits a bug there is a file to attach to
/// a report instead of nothing. Entirely local: it writes under the app's own
/// Application Support directory (owner-only) and never sends anything anywhere.
///
/// The exception path writes a rich report (version, reason, symbolicated Swift
/// call stack). The signal path is restricted to async-signal-safe calls
/// (`open`, `write`, `backtrace_symbols_fd`) and re-raises the default handler
/// so the OS still records its own crash log.
enum CrashReporter {

    /// Directory reused from DebugLog so all diagnostics live in one owner-only
    /// place. `crashDir` is created 0700 by DebugLog's fileURL initializer.
    static var directory: URL { DebugLog.fileURL.deletingLastPathComponent() }

    /// Kept as a C string so the async-signal-safe handler can `open()` it
    /// without touching Swift String machinery mid-crash.
    private static var signalLogPathC: [CChar] = []

    private static let maxReports = 10

    static func install() {
        // Resolve and cache the signal-log path once, up front.
        let signalLog = directory.appendingPathComponent("crash-signal.log")
        signalLogPathC = Array((signalLog.path as String).utf8CString)

        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.writeExceptionReport(exception)
        }

        for sig in [SIGABRT, SIGSEGV, SIGILL, SIGFPE, SIGBUS, SIGTRAP] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = CrashReporter.handleSignal
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(sig, &action, nil)
        }

        pruneOldReports()
    }

    /// True when at least one crash report is sitting on disk.
    static var hasReports: Bool { !reportURLs().isEmpty }

    /// Reveal the diagnostics directory in Finder (called from the menu).
    static func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    // MARK: - Exception path (rich, runs in a normal context)

    private static func writeExceptionReport(_ exception: NSException) {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        var report = """
        ClaudeNotch crash report
        date: \(Date())
        version: \(version) (build \(build))
        exception: \(exception.name.rawValue)
        reason: \(exception.reason ?? "-")

        call stack:
        """
        report += "\n" + exception.callStackSymbols.joined(separator: "\n") + "\n"

        let stamp = Int(Date().timeIntervalSince1970)
        let url = directory.appendingPathComponent("crash-\(stamp).log")
        try? report.data(using: .utf8)?.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Signal path (async-signal-safe only)

    private static let handleSignal: @convention(c) (Int32) -> Void = { sig in
        // Only async-signal-safe calls past this point: open, write,
        // backtrace_symbols_fd, and re-raising via the default disposition.
        let fd = signalLogPathC.withUnsafeBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return open(base, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        }
        if fd >= 0 {
            let header = "ClaudeNotch fatal signal \(sig)\n"
            header.utf8CString.withUnsafeBufferPointer { b in
                if let base = b.baseAddress { _ = write(fd, base, strlen(base)) }
            }
            var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
            let n = backtrace(&frames, 64)
            backtrace_symbols_fd(&frames, n, fd)
            let nl: [UInt8] = [0x0a]
            _ = nl.withUnsafeBufferPointer { write(fd, $0.baseAddress, 1) }
            close(fd)
        }
        // Restore the default handler and re-raise so the OS logs it too.
        signal(sig, SIG_DFL)
        raise(sig)
    }

    // MARK: - Housekeeping

    private static func reportURLs() -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { $0.lastPathComponent.hasPrefix("crash-") && $0.pathExtension == "log" }
    }

    private static func pruneOldReports() {
        let urls = reportURLs().sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }
        for url in urls.dropFirst(maxReports) { try? FileManager.default.removeItem(at: url) }
    }
}
