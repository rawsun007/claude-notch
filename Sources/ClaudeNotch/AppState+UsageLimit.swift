import Foundation
import AppKit

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

        // No appendHistory here: enqueuePermission writes the row for a
        // notification card itself, and two rows for one event is noise in the
        // drawer and in every export built from it.
        let title = UsageLimitPause.pausedTitle(autoContinues: auto)
        let detail = UsageLimitPause.pausedDetail(autoContinues: auto, resumesAt: resumesAt)
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
        // It woke up, so a later pause is allowed to warn again.
        stalledLimitReported.remove(key)

        let project = session.project
        let title = UsageLimitPause.resumedTitle(project: project)
        let detail = UsageLimitPause.resumedDetail(pausedFor: at.timeIntervalSince(pausedAt))

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

    /// Check whether any waiting session should have woken by now.
    ///
    /// The resume card is driven by evidence: a hook arriving for a session that
    /// was paused. That works, except in the one case where nothing arrives,
    /// which is exactly the case where the user needs to go back to the Mac.
    /// Nothing was watching for it, because nothing happening is not an event.
    func checkForStalledUsageLimits(now: Date = Date()) {
        for session in sessionsWaitingOnUsageLimit {
            guard UsageLimitPause.looksStalled(resumesAt: session.limitResumesAt, now: now) else { continue }
            guard !stalledLimitReported.contains(session.id) else { continue }
            stalledLimitReported.insert(session.id)

            let since = now.timeIntervalSince(session.limitResumesAt ?? now)
            enqueuePermission(PermissionRequest(
                kind: .notification,
                title: UsageLimitPause.stalledTitle(project: session.project),
                detail: UsageLimitPause.stalledDetail(since: since),
                toolName: "UsageLimit",
                source: "Claude Code",
                cwd: session.cwd,
                resolver: { _, _ in }))

            // This one is worth a notification: it is the only state in the
            // whole pause flow that needs the user back at the machine.
            if completionNotificationsEnabled, !AppState.appIsActive {
                permissionMirror?.sendCompletion(
                    project: session.project,
                    snippet: UsageLimitPause.stalledDetail(since: since),
                    agentName: entityName, cwd: session.cwd,
                    originatorBundleID: session.originatorBundleID)
            }
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

// MARK: - Compaction advice

extension AppState {

    /// Say something when a session's context crosses a line worth crossing
    /// deliberately. See CompactAdvice for the thresholds and the reasoning.
    func adviseCompactionIfNeeded(sessionId: String, cwd: String = "") {
        guard compactAdviceEnabled else { return }
        let key = sessionKey(sessionId: sessionId, cwd: cwd)
        guard let session = sessions[key] else { return }
        guard CompactAdvice.worthAdvising(hasMeter: session.hasMeter,
                                          isWorking: Self.isWorking(status: session.status),
                                          isCompacting: session.isCompacting) else { return }

        let said = CompactAdvice.Urgency(rawValueString: session.compactAdviceGiven)
        let urgency = CompactAdvice.urgency(percent: session.contextPercent, alreadySaid: said)
        guard urgency != .none else { return }

        upsertSession(id: sessionId, cwd: cwd) { $0.compactAdviceGiven = urgency.stringValue }

        // Allow on this card means "do it now": the card is advice, and advice
        // you have to go and act on somewhere else is advice most people skip.
        let cwd = session.cwd
        let originator = session.originatorBundleID
        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: CompactAdvice.title(urgency, percent: session.contextPercent),
            detail: CompactAdvice.detail(urgency),
            toolName: "Compact",
            source: "ClaudeNotch",
            cwd: cwd,
            resolver: { [weak self] decision, _ in
                guard decision == .allow else { return }
                self?.runCompact(forSessionCwd: cwd, originatorBundleID: originator)
            }))
    }
}

extension CompactAdvice.Urgency {
    /// Stored on the session as a string, because LiveSession stays a plain
    /// value type that anything can read without importing this rule.
    var stringValue: String {
        switch self {
        case .none: return ""
        case .suggested: return "suggested"
        case .urgent: return "urgent"
        }
    }

    init(rawValueString: String) {
        switch rawValueString {
        case "suggested": self = .suggested
        case "urgent": self = .urgent
        default: self = .none
        }
    }
}

// MARK: - Running /compact for the user

extension AppState {

    /// Type `/compact` into the session the advice was about.
    ///
    /// The advice is only advice until acting on it is cheaper than ignoring
    /// it. Ignoring it costs nothing; acting on it meant finding the terminal,
    /// which is the same context switch this whole app exists to remove.
    ///
    /// Typed rather than sent over the hook socket, because compaction is a
    /// slash command in the session's own prompt and there is no hook that
    /// starts one. That means Accessibility, and when it is missing the honest
    /// move is to say so rather than appear to do nothing.
    func runCompact(forSessionCwd cwd: String, originatorBundleID: String?) {
        guard let bid = originatorBundleID, !bid.isEmpty,
              !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty
        else {
            compactActionError = L("That session's terminal is not open any more.",
                                   comment: "Error when the app cannot find the terminal to type /compact into")
            return
        }
        guard TerminalAutomator.isAccessibilityTrusted else {
            promptAccessibility()
            compactActionError = L("ClaudeNotch needs Accessibility to type into your terminal. I opened System Settings; enable it there and try again.",
                                   comment: "Error when Accessibility is missing and the app cannot type /compact")
            return
        }
        TerminalAutomator.sendText("/compact", toBundleID: bid)
        play(.messageSent)
        compactActionError = nil
    }
}

// MARK: - Whether a project tells its agent anything

extension AppState {

    /// Say once, per project, whether this project has a CLAUDE.md worth having.
    ///
    /// Keyed on the directory rather than the session: the answer is a property
    /// of the project, and hearing it again for every session opened in the
    /// same repo is how a fair point becomes nagging.
    func adviseProjectInstructionsIfNeeded(sessionId: String, cwd: String = "") {
        guard compactAdviceEnabled else { return }   // same "should the app nudge" switch
        let key = sessionKey(sessionId: sessionId, cwd: cwd)
        guard let session = sessions[key], !session.cwd.isEmpty else { return }
        guard !instructionAdviceGiven.contains(session.cwd) else { return }

        let status = ProjectInstructions.status(cwd: session.cwd)
        guard ProjectInstructions.worthAdvising(status, toolCalls: session.toolCallCount) else { return }
        instructionAdviceGiven.insert(session.cwd)

        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: ProjectInstructions.title(status),
            detail: ProjectInstructions.detail(status),
            toolName: "Instructions",
            source: "ClaudeNotch",
            cwd: session.cwd,
            resolver: { _, _ in }))
    }
}

extension AppState {
    /// Run the check for every live session, off the heartbeat.
    func adviseProjectInstructionsForLiveSessions() {
        for session in Array(sessions.values) {
            adviseProjectInstructionsIfNeeded(sessionId: session.id, cwd: session.cwd)
        }
    }
}
