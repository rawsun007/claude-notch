import Foundation

// Pausing on a usage limit, and coming back from one.
//
// See UsageLimitPause for the rules. This is the part that holds the state and
// puts the cards up.
extension AppState {

    /// A turn died because the account is out of usage.
    ///
    /// Not an error card. Claude Code waits for the reset and continues on its
    /// own now, so the honest description is a pause with a time on it, and the
    /// user's job is to go and do something else.
    func notePausedByUsageLimit(sessionId: String = "", cwd: String = "") {
        let dir = cwd.isEmpty ? currentCwd : cwd
        let auto = UsageLimitPause.autoContinues(settingsPaths: UsageLimitPause.defaultSettingsPaths)
        // Whichever window is actually binding. The five-hour one is what a
        // mid-task stop nearly always hits; the weekly one only matters when it
        // is the later of the two.
        let resumesAt = [fiveHourResetAt, weeklyResetAt]
            .compactMap { $0 }
            .filter { $0 > Date() }
            .min()

        upsertSession(id: sessionId, cwd: dir) { s in
            s.limitPausedAt = Date()
            s.limitResumesAt = resumesAt
        }

        let title = UsageLimitPause.pausedTitle(autoContinues: auto)
        let detail = UsageLimitPause.pausedDetail(autoContinues: auto, resumesAt: resumesAt)
        appendHistory(HistoryEntry(
            timestamp: Date(),
            kind: .notification,
            toolName: "UsageLimit",
            title: title,
            detail: detail,
            project: (dir as NSString).lastPathComponent,
            outcome: .info))

        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: title,
            detail: detail,
            toolName: "UsageLimit",
            source: "Claude Code",
            cwd: dir,
            resolver: { _, _ in }))
    }

    /// Something happened in a session that was waiting on a usage limit.
    ///
    /// Called from the hook path on any sign of life. The card, and the native
    /// notification behind it, are the whole point of the feature: by the time
    /// a limit lifts the user is somewhere else, and nothing on the machine
    /// would otherwise tell them the work started again.
    func noteUsageLimitMaybeResumed(sessionId: String = "", cwd: String = "", at: Date = Date()) {
        let key = sessionKey(sessionId: sessionId, cwd: cwd)
        guard let session = sessions[key], let pausedAt = session.limitPausedAt else { return }
        guard UsageLimitPause.isRestart(pausedAt: pausedAt, eventAt: at) else { return }

        upsertSession(id: sessionId, cwd: cwd.isEmpty ? currentCwd : cwd) { s in
            s.limitPausedAt = nil
            s.limitResumesAt = nil
        }

        let project = session.project
        let title = UsageLimitPause.resumedTitle(project: project)
        let detail = UsageLimitPause.resumedDetail(pausedFor: at.timeIntervalSince(pausedAt))

        appendHistory(HistoryEntry(
            timestamp: Date(),
            kind: .notification,
            toolName: "UsageLimit",
            title: title,
            detail: detail,
            project: project,
            outcome: .info))

        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: title,
            detail: detail,
            toolName: "UsageLimit",
            source: "Claude Code",
            cwd: session.cwd,
            resolver: { _, _ in }))

        // The user is not at the Mac. That is the premise of the whole feature,
        // so this one goes to Notification Center whether or not the app is
        // frontmost, the same way a finished task does.
        if completionNotificationsEnabled, !AppState.appIsActive {
            permissionMirror?.sendCompletion(project: project, snippet: detail,
                                             agentName: entityName,
                                             cwd: session.cwd,
                                             originatorBundleID: session.originatorBundleID)
        }
    }

    /// Sessions currently waiting out a limit, newest pause first. Drives the
    /// row in the notch.
    var sessionsWaitingOnUsageLimit: [LiveSession] {
        sessions.values
            .filter { $0.limitPausedAt != nil }
            .sorted { ($0.limitPausedAt ?? .distantPast) > ($1.limitPausedAt ?? .distantPast) }
    }

    /// The key a session is filed under: its id, or its directory when a hook
    /// carried no id.
    func sessionKey(sessionId: String, cwd: String) -> String {
        if !sessionId.isEmpty { return sessionId }
        let dir = cwd.isEmpty ? currentCwd : cwd
        return Self.normalizedCwd(dir)
    }
}
