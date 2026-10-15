import Foundation

/// Single top-level settings in Claude Code's user settings
/// (`~/.claude/settings.json`), read and written the way SkillSettings does:
/// merge one key, keep every other key, never replace a file that does not
/// parse.
enum ClaudeCodeSettings {
    /// `idleCompaction` (CLI 2.1.299+): compact a long conversation left idle
    /// for about 54 minutes, before its one-hour prompt cache expires, so the
    /// next message does not pay to rebuild it. Absent means on.
    static let idleCompactionKey = "idleCompaction"

    /// A boolean setting, or nil when it is not set.
    nonisolated static func bool(_ key: String, in data: Data?) -> Bool? {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root[key] as? Bool
    }

    /// The settings JSON with one top-level key set (nil removes it).
    nonisolated static func setting(_ data: Data?, key: String, value: Any?) throws -> Data {
        var root: [String: Any] = [:]
        if let data, !data.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SkillSettings.WriteError.unreadable("settings")
            }
            root = obj
        }
        root[key] = value
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func bool(_ key: String) -> Bool? { bool(key, in: FileManager.default.contents(atPath: SkillSettings.userSettingsPath)) }

    static func set(_ key: String, _ value: Any?) throws {
        let path = SkillSettings.userSettingsPath
        do {
            let new = try setting(FileManager.default.contents(atPath: path), key: key, value: value)
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try new.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch SkillSettings.WriteError.unreadable { throw SkillSettings.WriteError.unreadable(path) }
    }
}
