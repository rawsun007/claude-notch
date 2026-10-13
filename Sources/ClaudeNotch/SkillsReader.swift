import Foundation

/// Claude Code's skills, as they sit on disk.
///
/// A skill is a folder with a `SKILL.md`: YAML frontmatter (name, description,
/// when to use it) and the instructions. Claude Code lists every skill's name
/// and description to the model on every turn, so a skill nobody uses still
/// costs context in every session. The listing has a budget of about 1% of the
/// context window; past it, Claude Code cuts descriptions, starting with the
/// skills used least, and each entry is capped at 1,536 characters.
///
/// Where they come from (docs: Extend Claude with skills, CLI 2.1.29x):
/// - personal: `~/.claude/skills/<name>/SKILL.md`
/// - project: `<repo>/.claude/skills/<name>/SKILL.md`
/// - claude.ai: synced into `~/.claude/skills/synced/<account>/<name>/`, named
///   `anthropic-skills:<name>`, and downloaded again if deleted locally
/// - plugin: `<plugin>/skills/<name>/SKILL.md`, named `<plugin>:<name>`, and
///   turned off only by disabling the plugin
///
/// Pure parsing and scanning; nothing here writes.
struct SkillInfo: Identifiable, Equatable {
    enum Source: String, CaseIterable { case personal, project, synced, plugin }

    /// The skill's folder, which is unique.
    var id: String { path }
    /// The name Claude Code lists and you type after `/`.
    let name: String
    /// The key it goes under in `skillOverrides` (the full name for synced skills).
    var overrideKey: String { name }
    let source: Source
    /// The project folder, for a project skill.
    let project: String?
    /// The plugin id (`name@marketplace`), for a plugin skill.
    let plugin: String?
    let description: String
    let whenToUse: String
    /// `disable-model-invocation: true` in the frontmatter: hidden from Claude already.
    let modelInvocationDisabled: Bool
    let path: String
    let bytes: Int
    let modified: Date?

    /// Characters this skill adds to the listing Claude reads every turn when
    /// it is fully on: its name plus its description and when-to-use text,
    /// the latter capped at 1,536 characters as Claude Code caps them.
    var listingChars: Int {
        guard !modelInvocationDisabled else { return 0 }
        let text = [description, whenToUse].filter { !$0.isEmpty }.joined(separator: " ")
        return name.count + 4 + min(SkillsReader.maxEntryChars, text.count)
    }
    /// Roughly four characters to a token.
    var listingTokens: Int { (listingChars + 3) / 4 }
    var canTrash: Bool { source == .personal || source == .project }
}

enum SkillsReader {
    static let maxEntryChars = 1_536

    struct Frontmatter: Equatable {
        var fields: [String: String] = [:]
        var name: String? { fields["name"].flatMap { $0.isEmpty ? nil : $0 } }
        var description: String { fields["description"] ?? "" }
        var whenToUse: String { fields["when_to_use"] ?? fields["when-to-use"] ?? "" }
        var disableModelInvocation: Bool { (fields["disable-model-invocation"] ?? "").lowercased() == "true" }
    }

    /// The frontmatter of a SKILL.md: flat `key: value` pairs between the
    /// first two `---` lines, quotes stripped, `>` and `|` block values
    /// joined. Lists and nested maps are skipped; nothing here needs them.
    /// Tolerates a byte-order mark and CRLF line endings.
    nonisolated static func frontmatter(_ text: String) -> Frontmatter {
        var s = text
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        let lines = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return Frontmatter() }
        var fm = Frontmatter(), i = 1
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            i += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("-"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value == ">" || value == "|" || value == ">-" || value == "|-" {
                var parts: [String] = []
                while i < lines.count, lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t") || lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    if lines[i].trimmingCharacters(in: .whitespaces) == "---" { break }
                    parts.append(lines[i].trimmingCharacters(in: .whitespaces)); i += 1
                }
                value = parts.filter { !$0.isEmpty }.joined(separator: " ")
            }
            if value.count >= 2, let f = value.first, let l = value.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
                value = String(value.dropFirst().dropLast())
            }
            fm.fields[key] = value
        }
        return fm
    }

    // MARK: - Scanning

    static var home: String { NSHomeDirectory() }
    static var personalDir: String { (home as NSString).appendingPathComponent(".claude/skills") }

    /// Folder names Claude Code reserves or uses for itself inside a skills folder.
    nonisolated static func isReserved(_ folder: String) -> Bool {
        let f = folder.lowercased()
        return folder.hasPrefix(".") || f == "synced" || f == "anthropic-skills" || f.hasPrefix("anthropic-skills:")
    }

    /// Every skill on this Mac that ClaudeNotch can see: personal, synced,
    /// the given projects', and installed plugins'.
    static func scan(projects: [String]) -> [SkillInfo] {
        var out: [SkillInfo] = []
        out += skills(in: personalDir, source: .personal)
        // One folder per claude.ai account that has synced here; the session
        // loads one skill per name, so a name in two accounts counts once
        // (the copy synced most recently).
        let synced = (personalDir as NSString).appendingPathComponent("synced")
        var syncedSkills: [SkillInfo] = []
        for account in children(synced) where !account.hasPrefix(".") {
            syncedSkills += skills(in: (synced as NSString).appendingPathComponent(account), source: .synced, prefix: "anthropic-skills:", reserved: false)
        }
        out += dedupeNewest(syncedSkills)
        var seen = Set<String>()
        for p in projects where seen.insert(p).inserted {
            out += skills(in: (p as NSString).appendingPathComponent(".claude/skills"), source: .project, project: p)
        }
        for (id, root) in installedPlugins() {
            let pluginName = String(id.split(separator: "@").first ?? Substring(id))
            out += skills(in: (root as NSString).appendingPathComponent("skills"), source: .plugin, plugin: id, prefix: pluginName + ":", reserved: false)
        }
        return out
    }

    private static func children(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
    }

    private static func skills(in dir: String, source: SkillInfo.Source, project: String? = nil, plugin: String? = nil,
                               prefix: String = "", reserved: Bool = true) -> [SkillInfo] {
        var out: [SkillInfo] = []
        for folder in children(dir) {
            if folder.hasPrefix(".") || (reserved && isReserved(folder)) { continue }
            let path = (dir as NSString).appendingPathComponent(folder)
            let md = (path as NSString).appendingPathComponent("SKILL.md")
            guard let data = FileManager.default.contents(atPath: md),
                  let text = String(data: data.prefix(64 * 1024), encoding: .utf8) else { continue }
            let fm = frontmatter(text)
            let attrs = try? FileManager.default.attributesOfItem(atPath: md)
            out.append(SkillInfo(name: prefix + (fm.name ?? folder), source: source, project: project, plugin: plugin,
                                 description: fm.description, whenToUse: fm.whenToUse,
                                 modelInvocationDisabled: fm.disableModelInvocation,
                                 path: path, bytes: folderSize(path), modified: attrs?[.modificationDate] as? Date))
        }
        return out
    }

    /// One skill per name, the most recently modified copy.
    nonisolated static func dedupeNewest(_ skills: [SkillInfo]) -> [SkillInfo] {
        var best: [String: SkillInfo] = [:]
        for s in skills {
            if let b = best[s.name], (b.modified ?? .distantPast) >= (s.modified ?? .distantPast) { continue }
            best[s.name] = s
        }
        return skills.filter { best[$0.name]?.path == $0.path }
    }

    /// Bytes on disk under a skill folder. A skill folder may itself be a
    /// symlink (Claude Code allows it), so that one link is resolved first.
    static func folderSize(_ path: String) -> Int {
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += v?.totalFileAllocatedSize ?? 0 }
        }
        return total
    }

    /// Installed plugins and where each lives, from `~/.claude/plugins/installed_plugins.json`.
    static func installedPlugins() -> [(id: String, path: String)] {
        let file = (home as NSString).appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = FileManager.default.contents(atPath: file) else { return [] }
        return installedPlugins(json: data)
    }

    /// Pure, for tests: each plugin id with the install path of its newest entry.
    nonisolated static func installedPlugins(json data: Data) -> [(id: String, path: String)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any] else { return [] }
        return plugins.keys.sorted().compactMap { id in
            guard let entries = plugins[id] as? [[String: Any]],
                  let path = entries.last?["installPath"] as? String, !path.isEmpty else { return nil }
            return (id, path)
        }
    }
}

/// How often a skill has run, as ClaudeNotch has seen it through the hooks:
/// Claude invoking it (the Skill tool) or you typing it as a slash command.
/// Only counts from when ClaudeNotch started watching, so "never" means
/// "not since then".
struct SkillUse: Codable, Equatable {
    var count: Int
    var last: Date

    /// Usage is kept for this many skill names at most.
    static let cap = 300

    /// The skill a Skill tool call ran, from its input: `{"skill": "pdf"}`.
    /// Leading slash dropped, trimmed, capped (it is payload text).
    nonisolated static func name(fromToolInput input: [String: Any]) -> String? {
        normalize(input["skill"] as? String)
    }

    nonisolated static func normalize(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("/") { s.removeFirst() }
        if let space = s.firstIndex(of: " ") { s = String(s[..<space]) }
        return s.isEmpty ? nil : String(s.prefix(120))
    }

    /// The usage record for a skill, by its full name or, for a synced or
    /// plugin skill, the short name after the colon (both can be typed).
    nonisolated static func lookup(_ usage: [String: SkillUse], name: String) -> SkillUse? {
        let short = name.split(separator: ":").last.map(String.init) ?? name
        let a = usage[name], b = name == short ? nil : usage[short]
        switch (a, b) {
        case let (x?, y?): return SkillUse(count: x.count + y.count, last: max(x.last, y.last))
        default: return a ?? b
        }
    }
}
