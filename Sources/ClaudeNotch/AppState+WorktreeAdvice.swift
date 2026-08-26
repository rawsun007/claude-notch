import Foundation

// MARK: - Two sessions in one checkout

extension AppState {

    /// Say once, per directory, when more than one live session is working in it.
    func adviseWorktreeIfNeeded() {
        guard compactAdviceEnabled else { return }
        let live = sessions.values.map { (cwd: $0.cwd, worktree: $0.worktree) }
        for dir in WorktreeAdvice.collidingDirectories(live) {
            guard !worktreeAdviceGiven.contains(dir) else { continue }
            if worktreeAdviceGiven.count >= AppState.worktreeAdviceCap { worktreeAdviceGiven.removeAll() }
            worktreeAdviceGiven.insert(dir)
            enqueuePermission(PermissionRequest(
                kind: .notification,
                title: WorktreeAdvice.cardTitle(project: (dir as NSString).lastPathComponent),
                detail: WorktreeAdvice.cardDetail(),
                toolName: "Worktree",
                source: "ClaudeNotch",
                cwd: dir,
                resolver: { _, _ in }))
        }
    }
}
