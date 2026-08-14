import Foundation
import Darwin

// Every running Claude Code session on this machine, whether or not it ever
// spoke to us.
//
// Claude Code writes one file per live session to ~/.claude/sessions/<pid>.json
// (the registry behind `ListAgents` and cross-session `SendMessage`). It holds
// the pid, session id, cwd, CLI version, the name `/rename` gave it, and
// busy/idle.
//
// This closes the app's oldest blind spot. The notch only ever knew sessions
// that fired a hook at it, so a session started before the app launched, or in
// a project whose settings never got the hooks, was invisible. And when a
// session died the app inferred it from silence; a pid either exists or it
// does not.
//
// Parsing is pure and takes Data, so the shapes this has to survive are
// testable without a filesystem.

enum SessionRegistry {

    struct Entry: Equatable {
        let pid: Int32
        let sessionId: String
        let cwd: String
        /// The CLI version this session is running. The notch shows facts that
        /// need a minimum version (sandbox needs 2.1.219+), so it matters which
        /// build a given session is.
        let version: String
        /// "interactive" for a terminal session; other values exist for the
        /// SDK and remote hosts.
        let kind: String
        /// "busy" or "idle" as the CLI last wrote it.
        let status: String
        /// What `/rename` set, or the name the CLI derived.
        let name: String
        let updatedAt: Date?

        var isBusy: Bool { status == "busy" }
    }

    static let directory: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/sessions")
    }()

    /// A registry file whose process is gone but whose file was never cleaned
    /// up is a crash leftover. Pid liveness catches almost all of those; this
    /// catches the rest, where a new process has since been given the same pid.
    /// Generous, because an idle session can go a long time without an update.
    static let maxAge: TimeInterval = 24 * 3600

    /// Parse one `<pid>.json`. Nil when it isn't one: the directory also holds
    /// `.key` files and whatever a future release puts there.
    nonisolated static func parse(_ data: Data) -> Entry? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        // A registry entry without a pid or a session id cannot be matched to
        // anything, which makes it useless rather than partially useful.
        guard let pid = intValue(obj["pid"]), pid > 0 else { return nil }
        let sessionId = (obj["sessionId"] as? String) ?? (obj["session_id"] as? String) ?? ""
        guard !sessionId.isEmpty else { return nil }

        return Entry(
            pid: Int32(truncatingIfNeeded: pid),
            sessionId: sessionId,
            cwd: normalized((obj["cwd"] as? String) ?? ""),
            version: (obj["version"] as? String) ?? "",
            kind: (obj["kind"] as? String) ?? "",
            status: (obj["status"] as? String) ?? "",
            name: (obj["name"] as? String) ?? "",
            updatedAt: millisDate(obj["updatedAt"]) ?? millisDate(obj["startedAt"]))
    }

    /// Whether a registry entry describes something still running.
    ///
    /// `now` is injectable so the age rule can be tested without waiting a day.
    nonisolated static func isCurrent(_ entry: Entry, now: Date = Date(),
                                      alive: (Int32) -> Bool = processExists) -> Bool {
        guard alive(entry.pid) else { return false }
        guard let updatedAt = entry.updatedAt else { return true }
        // A clock skew or a file written "in the future" is not a reason to
        // hide a session whose process is alive.
        return now.timeIntervalSince(updatedAt) < maxAge
    }

    /// Does this pid exist? `kill(pid, 0)` asks the kernel and changes nothing.
    /// EPERM means it exists and belongs to someone else, which still counts as
    /// existing.
    nonisolated static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Every live session in the registry, newest update first.
    nonisolated static func read(directory dir: String = directory,
                                 now: Date = Date()) -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [Entry] = []
        for name in names where name.hasSuffix(".json") {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: path),
                  let entry = parse(data),
                  isCurrent(entry, now: now) else { continue }
            out.append(entry)
        }
        return out.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    // MARK: - Helpers

    /// The registry's status vocabulary in the notch's own words. Only ever
    /// used for a session no hook has described: a hook knows which TOOL is
    /// running, and "busy" must not overwrite that with less.
    nonisolated static func statusLabel(_ status: String) -> String {
        switch status {
        case "busy":     return "thinking"
        case "idle", "": return "ready"
        default:         return status
        }
    }

    nonisolated private static func normalized(_ cwd: String) -> String {
        var out = cwd
        while out.count > 1, out.hasSuffix("/") { out.removeLast() }
        return out
    }

    nonisolated private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    /// The registry writes epoch milliseconds. Seconds are accepted too, in
    /// case that ever changes: a timestamp read a thousand times too small
    /// would put every session in 1970 and hide all of them.
    nonisolated private static func millisDate(_ any: Any?) -> Date? {
        guard let raw = (any as? Double) ?? (any as? Int).map(Double.init) else { return nil }
        guard raw > 0 else { return nil }
        let seconds = raw > 4_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }
}
