import Foundation

// Two agents working in the same directory at the same time.
//
// Running several sessions at once is the single most recommended way to get
// more out of these tools, and the way it goes wrong is specific: two sessions
// in the *same* checkout edit the same files underneath each other. One reads a
// file, the other rewrites it, and the first carries on reasoning about what it
// read. Nothing errors. The work just quietly disagrees with itself.
//
// Worktrees are the standard answer, and `claude --worktree` makes one per
// session. The notch is well placed to notice the collision because it already
// knows every live session's directory and which worktree, if any, it is in.
//
// The card says the honest limit too. A worktree isolates files. It does not
// isolate ports, databases, or environment, and finding that out by running two
// dev servers on one port is how people learn to distrust the advice.
//
// Pure and nonisolated: grouping directories, and worth pinning in tests.
enum WorktreeAdvice {

    /// Directories with more than one live session in them.
    ///
    /// Sessions already in a linked worktree are excluded: that is the thing
    /// being recommended, and telling somebody who took the advice to take it
    /// again is how a fair point becomes noise. Blank directories are excluded
    /// too, since "unknown" is not a collision.
    nonisolated static func collidingDirectories(_ sessions: [(cwd: String, worktree: String)]) -> [String] {
        var counts: [String: Int] = [:]
        for s in sessions {
            let cwd = s.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cwd.isEmpty else { continue }
            guard s.worktree.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            counts[cwd, default: 0] += 1
        }
        return counts.filter { $0.value > 1 }.keys.sorted()
    }

    // MARK: - What it says

    nonisolated static func cardTitle(project: String) -> String {
        String(format: L("Two sessions are working in %@ at once",
                         comment: "Card title when several live sessions share one directory. %@ is a folder name"),
               project)
    }

    nonisolated static func cardDetail() -> String {
        L("They will edit the same files underneath each other, and neither will report an error when it happens. `claude --worktree` gives a session its own checkout. It separates files, though not ports, databases, or environment.",
          comment: "Card body explaining why two sessions in one directory collide, and what a worktree does and does not separate")
    }
}
