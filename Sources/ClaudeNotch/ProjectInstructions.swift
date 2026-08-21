import Foundation

// Whether a project tells its agent anything, and whether what it says is still
// true.
//
// Every guide written about getting good work out of Claude Code says the same
// thing first: write a CLAUDE.md. It is the highest-leverage file in the
// project, because it is the only context the agent carries into every task
// without being asked. The two ways it goes wrong are both quiet. There is not
// one, and nobody notices because the agent still answers. Or there is one, it
// has not been touched in months, and it is now describing a codebase that has
// moved, which is worse than nothing: the agent is being confidently misled.
//
// The notch is well placed to say so, because it already knows which project a
// session is in and, since InstructionsLoaded, which files that session loaded.
//
// Pure: this is a filesystem question, and it is answered here so the rules can
// be tested without a project on disk.
enum ProjectInstructions {

    /// The names Claude Code reads, in the order it prefers them.
    static let fileNames = ["CLAUDE.md", "CLAUDE.local.md", "AGENTS.md"]

    /// Old enough that it is probably describing a codebase that has moved.
    ///
    /// Sixty days is deliberately generous. A stable project can have a correct
    /// CLAUDE.md that nobody touches for a month, and being nagged about a file
    /// that is right is exactly how this ends up switched off.
    static let staleAfter: TimeInterval = 60 * 24 * 3600

    enum Status: Equatable {
        /// The project has one and it has been touched recently enough.
        case current(path: String)
        /// It has one, and it is old.
        case stale(path: String, age: TimeInterval)
        /// It has none.
        case missing
        /// Not a project directory we can answer for.
        case unknown
    }

    nonisolated static func status(cwd: String, now: Date = Date(),
                                   fileManager: FileManager = .default) -> Status {
        let dir = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty, dir != "/" else { return .unknown }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return .unknown
        }

        for name in fileNames {
            let path = (dir as NSString).appendingPathComponent(name)
            guard fileManager.fileExists(atPath: path) else { continue }
            let modified = (try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
            guard let modified else { return .current(path: path) }
            let age = now.timeIntervalSince(modified)
            // A file with a future timestamp is a clock problem, not a stale
            // file, and treating it as ancient would be wrong in the loud
            // direction.
            return age > staleAfter ? .stale(path: path, age: age) : .current(path: path)
        }
        return .missing
    }

    /// Whether this is worth saying anything about.
    ///
    /// Only for a project the user is actually working in, and only once we
    /// have seen enough of the session to know it is real work rather than a
    /// one-line question in a scratch directory.
    static let toolCallsBeforeAdvising = 10

    nonisolated static func worthAdvising(_ status: Status, toolCalls: Int) -> Bool {
        guard toolCalls >= toolCallsBeforeAdvising else { return false }
        switch status {
        case .missing, .stale: return true
        case .current, .unknown: return false
        }
    }

    nonisolated static func title(_ status: Status) -> String {
        switch status {
        case .missing:
            return L("This project has no CLAUDE.md",
                     comment: "Card title when a project has no instruction file")
        case .stale:
            return L("This project's CLAUDE.md has not changed in a long time",
                     comment: "Card title when the instruction file is old")
        case .current, .unknown:
            return ""
        }
    }

    nonisolated static func detail(_ status: Status) -> String {
        switch status {
        case .missing:
            return L("It is the only context an agent carries into every task here without being asked: your conventions, the architecture, what not to touch. A short one is worth more than none.",
                     comment: "Card body when a project has no instruction file")
        case .stale(let path, let age):
            return String(format: L("Last changed %@ ago (%@). If the codebase has moved since, the agent is being told something that is no longer true, which is worse than being told nothing.",
                                    comment: "Card body when the instruction file is old. First %@ is a duration, second is a file name"),
                          HookHealth.duration(age), (path as NSString).lastPathComponent)
        case .current, .unknown:
            return ""
        }
    }
}
