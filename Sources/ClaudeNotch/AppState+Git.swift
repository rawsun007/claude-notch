import Foundation
import AppKit

// Git context for a session: branch, diff stat, and churn.

extension AppState {
    func refreshGitBranch(cwd: String, sessionId: String) {
        let now = Date()
        if let hit = branchCache[cwd], now.timeIntervalSince(hit.readAt) < 15 {
            upsertSession(id: sessionId, cwd: cwd) { s in
                if s.gitBranch != hit.branch { s.gitBranch = hit.branch }
            }
            return
        }
        let branch = Self.readGitBranch(cwd: cwd)
        branchCache[cwd] = (branch, now)
        upsertSession(id: sessionId, cwd: cwd) { s in
            if s.gitBranch != branch { s.gitBranch = branch }
        }
    }

    /// Read the checked-out branch from `.git/HEAD` without running git.
    /// See `Git.branch(forCwd:)` for the shared reader.
    static func readGitBranch(cwd: String) -> String { Git.branch(forCwd: cwd) }

    /// Whether `path` should be revealed in Finder instead of opened: it is
    /// missing (a guessy path), a directory/bundle, carries a runnable
    /// extension, or has the execute bit set. Pure so the classification is
    /// unit-testable without touching NSWorkspace.
    nonisolated static func isRiskyToOpen(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
        return !exists                            // missing: don't hand a guessy path to the launcher
            || isDir.boolValue                    // directory or .app-style bundle
            || riskyOpenExtensions.contains(ext)
            || fm.isExecutableFile(atPath: path)  // execute bit set
    }

    static func openEditedFile(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if isRiskyToOpen(path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Accept only http/https web URLs for anything from an untrusted hook
    /// payload that we'll later hand to NSWorkspace.open. Everything else becomes
    /// "" so it can't launch a file:// or custom-scheme handler. Returns the
    /// original string when safe (preserving the exact link), else "".
    nonisolated static func sanitizedWebURL(_ s: String) -> String {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "https" || scheme == "http", u.host?.isEmpty == false else { return "" }
        return s
    }

    /// "42s" / "3m 05s" — a live run timer, not an age. Seconds matter here:
    /// the whole point is seeing it move.
    nonisolated static func runningDuration(seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        // Past an hour, minutes-only reads as nonsense ("15543m 54s"). Roll up
        // into hours, and into days once a session spans more than one.
        if s < 86_400 { return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60) }
        return String(format: "%dd %02dh", s / 86_400, (s % 86_400) / 3600)
    }

    func noteActivity(_ label: String, sessionId: String = "") {
        // A tool is starting: the turn is live again, so late hooks from the
        // previous turn stop being ignored.
        turnGate.workStarted(TurnGate.key(sessionId: sessionId, cwd: currentCwd))
        lastActivity = label
        activityStartedAt = Date()   // each tool call restarts the run clock
        let status = Self.statusLabel(fromActivity: label)
        claudeActionStatus = status
        lastActivityAt = Date()
        lastHookAt = Date()
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.activity = label
            s.status = status
            s.toolCallCount += 1
        }
        ensureStaleTimer()
    }

    /// Called after a tool completes (PostToolUse) to show Claude is reasoning
    /// before the next tool call. Clears the command strip and sets status to
    /// "thinking" — persists until the next noteActivity call.
    ///
    /// Ignored outright once the turn has ended. A backgrounded Bash reports its
    /// PostToolUse after Stop, and honouring it would strand the notch on
    /// "thinking" with no further hook coming to clear it.
    func noteThinkingBetweenTools(sessionId: String = "") {
        guard !turnGate.isLate(TurnGate.key(sessionId: sessionId, cwd: currentCwd)) else { return }
        claudeActionStatus = "thinking"
        lastActivity = ""
        activityStartedAt = nil
        lastHookAt = Date()
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.activity = ""
            s.status = "thinking"
        }
        ensureStaleTimer()
    }

    /// Push a freshly-parsed context + cost meter for a session. Updates that
    /// session's row always; mirrors to the global header only for the current
    /// session (same gate as noteClaudeResponse, so background sessions can't
    /// thrash the header).
    func noteSessionMeter(sessionId: String, contextTokens: Int, costUSD: Double, model: String) {
        let contextPercent = ClaudeUsageReader.contextPercent(
            tokens: contextTokens, model: model, mode: contextWindowMode)
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.contextPercent = contextPercent
            s.contextTokens = contextTokens
            s.sessionCostUSD = costUSD
            if !model.isEmpty { s.model = model }
            // Only a real reading ends the cue. A zero is what the transcript
            // reports between the compaction boundary and the first turn after
            // it, and treating that as "compaction over" is what used to lower
            // the cue seconds after it went up. (PostCompact ends it properly;
            // this is the fallback for a CLI too old to send one.)
            if contextTokens > 0 { s.isCompacting = false }
        }

        // Per-session budget: alert when this session crosses 80% / 100% of cap.
        if sessionCostCap > 0 {
            let key = !sessionId.isEmpty ? sessionId : currentCwd
            if !key.isEmpty {
                let level = Self.budgetLevel(cost: costUSD, cap: sessionCostCap)
                if level > (sessionWarnLevel[key] ?? 0) {
                    sessionWarnLevel[key] = level
                    warnBudget(scope: "session", level: level, cost: costUSD, cap: sessionCostCap)
                }
            }
        }

        let isCurrent = currentSessionId.isEmpty || sessionId == currentSessionId
        guard isCurrent else { return }
        currentContextPercent = contextPercent
        currentContextTokens = contextTokens
        // Our estimate must not overwrite Claude Code's own figure. This poll runs
        // constantly, so without the guard the real cost would be replaced by the
        // estimate seconds after every status line delivered it.
        let key = !sessionId.isEmpty ? sessionId : currentCwd
        let reported = sessions[key]?.reportedCostUSD ?? 0
        currentCostUSD = reported > 0 ? reported : costUSD
        if !model.isEmpty { currentModel = model }
    }

    /// Push a Codex session's context/token usage (parsed from its rollout).
    /// Codex sends no status line, so this is how a Codex session gets a live
    /// meter. Uses the real window from the rollout; no dollar cost (unknown
    /// gpt pricing).
    func noteCodexUsage(sessionId: String, cwd: String, contextTokens: Int,
                        contextWindow: Int, model: String, gitBranch: String = "",
                        totalTokens: Int = 0) {
        let pct = contextWindow > 0 ? min(1.0, max(0, Double(contextTokens) / Double(contextWindow))) : 0
        upsertSession(id: sessionId, cwd: cwd.isEmpty ? currentCwd : cwd) { s in
            s.contextTokens = contextTokens
            s.contextWindow = contextWindow
            s.contextPercent = pct
            // Cumulative and monotonic, so a stale smaller reading never walks
            // a session's budget backwards.
            if totalTokens > s.totalTokens { s.totalTokens = totalTokens }
            if !model.isEmpty { s.model = model }
            if !gitBranch.isEmpty { s.gitBranch = gitBranch }
            if contextTokens > 0 { s.isCompacting = false }
        }
        let isCurrent = currentSessionId.isEmpty || sessionId == currentSessionId
        guard isCurrent else { return }
        currentContextPercent = pct
        currentContextTokens = contextTokens
        currentContextWindow = contextWindow
        // Codex has no dollar cost; clear the global mirror so a previous
        // Claude session's cost doesn't bleed onto the Codex header.
        currentCostUSD = 0
        if !model.isEmpty { currentModel = model }
    }

    /// A directory was granted to a running session via /add-dir.
    ///
    /// Recorded against the session rather than globally: two sessions in the
    /// same project can be granted different directories, and the question
    /// this answers is what THIS session may touch.
    func noteDirectoryAdded(sessionId: String, cwd: String, directory: String,
                            how: String = "") {
        let dir = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return }
        upsertSession(id: sessionId, cwd: cwd.isEmpty ? currentCwd : cwd, create: true) { s in
            // Capped and de-duplicated: the path arrives on a hook payload, and
            // /add-dir on a directory already added is an ordinary thing to do.
            guard !s.addedDirectories.contains(dir) else { return }
            s.addedDirectories.append(dir)
            if s.addedDirectories.count > Self.addedDirectoriesMax {
                s.addedDirectories.removeFirst()
            }
        }
        appendHistory(HistoryEntry(
            timestamp: Date(),
            kind: .notification,
            toolName: "AddDir",
            title: how.isEmpty ? "Directory added to the session"
                              : "Directory added to the session (\(how))",
            detail: dir,
            project: (cwd as NSString).lastPathComponent,
            outcome: .info))
    }

    /// Claude ran `cd`, so this session is somewhere else now.
    ///
    /// Most of what the notch shows about a session self-heals, because every
    /// hook payload carries the cwd it fired in. The exception is a session
    /// with no session_id: it is FILED UNDER its cwd, so the key it lives at
    /// has just become wrong, and the next hook creates a second row for the
    /// same session rather than updating the first. That is the gap this
    /// closes; the branch and project label are refreshed on the way.
    func noteCwdChanged(sessionId: String, oldCwd: String, newCwd: String) {
        let from = Self.normalizedCwd(oldCwd)
        let to = Self.normalizedCwd(newCwd)
        guard !to.isEmpty, from != to else { return }

        if sessionId.isEmpty, !from.isEmpty,
           sessions[to] == nil, var moved = sessions[from] {
            sessions.removeValue(forKey: from)
            moved.id = to
            moved.cwd = to
            moved.project = (to as NSString).lastPathComponent
            // Read again below rather than carried over: the new directory can
            // be a different repo, or no repo at all.
            moved.gitBranch = ""
            sessions[to] = moved
        } else {
            upsertSession(id: sessionId, cwd: to, authoritativeCwd: true) { s in
                s.gitBranch = ""
            }
        }

        // The global mirror follows the session it was already tracking.
        if (!sessionId.isEmpty && sessionId == currentSessionId) || currentCwd == from {
            currentCwd = to
            currentProject = (to as NSString).lastPathComponent
        }
        refreshGitBranch(cwd: to, sessionId: sessionId)
        // A different directory can be governed by different project settings,
        // so the sandbox answer moves with the cwd.
        refreshSandbox(cwd: to, sessionId: sessionId)
    }

    func noteSubagentStarted(sessionId: String = "") {
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.runningAgentCount += 1
        }
    }

    func noteSubagentStopped(sessionId: String = "") {
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.runningAgentCount = max(0, s.runningAgentCount - 1)
        }
    }

    /// PreCompact: context is about to be compacted. Flag the session so the UI
    /// can show a "compacting" cue; cleared when PostCompact says it is over.
    func noteCompacting(sessionId: String = "") {
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.isCompacting = true
            // The pre-compact occupancy is about to be wrong (context shrinks).
            // Drop it now so the bar doesn't sit stale-high until the next turn.
            s.contextPercent = 0
            s.contextTokens = 0
        }
        let isCurrent = currentSessionId.isEmpty || sessionId == currentSessionId
        if isCurrent { currentContextPercent = 0; currentContextTokens = 0 }
    }

    /// PostCompact: compaction is over and the summary exists.
    ///
    /// Until this hook existed the "compacting" cue was cleared by whatever
    /// event happened to arrive next — a status line, a tool call, a meter
    /// poll — so it ended early on a busy session and hung around on a quiet
    /// one. The end of compaction is now the thing that ends it.
    func noteCompacted(sessionId: String = "", cwd: String = "",
                       trigger: String = "", summary: String = "") {
        let dir = cwd.isEmpty ? currentCwd : cwd
        upsertSession(id: sessionId, cwd: dir) { s in
            s.isCompacting = false
        }
        // The summary is the whole point of the event: it is what the session
        // now remembers instead of the conversation it just lost.
        let detail = String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        appendHistory(HistoryEntry(
            timestamp: Date(),
            kind: .notification,
            toolName: "Compact",
            title: trigger == "manual"
                ? L("Context compacted with /compact", comment: "History row: the user compacted the context by hand")
                : L("Context compacted automatically", comment: "History row: the context filled up and Claude Code compacted it"),
            detail: detail,
            project: (dir as NSString).lastPathComponent,
            outcome: .info))
    }

    func noteUserPrompt(_ prompt: String, sessionId: String = "") {
        // A new turn: whatever was in flight for the last one is now irrelevant.
        turnGate.workStarted(TurnGate.key(sessionId: sessionId, cwd: currentCwd))
        lastUserPrompt = String(prompt.prefix(140))
        lastClaudeResponse = ""
        fullClaudeResponse = ""
        lastClaudeResponseAt = nil
        claudeActionStatus = "thinking"
        lastHookAt = Date()
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            s.status = "thinking"
            s.lastResponse = ""
            // The audit only counts work done for the reply it is judging.
            // fullResponse has to go too: it is the claim the audit reads, and
            // leaving the last turn's text there means a turn that only answers
            // a question inherits the previous turn's "I've updated the
            // handler" and gets accused of not having done it.
            s.fullResponse = ""
            s.turnFilesEdited = 0
            s.turnRanCommand = false
            s.turnRanTests = false
            s.turnTestFailed = nil
            // A finished checklist belongs to the previous turn. Clear a fully
            // completed task list on a new prompt so its 100% bar does not
            // linger; a still-in-progress list is left alone (the turn may be
            // continuing it) and will refresh on the next TodoWrite.
            if s.todoTotal > 0, s.todoDone >= s.todoTotal {
                s.todoTotal = 0; s.todoDone = 0
            }
            if !s.createdTaskIds.isEmpty, s.completedTaskIds.count >= s.createdTaskIds.count {
                s.createdTaskIds.removeAll(); s.completedTaskIds.removeAll()
            }
        }
        ensureStaleTimer()
    }

    // MARK: - Task progress meter

    /// A task was created (TaskCreated hook, or a TaskCreate tool call). Counts
    /// toward the session's "N/M" meter. If the previous batch was already
    /// fully complete, a fresh creation starts a new list (so the denominator
    /// doesn't grow without bound across a long session).
    /// `viaUpdate` is set when the id came from a status change rather than a
    /// creation. That distinction decides whether a finished batch may be
    /// cleared: working through a list one task at a time means every update
    /// arrives with the batch momentarily complete, and clearing on those would
    /// reset the meter to 0 of 1 after every single task.
    func noteTaskCreated(id: String, subject: String = "", sessionId: String = "",
                         viaUpdate: Bool = false) {
        guard !id.isEmpty else { return }
        upsertSession(id: sessionId, cwd: currentCwd, create: true) { s in
            if !viaUpdate,
               !s.createdTaskIds.isEmpty,
               s.completedTaskIds.count >= s.createdTaskIds.count {
                s.createdTaskIds.removeAll()
                s.completedTaskIds.removeAll()
            }
            s.createdTaskIds.insert(id)
        }
        lastHookAt = Date()
        ensureStaleTimer()
    }
}
