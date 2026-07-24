import Foundation

/// Reading git state without shelling out. Centralised so the several places
/// that need "what branch is this dir on" share one correct reader instead of
/// each parsing .git/HEAD slightly differently (one handled worktrees and
/// detached HEADs but not nested dirs; the other walked up but handled neither).
enum Git {
    /// The checked-out branch for `cwd`, read straight from `.git/HEAD`. Walks
    /// up to the repo root, follows a worktree/submodule ".git" file to its real
    /// gitdir, and returns a short hash for a detached HEAD. Empty when `cwd`
    /// isn't inside a repo.
    static func branch(forCwd cwd: String) -> String {
        guard !cwd.isEmpty else { return "" }
        var dir = cwd
        for _ in 0..<64 {
            if let b = branch(atRepoParent: dir) { return b }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        return ""
    }

    /// Branch from the ".git" entry directly inside `dir`. Nil when there is no
    /// ".git" here (so the caller keeps walking up); empty string when a repo is
    /// here but its HEAD can't be resolved to a branch (so the walk stops).
    private static func branch(atRepoParent dir: String) -> String? {
        let gitPath = (dir as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) else { return nil }

        var gitDir = gitPath
        if !isDir.boolValue {
            // Worktree/submodule: ".git" is a file — "gitdir: /path/to/gitdir".
            guard let content = try? String(contentsOfFile: gitPath, encoding: .utf8),
                  let path = content.split(separator: "\n").first?
                      .replacingOccurrences(of: "gitdir:", with: "")
                      .trimmingCharacters(in: .whitespaces), !path.isEmpty else { return "" }
            gitDir = path.hasPrefix("/") ? path : (dir as NSString).appendingPathComponent(path)
        }

        let headPath = (gitDir as NSString).appendingPathComponent("HEAD")
        guard let head = try? String(contentsOfFile: headPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return "" }
        let prefix = "ref: refs/heads/"
        if head.hasPrefix(prefix) { return String(head.dropFirst(prefix.count)) }
        // Detached HEAD: a short hash beats showing nothing.
        return head.count >= 7 ? String(head.prefix(7)) : head
    }
}
