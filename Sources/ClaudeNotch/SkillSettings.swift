import Foundation

/// Reads and writes the two settings that turn skills on and off.
///
/// - `skillOverrides`: a map of skill name to `"on"`, `"name-only"`,
///   `"user-invocable-only"` or `"off"`. Absent means on. Claude Code's own
///   `/skills` menu writes the same key, so this is the supported switch. User
///   settings (`~/.claude/settings.json`) apply to every project; a project's
///   `.claude/settings.local.json` applies to that project only and wins.
/// - `enabledPlugins`: `"<plugin>@<marketplace>": false` turns a plugin off,
///   and with it its skills (plugin skills ignore `skillOverrides`).
///
/// Writes merge into the file and keep every other key exactly as it was. A
/// file that is there but does not parse is never overwritten.
enum SkillSettings {
    enum Visibility: String, CaseIterable, Identifiable {
        case on, nameOnly = "name-only", userOnly = "user-invocable-only", off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .on: return L("On", comment: "Skill state: listed to Claude with its description")
            case .nameOnly: return L("Name only", comment: "Skill state: listed to Claude without its description")
            case .userOnly: return L("Only when I type it", comment: "Skill state: hidden from Claude, still available as a slash command")
            case .off: return L("Off", comment: "Skill state: hidden everywhere")
            }
        }
        var help: String {
            switch self {
            case .on: return L("Claude sees its name and description and can use it on its own.", comment: "Skill state explanation")
            case .nameOnly: return L("Claude sees only its name: much less context, but it may be picked less often.", comment: "Skill state explanation")
            case .userOnly: return L("Hidden from Claude. You can still run it by typing its slash command.", comment: "Skill state explanation")
            case .off: return L("Hidden from Claude and from the slash menu.", comment: "Skill state explanation")
            }
        }
    }

    enum WriteError: Error, LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            if case .unreadable(let p) = self { return String(format: L("%@ is not valid JSON, so ClaudeNotch left it alone.", comment: "Error when a settings file cannot be parsed. %@ is the path"), p) }
            return nil
        }
    }

    static var userSettingsPath: String { (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json") }
    static func projectLocalPath(_ project: String) -> String { (project as NSString).appendingPathComponent(".claude/settings.local.json") }

    // MARK: - Pure

    /// The overrides in a settings file's JSON.
    nonisolated static func overrides(in data: Data?) -> [String: Visibility] {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = root["skillOverrides"] as? [String: Any] else { return [:] }
        var out: [String: Visibility] = [:]
        for (k, v) in map { if let s = v as? String, let vis = Visibility(rawValue: s) { out[k] = vis } }
        return out
    }

    /// The enabled flags in a settings file's JSON. Absent means enabled.
    nonisolated static func enabledPlugins(in data: Data?) -> [String: Bool] {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = root["enabledPlugins"] as? [String: Any] else { return [:] }
        return map.compactMapValues { $0 as? Bool }
    }

    /// The settings JSON with one value set inside one map key, everything
    /// else untouched. `value` nil removes the entry, and an emptied map is
    /// removed with it. Throws on JSON that is there but is not an object.
    nonisolated static func setting(_ data: Data?, map: String, key: String, value: Any?) throws -> Data {
        var root: [String: Any] = [:]
        if let data, !data.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WriteError.unreadable("settings") }
            root = obj
        }
        var inner = (root[map] as? [String: Any]) ?? [:]
        inner[key] = value
        root[map] = inner.isEmpty ? nil : inner
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - Files

    static func overrides(at path: String) -> [String: Visibility] { overrides(in: FileManager.default.contents(atPath: path)) }
    static func enabledPlugins() -> [String: Bool] { enabledPlugins(in: FileManager.default.contents(atPath: userSettingsPath)) }

    /// Set a skill's state in a settings file. `.on` removes the entry, since
    /// absent already means on and that keeps the file as small as it was.
    static func setVisibility(_ vis: Visibility, for key: String, at path: String) throws {
        try write(path) { try setting($0, map: "skillOverrides", key: key, value: vis == .on ? nil : vis.rawValue) }
    }

    /// Turn a plugin on or off in user settings.
    static func setPlugin(_ id: String, enabled: Bool) throws {
        try write(userSettingsPath) { try setting($0, map: "enabledPlugins", key: id, value: enabled) }
    }

    private static func write(_ path: String, _ change: (Data?) throws -> Data) throws {
        let url = URL(fileURLWithPath: path)
        let old = FileManager.default.contents(atPath: path)
        do {
            let new = try change(old)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try new.write(to: url, options: .atomic)
        } catch WriteError.unreadable { throw WriteError.unreadable(path) }
    }
}
