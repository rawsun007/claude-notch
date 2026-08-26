import Foundation

// MARK: - What ran without anyone being asked

extension AppState {

    /// Say once, per session, how much has run unprompted.
    ///
    /// Runs off the end of a turn rather than per tool call: the number is only
    /// meaningful as a summary, and counting it up in front of somebody one
    /// action at a time is the opposite of the point.
    func reviewAutoModeIfNeeded(sessionId: String, cwd: String = "") {
        guard compactAdviceEnabled else { return }
        let key = sessionKey(sessionId: sessionId, cwd: cwd.isEmpty ? currentCwd : cwd)
        guard let session = sessions[key] else { return }
        guard AutoModeReview.worthReviewing(mode: session.permissionMode,
                                            toolCalls: session.toolCallCount,
                                            alreadySaid: session.autoModeReviewed)
        else { return }

        upsertSession(id: sessionId, cwd: session.cwd) { $0.autoModeReviewed = true }
        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: AutoModeReview.cardTitle(actions: session.toolCallCount,
                                            project: (session.cwd as NSString).lastPathComponent),
            detail: AutoModeReview.cardDetail(),
            toolName: "AutoMode",
            source: "ClaudeNotch",
            cwd: session.cwd,
            resolver: { _, _ in }))
    }
}
