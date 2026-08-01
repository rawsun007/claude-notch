import Foundation
import AppKit

// Spending caps: per-session and per-day budgets, warnings, and their state.

extension AppState {
    func setDailyCostCap(_ usd: Double) {
        dailyCostCap = max(0, usd)
        dailyWarnLevel = 0
        dailyWarnDate = ""
        schedulePersist()
        // Recompute today's spend off the main thread and evaluate immediately,
        // so a cap set mid-day reflects what you've already spent.
        guard dailyCostCap > 0 else { return }
        Task { [weak self] in
            let cost = await Task.detached { ClaudeUsageReader.compute().today.costUSD }.value
            self?.noteTodayCost(cost)
        }
    }

    /// Which budget threshold `cost` has crossed against `cap`: 100, 80, or 0.
    nonisolated static func budgetLevel(cost: Double, cap: Double) -> Int {
        guard cap > 0 else { return 0 }
        if cost >= cap { return 100 }
        if cost >= cap * 0.8 { return 80 }
        return 0
    }

    /// Push today's total estimated spend (from EventServer) and alert if it
    /// crosses the daily cap. The level resets at the start of a new day.
    func noteTodayCost(_ cost: Double) {
        todayCostUSD = cost
        guard dailyCostCap > 0 else { return }
        let today = Self.dayKey(Date())
        if dailyWarnDate != today { dailyWarnDate = today; dailyWarnLevel = 0 }
        let level = Self.budgetLevel(cost: cost, cap: dailyCostCap)
        if level > dailyWarnLevel {
            dailyWarnLevel = level
            warnBudget(scope: "daily", level: level, cost: cost, cap: dailyCostCap)
        }
    }

    /// Push rolling 5-hour and weekly cost totals for the status bar.
    func noteRollingCosts(fiveHour: Double, weekly: Double) {
        fiveHourCostUSD = fiveHour
        weeklyCostUSD = weekly
    }

    /// Effort read from ~/.claude/settings.json (cheap file read, call off-thread).
    ///
    /// Ignored once the status line has told us the *running* session's effort:
    /// the file says what a new session would start at, the status line says what
    /// this one is actually on, and they disagree the moment you change effort
    /// mid-session. A one-minute settings poll would otherwise keep stomping the
    /// live value back to the stale one.
    func noteEffort(_ effort: String) {
        guard !effortIsLive else { return }
        currentEffort = effort
    }

    func noteLiveEffort(_ effort: String) {
        guard !effort.isEmpty else { return }
        effortIsLive = true
        currentEffort = effort.prefix(1).uppercased() + effort.dropFirst()
    }

    /// Seed the model from a transcript scan at startup. Only fills in if
    /// the model is still unknown — a hook-driven update takes precedence.
    func noteStartupModel(_ model: String) {
        if currentModel.isEmpty { currentModel = model }
    }

    func setFiveHourCostCap(_ usd: Double) {
        fiveHourCostCap = max(0, usd)
        schedulePersist()
    }

    func setWeeklyCostCap(_ usd: Double) {
        weeklyCostCap = max(0, usd)
        schedulePersist()
    }

    /// Replace the visible status-bar items (max 2, order preserved).
    func setStatusBarItems(_ items: [StatusBarItem]) {
        statusBarItems = Array(items.prefix(2))
        schedulePersist()
    }

    func setContextWindowMode(_ mode: ContextWindowMode) {
        contextWindowMode = mode
        // Re-derive the visible header % from the last known token count so the
        // override takes effect immediately, not only on the next turn.
        if let s = currentSessionId.isEmpty ? nil : sessions[currentSessionId],
           s.contextTokens > 0 {
            let pct = ClaudeUsageReader.contextPercent(tokens: s.contextTokens, model: s.model, mode: mode)
            sessions[currentSessionId]?.contextPercent = pct
            currentContextPercent = pct
            currentContextTokens = sessions[currentSessionId]?.contextTokens ?? 0
        }
        schedulePersist()
    }

    /// Keep an anchor reading per limit window and project from it.
    ///
    /// The anchor is tied to the window's reset instant, the same way
    /// checkRateLimit re-arms its thresholds. A falling percentage is the
    /// obvious sign of a rollover, but it is not a reliable one: if the window
    /// resets and usage climbs past the old reading before the next status
    /// line arrives, the percentage only ever goes up and the anchor would be
    /// left in the previous window, quietly measuring a rate across a reset and
    /// under-reporting how fast the new window is filling.
    ///
    /// The anchor also moves forward once a reading is old, so the forecast
    /// follows the last stretch of work rather than an average over the window.
    func updateForecast(_ anchor: inout (sample: BurnRate.Sample, window: Date?)?,
                        pct: Double, resetAt: Date?) -> BurnRate.Forecast? {
        let now = BurnRate.Sample(percent: min(1, max(0, pct)), at: Date())
        guard let previous = anchor else {
            anchor = (now, resetAt)
            return nil
        }
        // A different window, or usage that fell: either way start again.
        if previous.window != resetAt || now.percent < previous.sample.percent {
            anchor = (now, resetAt)
            return nil
        }
        let forecast = BurnRate.project(from: previous.sample, to: now, resetAt: resetAt)
        if now.at.timeIntervalSince(previous.sample.at) > 3600 { anchor = (now, resetAt) }
        return forecast
    }

    /// Authoritative usage fed by Claude Code's statusLine command (the only
    /// local source of real plan-limit %). Percentages arrive as 0...100.
    func noteStatusLine(sessionId: String, model: String,
                        sessionName: String = "", worktree: String = "",
                        prNumber: Int? = nil, prURL: String = "", prState: String = "",
                        effort: String = "",
                        reportedCostUSD: Double? = nil,
                        linesAdded: Int? = nil, linesRemoved: Int? = nil,
                        contextPct: Double?, contextWindow: Int? = nil, contextTokens: Int? = nil,
                        fiveHourPct: Double?, sevenDayPct: Double?,
                        fiveHourResetsAt: Date? = nil, sevenDayResetsAt: Date? = nil) {
        if let p = fiveHourPct { fiveHourLimitPercent = min(1, max(0, p / 100)) }
        if let p = sevenDayPct { weeklyLimitPercent = min(1, max(0, p / 100)) }
        noteLiveEffort(effort)
        if let d = fiveHourResetsAt { fiveHourResetAt = d }
        if let d = sevenDayResetsAt { weeklyResetAt = d }
        // Warn before a plan limit runs out, so a lockout is not a surprise.
        if let p = fiveHourPct { checkRateLimit(name: "5-hour", pct: p / 100, resetAt: fiveHourResetAt, armed: &fiveHourWarned) }
        if let p = sevenDayPct { checkRateLimit(name: "weekly", pct: p / 100, resetAt: weeklyResetAt, armed: &weeklyWarned) }
        if fiveHourPct != nil || sevenDayPct != nil {
            limitsUpdatedAt = Date()
            schedulePersist()
        }
        // How long is left at the rate it is actually being spent. The
        // thresholds above say where you are; this says when you stop.
        if let p = fiveHourPct {
            fiveHourForecast = updateForecast(&fiveHourAnchor, pct: p / 100, resetAt: fiveHourResetAt)
        }
        if let p = sevenDayPct {
            weeklyForecast = updateForecast(&weeklyAnchor, pct: p / 100, resetAt: weeklyResetAt)
        }

        // Model update is independent of contextPct — a status line may carry a
        // model string but no context percentage (e.g. early in a session).
        let pct = contextPct.map { min(1, max(0, $0 / 100)) }
        upsertSession(id: sessionId, cwd: currentCwd) { s in
            if let pct { s.contextPercent = pct }
            if !model.isEmpty { s.model = model }
            if let w = contextWindow, w > 0 { s.contextWindow = w }
            if let t = contextTokens, t > 0 { s.contextTokens = t }
            if !sessionName.isEmpty { s.title = sessionName }
            if !worktree.isEmpty { s.worktree = worktree }
            if let pr = prNumber, pr > 0 {
                s.prNumber = pr
                // The PR link comes from a hook payload and gets handed to
                // NSWorkspace.open on click. Only keep it if it's a real web URL,
                // so a crafted pr_url can't open a file:// or custom-scheme
                // handler. A rejected URL leaves the chip present but unclickable.
                s.prURL = AppState.sanitizedWebURL(prURL)
                s.prState = prState
            }
            if let c = reportedCostUSD, c > 0 { s.reportedCostUSD = c }
            if let l = linesAdded, l > 0 { s.linesAdded = l }
            if let l = linesRemoved, l > 0 { s.linesRemoved = l }
        }
        let isCurrent = currentSessionId.isEmpty || sessionId == currentSessionId
        guard isCurrent else { return }
        if let pct { currentContextPercent = pct }
        if !model.isEmpty { currentModel = model }
        if let c = reportedCostUSD, c > 0 { currentCostUSD = c }
        if let w = contextWindow, w > 0 {
            currentContextWindow = w
            // Remember it per model, so the next session on this model shows the
            // right window from its first frame instead of guessing until the
            // first status line lands.
            // Only learn a NEW model's window while under the cap: the key is an
            // untrusted model string from the payload, and this map is persisted,
            // so an unbounded one would bloat state.json forever. Updating a model
            // we already know is always fine.
            if !model.isEmpty, learnedContextWindows[model] != w,
               learnedContextWindows[model] != nil || learnedContextWindows.count < learnedWindowsMax {
                learnedContextWindows[model] = w
                schedulePersist()
            }
        }
        if let t = contextTokens, t > 0 { currentContextTokens = t }
    }

    /// The window to measure a session against: what Claude Code reported for it,
    /// else what it reported for this model before, else the inference.
    nonisolated static func windowFor(model: String, reported: Int, learned: [String: Int],
                                      tokens: Int, mode: ContextWindowMode) -> Int {
        if mode == .auto {
            if reported > 0 { return reported }
            if let known = learned[model], known > 0 { return known }
        }
        return ClaudeUsageReader.contextWindow(forModel: model, tokens: tokens, mode: mode)
    }

    /// Demo entry point: show the budget alert card exactly as a real
    /// over-budget event renders it.
    func demoBudgetAlert() {
        warnBudget(scope: "session", level: 100, cost: 27.40, cap: 25)
    }

    /// Demo entry point: show a budget hard-stop card (Deny / Allow once /
    /// Raise cap) for a fake over-cap command.
    func demoBudgetBlock() {
        let req = PermissionRequest(
            kind: .toolUse, title: "Run shell command", detail: "npm run build",
            toolName: "Bash", source: "Demo", cwd: NSHomeDirectory(),
            resolver: { _, _ in })
        req.budgetBlock = BudgetBlock(scope: "session", cost: 10.40, cap: 10)
        permissionQueue.append(req)
        playAlert(toolName: "Bash")
        recompute()
    }

    func setEnforceBudget(_ on: Bool) { enforceBudget = on; schedulePersist() }

    /// Is this tool request over a cap that enforcement should hold back? Daily
    /// is checked first (broader); session uses the originating session's spend.
    func budgetBlock(for req: PermissionRequest) -> BudgetBlock? {
        if dailyCostCap > 0, todayCostUSD >= dailyCostCap {
            return BudgetBlock(scope: "daily", cost: todayCostUSD, cap: dailyCostCap)
        }
        if sessionCostCap > 0 {
            let cost = sessionCost(forCwd: req.cwd)
            if cost >= sessionCostCap {
                return BudgetBlock(scope: "session", cost: cost, cap: sessionCostCap)
            }
        }
        return nil
    }

    /// Best estimate of the spend for the session a request belongs to: the
    /// priciest live session at that cwd, falling back to the global mirror.
    private func sessionCost(forCwd cwd: String) -> Double {
        var c = cwd
        while c.count > 1, c.hasSuffix("/") { c.removeLast() }
        let matching = sessions.values.filter { $0.cwd == c }.map { $0.sessionCostUSD }
        return matching.max() ?? currentCostUSD
    }

    /// Raise the blocked cap above the current spend and allow the held request,
    /// so the flow continues instead of re-blocking on the next call.
    func raiseBudgetAndAllow() {
        guard let req = permissionQueue.first, let block = req.budgetBlock else { return }
        let newCap = Self.nextCap(covering: block.cost, current: block.cap)
        if block.scope == "daily" { setDailyCostCap(newCap) } else { setSessionCostCap(newCap) }
        resolveCurrentPermission(.allow)
    }

    /// Turn enforcement off and allow the held request in one click.
    func disableEnforcementAndAllow() {
        setEnforceBudget(false)
        resolveCurrentPermission(.allow)
    }

    /// Next sensible cap above both the current cap and the spend that tripped
    /// it, so the allow goes through and isn't re-blocked immediately.
    static func nextCap(covering cost: Double, current cap: Double) -> Double {
        let presets: [Double] = [1, 2, 5, 10, 25, 50, 100, 200, 500]
        if let n = presets.first(where: { $0 > cost && $0 > cap }) { return n }
        return (cost / 50).rounded(.down) * 50 + 50   // beyond presets: next $50
    }

    /// The dollar amount the Raise-cap button would set, for its label.
    func raisedCapTarget(for block: BudgetBlock) -> Double {
        Self.nextCap(covering: block.cost, current: block.cap)
    }

    func warnBudget(scope: String, level: Int, cost: Double, cap: Double) {
        let pct = Int((cost / cap * 100).rounded())
        let title = level >= 100 ? "Over your \(scope) budget" : "Approaching your \(scope) budget"
        let detail = "\(ClaudeUsageReader.fmtMoney(cost)) of \(ClaudeUsageReader.fmtMoney(cap)) \(scope) cap (\(pct)%)"
        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: title,
            detail: detail,
            toolName: "Budget",
            source: "Cost budget",
            cwd: currentCwd,
            resolver: { _, _ in }
        ))
    }

    /// Suppress non-blocking cards (notifications + completions) for N minutes.
    /// Permission cards still show — Claude is blocking on them.
    func snooze(forMinutes minutes: Int) {
        snoozedUntil = Date().addingTimeInterval(Double(minutes) * 60)
        snoozeTimer?.invalidate()
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.snoozedUntil = nil
                self?.snoozeTimer = nil
            }
        }
    }

    func cancelSnooze() {
        snoozeTimer?.invalidate(); snoozeTimer = nil
        snoozedUntil = nil
    }

    /// Friendly welcome card shown once at the end of the onboarding flow, so
    /// first-time users immediately see what a ClaudeNotch card looks like.
    func triggerWelcomeDemo() {
        let req = PermissionRequest(
            kind: .notification,
            title: "Welcome to ClaudeNotch!",
            detail: "Permissions, questions, and notifications from Claude Code will appear right here. Click Dismiss when you're ready.",
            toolName: "Notification",
            source: "Demo",
            cwd: NSHomeDirectory(),
            resolver: { _, _ in }
        )
        enqueuePermission(req, bypassRules: true)
    }

    func schedulePersist() {
        persistTimer?.invalidate()
        persistTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.persistNow() }
        }
    }

    private func persistNow() {
        Persistence.save(.init(
            history: history,
            sessionHistory: sessionHistory,
            allowRules: allowRules,
            recentProjects: recentProjects,
            // Don't persist a timed auto-approve as a permanent ON — would
            // get stuck on after a restart since the timer is gone.
            autoApprove: autoApprove && autoApproveUntil == nil,
            soundMuted: soundMuted,
            stats: stats,
            alertSound: alertSound,
            perToolSounds: perToolSounds,
            perToolSoundMap: perToolSoundMap,
            persistentNotchDisplay: persistentNotchDisplay,
            petEnabled: petEnabled,
            petRandomEnabled: petRandomEnabled,
            completionAuditEnabled: completionAuditEnabled,
            lastDigestDate: lastDigestDate,
            lastUpdateCardVersion: lastUpdateCardVersion,
            lastSeenVersion: lastSeenVersion,
            sessionCostCap: sessionCostCap,
            dailyCostCap: dailyCostCap,
            fiveHourCostCap: fiveHourCostCap,
            weeklyCostCap: weeklyCostCap,
            requireTouchID: requireTouchID,
            mirrorToNotificationCenter: mirrorToNotificationCenter,
            completionNotificationsEnabled: completionNotificationsEnabled,
            digestNotificationsEnabled: digestNotificationsEnabled,
            hideFromScreenCapture: hideFromScreenCapture,
            showSpendInMenuBar: showSpendInMenuBar,
            showPlanInMenuBar: showPlanInMenuBar,
            enforceBudget: enforceBudget,
            statusBarItems: statusBarItems.map(\.rawValue),
            contextWindowMode: contextWindowMode.rawValue,
            notchTitleMode: notchTitleMode.rawValue,
            customNotchTitle: customNotchTitle,
            learnedContextWindows: learnedContextWindows,
            fiveHourLimitPercent: fiveHourLimitPercent,
            weeklyLimitPercent: weeklyLimitPercent,
            fiveHourResetAt: fiveHourResetAt,
            weeklyResetAt: weeklyResetAt,
            limitsUpdatedAt: limitsUpdatedAt,
            breakRemindersEnabled: breakRemindersEnabled,
            longRunAlertsEnabled: longRunAlertsEnabled,
            rateLimitWarningsEnabled: rateLimitWarningsEnabled,
            pinnedProjects: Array(pinnedProjects),
            sessionNotes: sessionNotes,
            lastWeeklyDigestDate: lastWeeklyDigestDate,
            dropStartsCodex: dropStartsCodex
        ))
    }

    /// Pin or unpin a project directory to the top of the sessions list.
    func togglePinnedProject(_ cwd: String) {
        if pinnedProjects.contains(cwd) { pinnedProjects.remove(cwd) }
        else { pinnedProjects.insert(cwd) }
        schedulePersist()
    }

    /// Set (or clear, when empty) a user-given name for a session.
    func setSessionNote(id: String, _ note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { sessionNotes[id] = nil }
        else { sessionNotes[id] = trimmed }
        schedulePersist()
    }

    func setHovering(_ value: Bool) {
        if isHovering != value { isHovering = value }
    }

    func noteSession(cwd: String, sessionId: String = "", originatorBundleID: String? = nil) {
        // Normalize: strip trailing slashes so "/a/b" and "/a/b/" dedupe.
        var c = cwd
        while c.count > 1, c.hasSuffix("/") { c.removeLast() }
        guard !c.isEmpty else { return }
        currentCwd = c
        currentProject = (c as NSString).lastPathComponent
        // A real hook just arrived for this session, so it becomes the one the
        // global mirror tracks. (Polls don't run through here, so they can't
        // steal "current" from the session the user is actually watching.)
        if !sessionId.isEmpty { currentSessionId = sessionId }
        let beforeRecent = recentProjects
        recentProjects.removeAll { $0 == c }
        recentProjects.insert(c, at: 0)
        if recentProjects.count > 8 { recentProjects = Array(recentProjects.prefix(8)) }
        if recentProjects != beforeRecent { schedulePersist() }
        let bid = (originatorBundleID != Bundle.main.bundleIdentifier) ? originatorBundleID : nil
        if let bid { lastOriginatorBundleID = bid }
        lastHookAt = Date()
        noteFocusActivity()
        upsertSession(id: sessionId, cwd: c, authoritativeCwd: true, create: true) { s in
            if let bid { s.originatorBundleID = bid }
        }
        refreshGitBranch(cwd: c, sessionId: sessionId)
        ensureStaleTimer()
    }
}
