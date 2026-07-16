import Foundation

/// One place for the app's diagnostic log.
///
/// This used to be four copies of the same `append to /tmp/claudenotch-debug.log`
/// scattered across the codebase. A world-readable file in `/tmp` is the wrong
/// home for it: the log carries working directories, session ids, transcript
/// paths and cost figures, and on a shared machine anyone could read it. It also
/// grew forever, with no rotation.
///
/// It lives under the user's own Application Support now, created `0700`, with the
/// file itself `0600`, and it rotates once it passes a size cap so it cannot fill
/// the disk over months of use.
enum DebugLog {

    private static let queue = DispatchQueue(label: "com.claudenotch.debuglog")
    private static let maxBytes: UInt64 = 512 * 1024

    /// Off by default. The log is a diagnostic aid, not a normal-operation
    /// artefact — writing session ids, working directories, transcript paths and
    /// costs to disk on every hook is a privacy cost and a steady trickle of IO
    /// nobody asked for. Turn it on for a session by launching with
    /// CLAUDENOTCH_DEBUG=1 (or dropping a `debug-logging` marker file next to the
    /// log), and it stays silent otherwise.
    static let isEnabled: Bool = {
        if let v = ProcessInfo.processInfo.environment["CLAUDENOTCH_DEBUG"],
           v == "1" || v.lowercased() == "true" {
            return true
        }
        let marker = fileURL.deletingLastPathComponent().appendingPathComponent("debug-logging")
        return FileManager.default.fileExists(atPath: marker.path)
    }()

    static let fileURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("ClaudeNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("debug.log")
    }()

    static func append(_ category: String, _ message: String) {
        guard isEnabled else { return }
        let line = "[\(Date())] \(category): \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            let fm = FileManager.default
            let path = fileURL.path

            if !fm.fileExists(atPath: path) {
                // Create it owner-only from the start, before a single byte lands.
                fm.createFile(atPath: path, contents: nil,
                              attributes: [.posixPermissions: 0o600])
            } else if let size = (try? fm.attributesOfItem(atPath: path)[.size]) as? UInt64,
                      size > maxBytes {
                // Rotate: keep one previous generation, drop the rest.
                let old = fileURL.deletingLastPathComponent().appendingPathComponent("debug.log.1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: fileURL, to: old)
                fm.createFile(atPath: path, contents: nil,
                              attributes: [.posixPermissions: 0o600])
            }

            if let h = try? FileHandle(forWritingTo: fileURL) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            }
        }
    }
}
