import Foundation

// Parallel workspaces appearing and disappearing under a session.
//
// Worktrees are how people run several agents at once without them colliding
// on the same files, and `claude --worktree` made it a first-class workflow.
// The cost is the one every account of it mentions: more directories, more
// panes, and no clear sense of which session is in which. Sessions already
// carry the worktree they are in; what was missing is the moment one is
// created or thrown away.
//
// The two payloads are not symmetric, which is worth stating because it is
// surprising and it is verified rather than assumed. `WorktreeCreate` carries
// `name`. `WorktreeRemove` carries `worktree_path`. Neither carries a method.
//
// Pure and nonisolated: payload text on its way to a card.
enum Worktree {

    /// Longest label kept. Payload-supplied, so bounded rather than trusted.
    static let labelLimit = 60

    /// A worktree name or path reduced to something displayable.
    ///
    /// A path is shown as its last component, since the parent is usually a
    /// long shared prefix that says nothing about which worktree this is.
    nonisolated static func label(name: String = "", path: String = "") -> String {
        let raw = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? name
            : (path as NSString).lastPathComponent

        let cleaned = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        return cleaned.count <= labelLimit
            ? cleaned
            : String(cleaned.prefix(labelLimit - 1)) + "\u{2026}"
    }

    // MARK: - What it says

    nonisolated static func createdTitle(label: String) -> String {
        guard !label.isEmpty else {
            return L("A new worktree was created",
                     comment: "Card title when a git worktree is created and its name is unknown")
        }
        return String(format: L("New worktree: %@",
                                comment: "Card title when a git worktree is created. %@ is its name"),
                      label)
    }

    nonisolated static func createdDetail() -> String {
        L("A session working here is isolated from your other checkouts by file, but not by port, database, or environment.",
          comment: "Card body explaining what a worktree does and does not isolate")
    }

    nonisolated static func removedTitle(label: String) -> String {
        guard !label.isEmpty else {
            return L("A worktree was removed",
                     comment: "Card title when a git worktree is removed and its name is unknown")
        }
        return String(format: L("Worktree removed: %@",
                                comment: "Card title when a git worktree is removed. %@ is its name"),
                      label)
    }
}
