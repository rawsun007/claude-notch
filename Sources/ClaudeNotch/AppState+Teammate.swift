import Foundation

// MARK: - A named teammate has gone idle

extension AppState {

    /// Put a waiting teammate on screen.
    ///
    /// No enable switch and no once-per-teammate guard, unlike the advice
    /// cards. A teammate going idle is the same event as a session finishing,
    /// which this app has always shown unconditionally, and it is news every
    /// time rather than a fact about the project that gets stale. The queue cap
    /// is what bounds it if a team is large or noisy.
    func noteTeammateIdle(name rawName: String, sessionId: String, cwd: String = "") {
        let name = Teammate.displayName(rawName)
        let key = sessionKey(sessionId: sessionId, cwd: cwd.isEmpty ? currentCwd : cwd)
        let where_ = sessions[key]?.cwd ?? cwd
        let project = where_.isEmpty ? "" : (where_ as NSString).lastPathComponent

        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: Teammate.cardTitle(name: name),
            detail: Teammate.cardDetail(project: project),
            toolName: "Teammate",
            source: "ClaudeNotch",
            cwd: where_,
            resolver: { _, _ in }))
    }
}
