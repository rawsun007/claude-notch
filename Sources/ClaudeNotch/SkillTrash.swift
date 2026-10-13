import Foundation

/// Deleting a skill without losing it.
///
/// Claude Code keeps a trash for skills at `~/.claude/skills/.trash/`: each
/// entry is a folder named `<epoch-ms>-<pid>-<random>` holding the skill's
/// folder, and its retention sweep removes entries 30 days after they were
/// moved there. ClaudeNotch moves a skill into an entry of the same shape, so
/// the same sweep cleans up after it, and writes a small `.claudenotch-origin`
/// file beside the skill saying where it came from, so Restore can put a
/// project skill back in its project rather than in your personal folder.
enum SkillTrash {
    static let retentionDays = 30
    static let originFile = ".claudenotch-origin"
    static var dir: String { (SkillsReader.personalDir as NSString).appendingPathComponent(".trash") }

    struct Entry: Identifiable, Equatable {
        var id: String { path }
        /// The trashed skill's folder.
        let path: String
        let name: String
        let trashedAt: Date?
        /// Where it lived before; nil means the personal skills folder.
        let origin: String?
        var daysLeft: Int? {
            guard let trashedAt else { return nil }
            return max(0, SkillTrash.retentionDays - Int(Date().timeIntervalSince(trashedAt) / 86_400))
        }
    }

    enum TrashError: Error, LocalizedError {
        case notASkillFolder, alreadyExists(String)
        var errorDescription: String? {
            switch self {
            case .notASkillFolder: return L("That folder is not a skill ClaudeNotch can move.", comment: "Error moving a skill to the trash")
            case .alreadyExists(let p): return String(format: L("A skill is already at %@, so it was not overwritten.", comment: "Error restoring a skill. %@ is a path"), p)
            }
        }
    }

    /// The trash entry folder name Claude Code uses: when it was trashed, which
    /// process did it, and a random tail so two moves never collide.
    nonisolated static func entryName(now: Date = Date(), pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        let tail = String((0..<6).map { _ in alphabet.randomElement()! })
        return "\(Int64(now.timeIntervalSince1970 * 1000))-\(pid)-\(tail)"
    }

    /// When an entry was trashed, from its folder name.
    nonisolated static func trashedAt(entryName: String) -> Date? {
        guard let ms = entryName.split(separator: "-").first.flatMap({ Double($0) }), ms > 1e12 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Move a personal or project skill folder into the trash.
    static func trash(_ skill: SkillInfo) throws {
        guard skill.canTrash, FileManager.default.fileExists(atPath: (skill.path as NSString).appendingPathComponent("SKILL.md")) else { throw TrashError.notASkillFolder }
        let entry = (dir as NSString).appendingPathComponent(entryName())
        try FileManager.default.createDirectory(atPath: entry, withIntermediateDirectories: true)
        let folder = (skill.path as NSString).lastPathComponent
        try FileManager.default.moveItem(atPath: skill.path, toPath: (entry as NSString).appendingPathComponent(folder))
        let parent = (skill.path as NSString).deletingLastPathComponent
        if parent != SkillsReader.personalDir {
            try? parent.write(toFile: (entry as NSString).appendingPathComponent(originFile), atomically: true, encoding: .utf8)
        }
    }

    /// Everything in the trash, newest first.
    static func list() -> [Entry] {
        let fm = FileManager.default
        var out: [Entry] = []
        for e in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !e.hasPrefix(".") {
            let entry = (dir as NSString).appendingPathComponent(e)
            let origin = try? String(contentsOfFile: (entry as NSString).appendingPathComponent(originFile), encoding: .utf8)
            for f in (try? fm.contentsOfDirectory(atPath: entry)) ?? [] where !f.hasPrefix(".") {
                out.append(Entry(path: (entry as NSString).appendingPathComponent(f), name: f, trashedAt: trashedAt(entryName: e),
                                 origin: origin?.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        return out.sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) }
    }

    /// Put a trashed skill back where it came from. Never overwrites a skill
    /// that has since appeared under the same name.
    static func restore(_ entry: Entry) throws {
        let parent = entry.origin ?? SkillsReader.personalDir
        let dest = (parent as NSString).appendingPathComponent(entry.name)
        guard !FileManager.default.fileExists(atPath: dest) else { throw TrashError.alreadyExists(dest) }
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: entry.path, toPath: dest)
        let entryDir = (entry.path as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: (entryDir as NSString).appendingPathComponent(originFile))
        if ((try? FileManager.default.contentsOfDirectory(atPath: entryDir)) ?? []).isEmpty { try? FileManager.default.removeItem(atPath: entryDir) }
    }
}
