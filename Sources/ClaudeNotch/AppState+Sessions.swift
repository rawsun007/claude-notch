import Foundation
import AppKit

// Live session lifecycle: staleness, removal, background agents, and returning focus.

extension AppState {
    var activeSessionCount: Int { activeSessions.count }

    var totalRunningAgentCount: Int {
        sessions.values.reduce(0) { $0 + $1.runningAgentCount }
    }

    var workingSessionCount: Int {
        activeSessions.filter { Self.isWorking(status: $0.status) }.count
    }

    /// Create-or-update the session entry for `id` (falling back to `cwd` when
    /// no session_id was supplied), then apply `mutate`. Stamps lastHookAt and
    /// bounds the dict so it can't grow without limit.
    ///
    /// `authoritativeCwd` must be true ONLY for the per-request metadata call,
    /// which carries this session's real cwd. The activity/prompt/response
    /// helpers fall back to the global `currentCwd`, which can belong to a
    /// *different* session — so they must NOT rewrite an existing entry's cwd,
    /// or two concurrent sessions cross-contaminate each other's project label.
    /// `create` must be true ONLY for the per-request metadata call. The
    /// activity/prompt/response helpers pass false so a stale transcript poll
    /// can't resurrect a session that already ended (SessionEnd removed it).
    func upsertSession(id rawId: String, cwd: String, authoritativeCwd: Bool = false, create: Bool = false, _ mutate: (inout LiveSession) -> Void) {
        var normCwd = cwd
        while normCwd.count > 1, normCwd.hasSuffix("/") { normCwd.removeLast() }
        let key = !rawId.isEmpty ? rawId : normCwd
        guard !key.isEmpty else { return }
        if sessions[key] == nil, !create { return }

        var session = sessions[key] ?? LiveSession(
            id: key,
            cwd: normCwd,
            project: (normCwd as NSString).lastPathComponent,
            status: "ready",
            activity: "",
            lastResponse: "",
            fullResponse: "",
            originatorBundleID: nil,
            lastHookAt: Date(),
            createdAt: Date()
        )
        if authoritativeCwd, !normCwd.isEmpty {
            session.cwd = normCwd
            session.project = (normCwd as NSString).lastPathComponent
        }
        mutate(&session)
        session.lastHookAt = Date()
        sessions[key] = session

        if sessions.count > sessionsMax {
            let drop = sessions.values
                .sorted { $0.lastHookAt < $1.lastHookAt }
                .prefix(sessions.count - sessionsMax)
                .map(\.id)
            for k in drop { sessions.removeValue(forKey: k) }
        }
    }

    static func statusSnippet(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let currentLine = lines.reversed().first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? text
        let compact = currentLine
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(compact.prefix(240))
    }

    static func statusLabel(fromActivity label: String) -> String {
        let tool = label.split(separator: ":", maxSplits: 1).first.map(String.init) ?? label
        switch tool {
        case "Bash":                  return "running Bash"
        case "Read":                  return "reading"
        case "Edit", "MultiEdit":     return "editing"
        case "Write", "NotebookEdit": return "writing"
        case "Grep", "Glob", "LS":    return "searching files"
        case "WebFetch":              return "fetching"
        case "WebSearch":             return "searching web"
        case "TodoWrite":             return "updating todos"
        case "Task", "TaskCreate":    return "delegating"
        case "TaskUpdate":            return "tracking task"
        case "TaskList", "TaskGet":   return "checking tasks"
        case "ExitPlanMode":          return "waiting approval"
        case "Skill":                 return "loading skill"
        default:
            let clean = tool.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? "working" : "using \(clean)"
        }
    }

    // Override noteActivity to stamp its own time so the IdlePill can pick
    // the most-recent signal.
    func setLastActivityTimestamp() {
        lastActivityAt = Date()
    }

    // MARK: - Compose (send message to Claude)

    /// Hotkey entry point. Doesn't barge in on an active permission /
    /// question prompt — those are time-sensitive and dismissing them
    /// would be worse than the hotkey appearing to do nothing.
    func summonCompose() {
        switch mode {
        case .permission, .question:
            playSound("Funk")
            return
        default:
            beginCompose()
        }
    }

    func refreshBackgroundAgents() {
        let agents = BackgroundAgentReader.read()
        guard agents != backgroundAgents else { return }
        backgroundAgents = agents

        // Stamp the sessions we already know about, so their rows can say what
        // they are and what they were asked to do.
        let byId = Dictionary(uniqueKeysWithValues: agents.map { ($0.sessionId, $0) })
        for (key, var session) in sessions {
            guard let agent = byId[session.id] ?? byId[key] else { continue }
            guard session.backgroundAgentId != agent.id else { continue }
            session.backgroundAgentId = agent.id
            session.backgroundIntent = agent.intent
            sessions[key] = session
        }
    }

    /// A background agent said it needs input, or that it finished.
    func noteAgentNotice(_ notice: AgentNotice, sessionId: String) {
        guard !sessionId.isEmpty else { return }
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.agentNeedsInput = (notice == .needsInput)
        }
        // The roster is how we know it is a background agent at all, and a notice
        // is the moment it is most worth being right about.
        refreshBackgroundAgents()
    }

    /// Background agents currently blocked on you.
    var blockedAgents: [LiveSession] {
        sessions.values.filter { $0.agentNeedsInput && !$0.backgroundAgentId.isEmpty }
    }

    /// Open a background agent in a terminal. It has no terminal of its own, so
    /// this is the only way to see it or answer it.
    func attachBackgroundAgent(id: String, cwd: String) {
        // Attaching answers it, so it is no longer waiting on you.
        for (key, var session) in sessions where session.backgroundAgentId == id {
            session.agentNeedsInput = false
            sessions[key] = session
        }
        guard !id.isEmpty else { return }
        TerminalAutomator.attachAgent(id: id, in: cwd)
    }

    func ensureStaleTimer() {
        guard staleTimer == nil else { return }
        staleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkStale()
                self?.checkLongRun()
                // Same heartbeat: an agent can start or die without any hook
                // reaching us (it is a daemon, not a terminal).
                self?.refreshBackgroundAgents()
            }
        }
    }

    /// A session is dead if its terminal app has quit (so a Stop hook will
    /// never come — e.g. the user killed the terminal mid-run) or it has gone
    /// silent past the stale window.
    private func isSessionDead(_ s: LiveSession, cutoff: Date) -> Bool {
        if s.lastHookAt <= cutoff { return true }
        if let bid = s.originatorBundleID, !bid.isEmpty,
           NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
            return true
        }
        return false
    }

    /// After one or more sessions are removed, keep the global "current" mirror
    /// honest: if the session it pointed at is gone, re-point at the newest
    /// survivor, or collapse the notch to idle when nothing is left.
    private func resyncCurrentSession() {
        // Still pointing at a live session? Nothing to do. Prefer the session-id
        // identity (cwd can be shared by two terminals in the same project).
        let currentAlive = (!currentSessionId.isEmpty && sessions[currentSessionId] != nil)
            || (currentSessionId.isEmpty && sessions.values.contains { $0.cwd == currentCwd })
        guard !currentAlive else { return }
        // Pick the most-recently-active survivor explicitly by lastHookAt.
        // (Don't use activeSessions.first — that list is ordered by createdAt for
        // stable row display, so .first is the oldest session, not the newest.)
        if let newest = activeSessions.max(by: { $0.lastHookAt < $1.lastHookAt }) {
            currentSessionId = newest.id
            currentCwd = newest.cwd
            currentProject = newest.project
            lastActivity = newest.activity
            // Approximate: this session's last hook is the best start we have for
            // a run we did not watch begin. Off by seconds, never by minutes.
            activityStartedAt = newest.activity.isEmpty ? nil : newest.lastHookAt
            claudeActionStatus = newest.status
            lastClaudeResponse = newest.lastResponse
            fullClaudeResponse = newest.fullResponse
            currentContextPercent = newest.contextPercent
            currentContextTokens = newest.contextTokens
            currentCostUSD = newest.sessionCostUSD
            if !newest.model.isEmpty { currentModel = newest.model }
            currentPermissionMode = newest.permissionMode
        } else {
            currentSessionId = ""
            currentProject = ""
            currentCwd = ""
            lastActivity = ""
            activityStartedAt = nil
            lastUserPrompt = ""
            claudeActionStatus = lastClaudeResponse.isEmpty ? "ready" : "last reply"
            lastHookAt = nil
            currentContextPercent = 0
            currentContextTokens = 0
            currentCostUSD = 0
            currentModel = ""
            currentPermissionMode = ""
        }
    }

    /// A Claude Code session ended (SessionEnd hook — Ctrl+C / Ctrl+D / exit).
    /// Drop it immediately instead of waiting for the stale window.
    func removeSession(sessionId: String, cwd: String = "") {
        var keys: [String] = []
        if !sessionId.isEmpty, sessions[sessionId] != nil { keys.append(sessionId) }
        var normCwd = cwd
        while normCwd.count > 1, normCwd.hasSuffix("/") { normCwd.removeLast() }
        if !normCwd.isEmpty, sessions[normCwd] != nil { keys.append(normCwd) }
        guard !keys.isEmpty else { return }
        for k in keys { if let s = sessions[k] { archiveSession(s) } }
        for k in keys { sessions.removeValue(forKey: k) }
        resyncCurrentSession()
        if sessions.isEmpty {
            staleTimer?.invalidate()
            staleTimer = nil
        }
    }

    private func checkStale() {
        // Drop sessions whose terminal has been killed/closed, or that have
        // gone silent past the stale window, so the per-session list reflects
        // only what's actually running.
        let sessionCutoff = Date().addingTimeInterval(-projectStaleAfter)
        let dead = sessions.filter { isSessionDead($0.value, cutoff: sessionCutoff) }.map(\.key)
        if !dead.isEmpty {
            for k in dead { if let s = sessions[k] { archiveSession(s) } }
            for k in dead { sessions.removeValue(forKey: k) }
            resyncCurrentSession()
            if sessions.isEmpty {
                staleTimer?.invalidate()
                staleTimer = nil
                return
            }
        }

        guard let last = lastHookAt else { return }
        let age = Date().timeIntervalSince(last)
        if age > projectStaleAfter {
            // Full clear — terminal is almost certainly closed.
            currentProject = ""
            currentCwd = ""
            lastActivity = ""
            activityStartedAt = nil
            lastUserPrompt = ""
            claudeActionStatus = lastClaudeResponse.isEmpty ? "ready" : "last reply"
            lastHookAt = nil
            staleTimer?.invalidate()
            staleTimer = nil
        } else if age > activityStaleAfter {
            // Just drop the volatile fields.
            if !lastActivity.isEmpty { lastActivity = "" }
            if activityStartedAt != nil { activityStartedAt = nil }
            if !lastUserPrompt.isEmpty { lastUserPrompt = "" }
            if !lastClaudeResponse.isEmpty {
                claudeActionStatus = "last reply"
            }
        }
    }

    func openLastApp() {
        frontmost.activateLastApp()
    }

    func openOriginator(_ bundleID: String?) {
        let me = Bundle.main.bundleIdentifier
        // Discard a captured originator that points back at *us* — happens
        // whenever the notch panel was key at hook-fire time. Also discard
        // an originator whose process is no longer running.
        if let bid = bundleID, bid != me,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
           !app.isTerminated {
            AppActivation.bringToFront(app)
            return
        }
        frontmost.activateLastApp()
    }

    func returnKeyboardToTerminal(preferred: String? = nil) {
        if suppressReturnToApp { suppressReturnToApp = false; return }
        switch mode {
        case .permission, .question, .compose, .completed, .responseDetail, .history:
            return   // still interactive — keep keyboard on the notch
        default:
            break
        }
        let bid = preferred ?? lastOriginatorBundleID
        openOriginator(bid)
    }

    /// After the user CLOSES a panel they opened themselves (history, the response
    /// detail, an export), return to whatever app they were actually using —
    /// which is the last app that was frontmost before the notch took focus, not
    /// the terminal that happened to run Claude. Closing history from a
    /// full-screen browser must land you back in that browser, not yank you into
    /// the terminal.
    func returnToPreviousApp() {
        if suppressReturnToApp { suppressReturnToApp = false; return }
        switch mode {
        case .permission, .question, .compose, .completed, .responseDetail, .history:
            return   // another interactive card is still up — keep focus here
        default:
            break
        }
        frontmost.activateLastApp()
    }
}
