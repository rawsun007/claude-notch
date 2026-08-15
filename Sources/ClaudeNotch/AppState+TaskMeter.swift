import Foundation
import AppKit

// The task progress meter: todo parsing and per-session progress.

extension AppState {
    /// A task was completed (TaskCompleted hook, or TaskUpdate status=completed).
    func noteTaskCompleted(id: String, sessionId: String = "") {
        guard !id.isEmpty else { return }
        upsertSession(id: sessionId, cwd: currentCwd, create: true) { s in
            // A completion can arrive for a task we never saw created (e.g. the
            // TaskCreated hook was missed) — count it on both sides so the meter
            // never shows more done than total.
            s.createdTaskIds.insert(id)
            s.completedTaskIds.insert(id)
        }
        lastHookAt = Date()
        ensureStaleTimer()
    }

    /// The TodoWrite checklist changed. Store the whole snapshot (total items,
    /// completed items) on the session; this is what most sessions use, so it
    /// drives the notch task meter.
    func noteTodos(total: Int, done: Int, sessionId: String = "") {
        upsertSession(id: sessionId, cwd: currentCwd, create: true) { s in
            s.todoTotal = max(0, total)
            s.todoDone = min(max(0, done), max(0, total))
        }
        lastHookAt = Date()
        ensureStaleTimer()
    }

    /// A task was abandoned (TaskUpdate status=deleted). Drop it from both sets
    /// so a cancelled task doesn't inflate the denominator.
    func noteTaskDeleted(id: String, sessionId: String = "") {
        guard !id.isEmpty else { return }
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.createdTaskIds.remove(id)
            s.completedTaskIds.remove(id)
        }
    }

    /// A turn finished for a session — settle it to a steady state (so its dot
    /// stops pulsing) without disturbing the other live sessions.
    func markSessionDone(cwd: String = "", sessionId: String = "") {
        guard !sessionId.isEmpty || !cwd.isEmpty || !currentCwd.isEmpty else { return }
        let resolvedCwd = cwd.isEmpty ? currentCwd : cwd
        upsertSession(id: sessionId, cwd: resolvedCwd) { s in
            s.status = s.lastResponse.isEmpty ? "done" : "last reply"
        }
        petCelebrate()
        let key = TurnGate.key(sessionId: sessionId, cwd: resolvedCwd)
        // The turn is over: ignore hooks that were already in flight for it.
        turnGate.turnEnded(key)
        if let s = sessions[key] { archiveSession(s) }
    }

    /// SessionStart hook: the session just opened. Sets the model id straight
    /// from the payload — the only pre-transcript source — so the notch shows
    /// the right model from the first second instead of waiting for the first
    /// transcript read or status line. Also captures the session title.
    func noteSessionStart(sessionId: String, cwd: String,
                          model: String, title: String, source: String) {
        upsertSession(id: sessionId, cwd: cwd) { s in
            if !model.isEmpty { s.model = model }
            if !title.isEmpty { s.title = title }
            // How the session began. Only SessionStart carries this, and it
            // fires once, so a later hook must never blank it.
            if !source.isEmpty { s.startSource = source }
        }
        let isCurrent = currentSessionId.isEmpty || sessionId == currentSessionId
        if isCurrent, !model.isEmpty { currentModel = model }
    }

    /// A file was edited/written by Claude (PostToolUse for Edit / Write /
    /// MultiEdit / NotebookEdit). Kept unique and ordered, newest last.
    func noteFileTouched(_ path: String, sessionId: String, cwd: String) {
        guard !path.isEmpty else { return }
        upsertSession(id: sessionId, cwd: cwd) { s in
            if let i = s.touchedFiles.firstIndex(of: path) {
                s.touchedFiles.remove(at: i)      // re-touch moves to the end
            }
            s.touchedFiles.append(path)
            if s.touchedFiles.count > 50 { s.touchedFiles.removeFirst() }
            s.turnFilesEdited += 1
        }
    }

    /// A shell command ran this turn, whatever it was.
    func noteCommandRun(sessionId: String, cwd: String) {
        upsertSession(id: sessionId, cwd: cwd) { s in s.turnRanCommand = true }
    }

    /// A test command ran. The outcome is recorded only when the tool reported
    /// an explicit failure; everything else leaves `turnTestFailed` nil, which
    /// CompletionAudit reads as "unknown" and stays quiet about.
    func noteTestRun(failed: Bool?, sessionId: String, cwd: String) {
        upsertSession(id: sessionId, cwd: cwd) { s in
            s.turnRanTests = true
            if let failed { s.turnTestFailed = failed }
        }
    }

    /// The audit's view of the turn that just ended.
    func completionEvidence(sessionId: String, cwd: String) -> CompletionAudit.Evidence {
        let s = sessions[sessionId] ?? sessions.values.first { $0.cwd == cwd && !cwd.isEmpty }
        return CompletionAudit.Evidence(
            claim: s?.fullResponse ?? fullClaudeResponse,
            filesEdited: s?.turnFilesEdited ?? 0,
            ranCommands: s?.turnRanCommand ?? false,
            testCommandRan: s?.turnRanTests ?? false,
            testFailed: s?.turnTestFailed
        )
    }

    /// The session the header is showing, plus any sibling in the same folder,
    /// newest first. A long session that compacts or resumes gets a NEW id and a
    /// fresh, empty entry: its cost and context survive (they are read from the
    /// transcript) but its touched-files and branch, which live in memory per id,
    /// start blank — so the notch would suddenly show no files and no branch
    /// halfway through real work. Falling back to a sibling in the same cwd that
    /// still has them restores that detail across the id change.
    private var currentAndSiblings: [LiveSession] {
        let current = currentSessionId.isEmpty ? nil : sessions[currentSessionId]
        let cwd = current?.cwd
            ?? sessions.values.max(by: { $0.lastHookAt < $1.lastHookAt })?.cwd
        guard let cwd, !cwd.isEmpty else { return current.map { [$0] } ?? [] }
        let inFolder = sessions.values.filter { $0.cwd == cwd }
            .sorted { $0.lastHookAt > $1.lastHookAt }
        // Current first (it is the one being shown), then its folder-mates.
        if let current { return [current] + inFolder.filter { $0.id != current.id } }
        return inFolder
    }

    /// Files touched by the session the notch header is currently showing, or the
    /// most recent sibling in its folder that has any.
    var currentTouchedFiles: [String] {
        for s in currentAndSiblings where !s.touchedFiles.isEmpty { return s.touchedFiles }
        return []
    }

    /// Git branch of the session the notch header is showing, or a sibling's.
    var currentGitBranch: String {
        for s in currentAndSiblings where !s.gitBranch.isEmpty { return s.gitBranch }
        return ""
    }

    /// Record the permission mode carried on every hook payload. Cheap no-op
    /// when unchanged; drives the BYPASS / PLAN / AUTO badge in the notch.
    func notePermissionMode(_ mode: String, sessionId: String, cwd: String) {
        guard !mode.isEmpty else { return }
        upsertSession(id: sessionId, cwd: cwd) { s in
            if s.permissionMode != mode { s.permissionMode = mode }
        }
        let isCurrent = currentSessionId.isEmpty || sessionId == currentSessionId
        if isCurrent, currentPermissionMode != mode { currentPermissionMode = mode }
    }

    /// A turn died from an API-level failure (StopFailure hook: rate limit,
    /// overloaded, billing…). Shows a blocking alert card + native banner so a
    /// long task never dies silently while the user is away.
    func noteStopFailure(reason: String = "", title: String, detail: String,
                         cwd: String, sessionId: String) {
        // A turn that dies while the session is compacting is not a session
        // dying. The context filled up, Claude Code is summarising it, and it
        // will carry on by itself — the terminal says exactly that. Reporting
        // the API's "invalid_request" over the top of it is alarming, wrong
        // about what is happening, and something the user can do nothing with.
        let compacting = isCompacting(sessionId: sessionId, cwd: cwd)
        if compacting {
            let req = PermissionRequest(
                kind: .notification,
                title: L("Compacting the conversation",
                         comment: "Card title shown when a turn pauses because the context filled up and is being summarised"),
                detail: L("The context filled up. Claude Code is summarising it and will pick up where it left off.",
                          comment: "Card body explaining that compaction is under way and needs nothing from the user"),
                toolName: "Compacting",
                source: "Claude Code",
                cwd: cwd,
                originatorBundleID: nil,
                resolver: { _, _ in }
            )
            enqueuePermission(req)
            return
        }

        markSessionDone(cwd: cwd, sessionId: sessionId)
        petStartle()
        upsertSession(id: sessionId, cwd: cwd) { s in
            s.status = "error"
        }
        let req = PermissionRequest(
            kind: .notification,
            title: "⚠️ \(title)",
            detail: detail,
            toolName: "StopFailure",
            source: "Claude Code",
            cwd: cwd,
            originatorBundleID: nil,
            resolver: { _, _ in }
        )
        enqueuePermission(req)
        if mirrorToNotificationCenter, !AppState.appIsActive {
            let project = (cwd as NSString).lastPathComponent
            permissionMirror?.sendCompletion(
                project: project.isEmpty ? title : "\(project), \(title)",
                snippet: detail.isEmpty ? title : detail,
                agentName: completionEntityName(sessionId: sessionId, cwd: cwd),
                cwd: "", originatorBundleID: nil)   // failures aren't replyable
        }
    }

    /// Manually wipe the live session info — useful when you closed the
    /// terminal and want the notch to forget what was running there.
    func clearSession() {
        currentProject = ""
        currentCwd = ""
        lastActivity = ""
        activityStartedAt = nil
        lastUserPrompt = ""
        lastClaudeResponse = ""
        claudeActionStatus = "ready"
        lastHookAt = nil
        sessions.removeAll()
        turnGate.reset()
    }

    func noteClaudeResponse(_ text: String, sessionId: String = "") {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let snippet = Self.statusSnippet(from: trimmed)
        // Attribute to the session even if the global mirror already holds this
        // text (e.g. two sessions emitting the same reply).
        if !sessionId.isEmpty || !currentCwd.isEmpty {
            upsertSession(id: sessionId, cwd: currentCwd) { s in
                s.lastResponse = snippet
                s.fullResponse = String(trimmed.prefix(8000))
                if !Self.terminalSessionStatuses.contains(s.status) {
                    s.status = "replying"
                }
            }
        }

        // Only the current session writes the global mirror. Without this gate,
        // two sessions polling their transcripts (one possibly just-closed but
        // still winding down) overwrite lastClaudeResponse on alternating ticks,
        // and the collapsed header flickers between their replies every second.
        // Gate on session identity, not sessions.count: a closed session can be
        // gone from the dict (count == 1) while its poll loop is still pushing.
        // currentSessionId == "" means legacy/no per-session tracking → allow.
        let isCurrent = currentSessionId.isEmpty || sessionId == currentSessionId
        guard isCurrent else { return }

        guard trimmed != fullClaudeResponse else { return }
        fullClaudeResponse = String(trimmed.prefix(8000))
        lastClaudeResponse = snippet
        if completedQueue.isEmpty {
            claudeActionStatus = "replying"
        }
        lastClaudeResponseAt = Date()
        lastHookAt = Date()
    }

    var idleTitle: String {
        "\(entityName) · \(claudeActionStatus)"
    }

    /// True while Claude is mid-task — drives the pulsing status dot. Idle,
    /// finished, and "last reply" states are steady (not pulsing).
    var isClaudeWorking: Bool { Self.isWorking(status: claudeActionStatus) }

    /// Shared definition of "mid-task" so the global dot and per-session rows
    /// agree. Idle, finished, and "last reply" states are steady.
    static func isWorking(status: String) -> Bool {
        switch status {
        case "ready", "done", "last reply": return false
        default: return true
        }
    }

    // MARK: - Live sessions

    /// Sessions that have fired a hook recently enough to still be considered
    /// alive. Filters out anything past the project-stale window.
    ///
    /// Ordered by `createdAt` (oldest first), NOT `lastHookAt`: liveness is
    /// gauged by lastHookAt but that field updates on every hook, so sorting by
    /// it made the rows swap position every second whenever more than one
    /// session was active. createdAt is fixed for a session's lifetime, so the
    /// rows stay put and a new session simply appears at the bottom. The `id`
    /// tiebreaker keeps the order deterministic if two sessions share a tick.
    var activeSessions: [LiveSession] {
        let cutoff = Date().addingTimeInterval(-projectStaleAfter)
        let live = sessions.values.filter { $0.lastHookAt > cutoff }

        // Collapse phantom rows for the same folder. One physical Claude session
        // can leave more than one entry behind: a hook that arrives before the
        // session_id is known keys a fallback by the cwd (its id is the path), and
        // a session that got a new id (after /clear, a compact, a resume) lingers
        // under the old one until it ages out. Both show as a bare row — no
        // session name, no cost/context meter — beside the real one, same project
        // and same branch.
        //
        // So within a folder, a bare session is treated as a duplicate of a richer
        // one: if any session in a cwd has a name or a live meter, the nameless,
        // meterless siblings for that same cwd are dropped. The current session is
        // always kept, and two sessions that are both real (each with its own name
        // or meter) both stay, because those are genuinely two sessions.
        func isRich(_ s: LiveSession) -> Bool { !s.title.isEmpty || s.hasMeter }
        // Folders that have a real, id-keyed session, and folders that have a rich
        // one (a name or a live meter).
        let idKeyedCwds = Set(live.filter { !$0.id.hasPrefix("/") }.map(\.cwd))
        let richCwds = Set(live.filter(isRich).map(\.cwd))
        let deduped = live.filter { session in
            if session.id == currentSessionId { return true }   // never hide the one in front of you
            // A path-keyed placeholder is a pre-id fallback: drop it the moment any
            // real id-keyed session shares its folder, rich or not.
            if session.id.hasPrefix("/") { return !idKeyedCwds.contains(session.cwd) }
            // A bare id-keyed session (no name, no meter) is a phantom left by an
            // id that changed under one physical session: drop it when a richer
            // session covers the same folder. A rich session always stands.
            if isRich(session) { return true }
            return !richCwds.contains(session.cwd)
        }
        return deduped.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
}
