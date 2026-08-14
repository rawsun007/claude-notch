import Foundation
import AppKit

// Token and cost usage: reading transcripts, rollups, and the daily counts.

extension AppState {
    /// ISO year-and-week key (e.g. "2026-W30"), used to fire the weekly digest
    /// at most once per calendar week. Pure, so it is unit-tested (nonisolated
    /// so the tests can call it off the main actor).
    nonisolated static func weekKey(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        return "\(c.yearForWeekOfYear ?? 0)-W\(c.weekOfYear ?? 0)"
    }

    func markActiveToday() {
        if stats.firstUsed == nil { stats.firstUsed = Date() }
        let today = Self.dayKey(Date())
        if stats.activeDays.last != today, !stats.activeDays.contains(today) {
            stats.activeDays.append(today)
            if stats.activeDays.count > 400 {
                stats.activeDays = Array(stats.activeDays.suffix(400))
            }
        }
    }

    /// A tool permission was requested (shown or auto-handled).
    func recordToolRequested(_ toolName: String, dangerousShown: Bool) {
        markActiveToday()
        stats.toolCounts[toolName, default: 0] += 1
        sessionTools += 1
        let today = Self.dayKey(Date())
        var day = stats.dailyCounts[today] ?? DayCounts()
        day.tools += 1
        if dangerousShown {
            stats.dangerousFlagged += 1
            day.dangerousFlagged += 1
        }
        stats.dailyCounts[today] = day
        pruneOldDailyCounts()
        schedulePersist()
    }

    func recordDecision(_ decision: PermissionDecision, auto: Bool) {
        let today = Self.dayKey(Date())
        var day = stats.dailyCounts[today] ?? DayCounts()
        switch decision {
        case .allow:
            stats.allowed += 1; sessionAllowed += 1
            day.allowed += 1
            if auto { stats.autoApproved += 1; day.autoApproved += 1 }
        case .deny:
            stats.denied += 1; sessionDenied += 1
            day.denied += 1
            if auto { stats.autoDenied += 1; day.autoDenied += 1 }
            petStartle()
        case .ask:
            break
        }
        stats.dailyCounts[today] = day
        schedulePersist()
    }

    /// Keep the per-day map bounded so state.json doesn't grow forever.
    private func pruneOldDailyCounts() {
        guard stats.dailyCounts.count > 400 else { return }
        let sorted = stats.dailyCounts.keys.sorted()
        let drop = sorted.prefix(stats.dailyCounts.count - 400)
        for k in drop { stats.dailyCounts.removeValue(forKey: k) }
    }

    /// Counts for "yesterday" (or nil if you weren't active yesterday).
    var yesterdayCounts: DayCounts? {
        let cal = Calendar.current
        guard let y = cal.date(byAdding: .day, value: -1, to: Date()) else { return nil }
        return stats.dailyCounts[Self.dayKey(y)]
    }

    var shouldShowDigest: Bool {
        let today = Self.dayKey(Date())
        return yesterdayCounts != nil && lastDigestDate != today
    }

    func markDigestShown() {
        lastDigestDate = Self.dayKey(Date())
        schedulePersist()
    }

    /// Distinct days ClaudeNotch handled something.
    var activeDayCount: Int { Set(stats.activeDays).count }

    /// Consecutive-day streak ending today (or yesterday if nothing yet today).
    var currentStreak: Int {
        let set = Set(stats.activeDays)
        let cal = Calendar.current
        var day = Date()
        if !set.contains(Self.dayKey(day)) {
            guard let y = cal.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = y
            if !set.contains(Self.dayKey(day)) { return 0 }
        }
        var streak = 0
        while set.contains(Self.dayKey(day)) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    func setAutoApprove(_ on: Bool) {
        autoApprove = on
        // Manual toggle cancels any in-progress timed window.
        autoApproveTimer?.invalidate(); autoApproveTimer = nil
        autoApproveUntil = nil
        schedulePersist()
    }

    /// Turn auto-approve on for N minutes, then automatically turn it back off.
    func enableAutoApprove(forMinutes minutes: Int) {
        autoApprove = true
        autoApproveUntil = Date().addingTimeInterval(Double(minutes) * 60)
        autoApproveTimer?.invalidate()
        autoApproveTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.autoApprove = false
                self.autoApproveUntil = nil
                self.autoApproveTimer = nil
                self.schedulePersist()
            }
        }
        // Don't persist autoApprove=true here — persistNow guards it.
    }

    func setSoundMuted(_ on: Bool) { soundMuted = on; schedulePersist() }

    func setAlertSound(_ name: String) { alertSound = name; schedulePersist() }

    func setPerToolSounds(_ on: Bool) { perToolSounds = on; schedulePersist() }

    func setPersistentNotchDisplay(_ on: Bool) { persistentNotchDisplay = on; schedulePersist() }

    func setRequireTouchID(_ on: Bool) { requireTouchID = on; schedulePersist() }
    func setStrictMode(_ on: Bool) { strictMode = on; schedulePersist() }

    func setMirrorToNotificationCenter(_ on: Bool) {
        mirrorToNotificationCenter = on
        if on {
            // Post any currently-queued blocking cards so the toggle takes
            // effect immediately rather than only on the next request.
            for req in permissionQueue where req.kind == .toolUse {
                permissionMirror?.mirror(req)
            }
        } else {
            permissionMirror?.withdrawAll()
        }
        schedulePersist()
    }

    func setCompletionNotificationsEnabled(_ on: Bool) {
        completionNotificationsEnabled = on
        schedulePersist()
    }

    func setDigestNotificationsEnabled(_ on: Bool) {
        digestNotificationsEnabled = on
        schedulePersist()
    }

    func setHideFromScreenCapture(_ on: Bool) {
        hideFromScreenCapture = on
        schedulePersist()
    }

    func setShowSpendInMenuBar(_ on: Bool) {
        showSpendInMenuBar = on
        schedulePersist()
    }

    /// Estimated spend so far today: live sessions' running cost + archived
    /// sessions that started today and are no longer live (a live session's
    /// archived record would double-count, so those are skipped).
    var todaySpendUSD: Double {
        let todayStart = Calendar.current.startOfDay(for: Date())
        let liveKeys = Set(sessions.keys)
        let archived = sessionHistory
            .filter { $0.startedAt >= todayStart && !liveKeys.contains($0.sessionKey) }
            .reduce(0.0) { $0 + $1.costUSD }
        let live = sessions.values.reduce(0.0) { $0 + $1.sessionCostUSD }
        return archived + live
    }

    /// Yesterday's spend aggregated from session history.
    var yesterdaySpend: DailySpendSummary? {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        guard let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart) else { return nil }
        let sessions = sessionHistory.filter { $0.startedAt >= yesterdayStart && $0.startedAt < todayStart }
        guard !sessions.isEmpty else { return nil }
        let cost = sessions.reduce(0.0) { $0 + $1.costUSD }
        let tokens = sessions.reduce(0) { $0 + $1.contextTokens }
        let topProject = Dictionary(grouping: sessions, by: { ($0.project as NSString).lastPathComponent })
            .max(by: { $0.value.count < $1.value.count })?.key ?? ""
        return DailySpendSummary(costUSD: cost, sessionCount: sessions.count,
                                 topProject: topProject, totalTokens: tokens)
    }

    /// Show a one-time notch card when the daily update poll finds a newer
    /// release. Once per version — ignoring an update stays ignored until the
    /// next one ships. (The manual "Check for Updates…" flow shows an alert
    /// instead; this is only for the background poll most users rely on.)
    func showUpdateCard(version: String) {
        guard lastUpdateCardVersion != version else { return }
        lastUpdateCardVersion = version
        schedulePersist()
        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: String(format: L("Update available: v%@", comment: "Notch card title. %@ is the new version number"), version),
            detail: TerminalAutomator.canSelfUpdate
                ? String(format: L("You're on v%@. Update takes a few seconds.", comment: "Notch card body. %@ is the installed version"), UpdateChecker.shared.currentVersion)
                : String(format: L("You're on v%@. Download it from the menu bar icon.", comment: "Notch card body when the bundled updater is missing. %@ is the installed version"), UpdateChecker.shared.currentVersion),
            toolName: "Update",
            source: "ClaudeNotch",
            cwd: "",
            resolver: { _, _ in }
        ))
    }

    /// Fire the daily spend digest notification if enabled and not yet shown today.
    func fireDigestIfNeeded() {
        guard digestNotificationsEnabled, shouldShowDigest,
              let spend = yesterdaySpend else { return }
        permissionMirror?.sendDigest(spend)
        markDigestShown()
    }

    /// Fire a once-a-week roundup card if the daily digest is enabled and this
    /// week hasn't been shown yet. Uses in-memory data only (weekly cost map and
    /// recent session history), and goes through the normal notification card so
    /// it needs no new mirror plumbing. Costs are API-equivalent estimates.
    func fireWeeklyDigestIfNeeded() {
        guard digestNotificationsEnabled else { return }
        let key = Self.weekKey(Date())
        guard lastWeeklyDigestDate != key else { return }

        let cost = weekCostByProject.values.reduce(0, +)
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        let sessions = sessionHistory.filter { $0.startedAt >= weekAgo }.count
            + sessions.count   // include live sessions this week
        guard cost > 0 || sessions > 0 else { return }   // nothing to report

        let topCwd = weekCostByProject.max { $0.value < $1.value }?.key
        let top = topCwd.map { ($0 as NSString).lastPathComponent } ?? ""
        var detail = "\(sessions) session\(sessions == 1 ? "" : "s") this week"
        if cost > 0 { detail += " · ~\(ClaudeUsageReader.fmtMoney(cost)) API-equiv" }
        if !top.isEmpty { detail += " · top: \(top)" }

        lastWeeklyDigestDate = key
        schedulePersist()
        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: "Your week in Claude Code",
            detail: detail,
            toolName: "Digest",
            source: "ClaudeNotch",
            cwd: "",
            resolver: { _, _ in }
        ))
    }

    // MARK: - Cost budgets

    func setSessionCostCap(_ usd: Double) {
        sessionCostCap = max(0, usd)
        sessionWarnLevel.removeAll()   // re-arm against the new cap
        schedulePersist()
        // Evaluate spend right now — don't wait for the next hook. Covers
        // "I set a cap and I'm already over it."
        guard sessionCostCap > 0 else { return }
        // Check every known session, plus the current mirror as a fallback.
        var checked = false
        for s in sessions.values where s.sessionCostUSD > 0 {
            checked = true
            let level = Self.budgetLevel(cost: s.sessionCostUSD, cap: sessionCostCap)
            if level > (sessionWarnLevel[s.id] ?? 0) {
                sessionWarnLevel[s.id] = level
                warnBudget(scope: "session", level: level, cost: s.sessionCostUSD, cap: sessionCostCap)
            }
        }
        if !checked, currentCostUSD > 0 {
            let level = Self.budgetLevel(cost: currentCostUSD, cap: sessionCostCap)
            if level > 0 { warnBudget(scope: "session", level: level, cost: currentCostUSD, cap: sessionCostCap) }
        }
    }

    func recompute() {
        let next: NotchMode
        if isHistoryOpen {
            next = .history
        } else if isResponseDetailOpen {
            next = .responseDetail
        } else if isComposing {
            next = .compose
        } else if let q = questionQueue.first {
            next = .question(q)
        } else if let p = permissionQueue.first {
            next = .permission(p)
        } else if let c = completedQueue.first {
            next = .completed(c)
        } else if let info = autoInfo {
            next = .autoInfo(info)
        } else if let exp = thinkingExpiresAt, exp > Date() {
            next = .thinking(label: thinkingLabel)
        } else {
            next = .idle
        }
        if next != mode {
            mode = next
            // Announce the card that is actually on screen, not the one that was
            // queued — a card waiting behind another must not be spoken early.
            announce(next)
        }
        updateReAlertTimer()
    }
}
