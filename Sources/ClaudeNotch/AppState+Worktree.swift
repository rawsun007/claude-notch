import Foundation

// MARK: - Worktrees appearing and disappearing

extension AppState {

    func noteWorktreeCreated(name: String, sessionId: String, cwd: String = "") {
        let label = Worktree.label(name: name)
        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: Worktree.createdTitle(label: label),
            detail: Worktree.createdDetail(),
            toolName: "Worktree",
            source: "ClaudeNotch",
            cwd: cwd.isEmpty ? currentCwd : cwd,
            resolver: { _, _ in }))
    }

    /// Removal is logged rather than carded.
    ///
    /// A worktree going away is not something anybody needs to act on, and it
    /// usually happens right after the work in it was merged, which is the
    /// least welcome moment for an interruption. It still belongs in history,
    /// because "where did that checkout go" is a question people ask later.
    func noteWorktreeRemoved(path: String, sessionId: String, cwd: String = "") {
        let label = Worktree.label(path: path)
        appendHistory(HistoryEntry(
            timestamp: Date(),
            kind: .notification,
            toolName: "Worktree",
            title: Worktree.removedTitle(label: label),
            detail: path,
            project: ((cwd.isEmpty ? currentCwd : cwd) as NSString).lastPathComponent,
            outcome: .info))
    }
}
