import Foundation
import AppKit

// Time-based nudges: break reminders, long-run alerts, and the waiting-on-you re-alert.

extension AppState {
    func setBreakRemindersEnabled(_ on: Bool) {
        breakRemindersEnabled = on
        schedulePersist()
    }

    func setLongRunAlertsEnabled(_ on: Bool) {
        longRunAlertsEnabled = on
        schedulePersist()
    }

    /// Called on the stale heartbeat. Fires one alert when the running tool passes
    /// the threshold; the flag is keyed to the run's start, so a new tool call
    /// (which resets `activityStartedAt`) can alert again.
    /// Whether a long-run alert should fire right now. Pure so the timing rule
    /// can be pinned without a clock: fires once when a run passes the threshold,
    /// and not again for the same run (keyed by its start).
    nonisolated static func shouldAlertLongRun(enabled: Bool, working: Bool,
                                               startedAt: Date?, alertedFor: Date?,
                                               now: Date, threshold: TimeInterval) -> Bool {
        guard enabled, working, let started = startedAt else { return false }
        guard alertedFor != started else { return false }
        return now.timeIntervalSince(started) >= threshold
    }

    func checkLongRun() {
        guard Self.shouldAlertLongRun(enabled: longRunAlertsEnabled, working: isClaudeWorking,
                                      startedAt: activityStartedAt, alertedFor: longRunAlertedFor,
                                      now: Date(), threshold: Self.longRunThreshold),
              let started = activityStartedAt else { return }
        let elapsed = Date().timeIntervalSince(started)
        longRunAlertedFor = started
        let minutes = Int(elapsed / 60)
        let req = PermissionRequest(
            kind: .notification,
            title: "Still running — \(minutes)m",
            detail: lastActivity.isEmpty
                ? "This tool call has been going for \(minutes) minutes."
                : "\(lastActivity) has been running for \(minutes) minutes.",
            toolName: "LongRun",
            source: "ClaudeNotch",
            cwd: currentCwd,
            originatorBundleID: nil,
            resolver: { _, _ in }
        )
        enqueuePermission(req)
    }

    /// How long you have been working without a break, in seconds. 0 when you are
    /// on one. Measured from Claude Code's hooks rather than a timer you start:
    /// the app already knows when work is happening.
    var focusStretch: TimeInterval { focus.stretch(now: Date()) }

    /// Called on every hook. Ends the stretch if you have been away, and nudges
    /// once when a stretch gets long.
    func noteFocusActivity() {
        let now = Date()
        focus.noteActivity(at: now)
        guard breakRemindersEnabled, focus.shouldNudge(now: now) else { return }
        let minutes = Int(focus.stretch(now: now) / 60)
        let req = PermissionRequest(
            kind: .notification,
            title: "\(minutes)m without a break",
            detail: "You have been at this for \(minutes) minutes. Claude will still be here.",
            toolName: "Focus",
            source: "ClaudeNotch",
            cwd: currentCwd,
            originatorBundleID: nil,
            resolver: { _, _ in }
        )
        enqueuePermission(req)
    }

    func updateReAlertTimer() {
        let hasPending = permissionQueue.contains { $0.kind == .toolUse } || !questionQueue.isEmpty
        if hasPending, reAlertTimer == nil {
            reAlertTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkReAlert() }
            }
        } else if !hasPending, reAlertTimer != nil {
            reAlertTimer?.invalidate(); reAlertTimer = nil
            reAlertState.removeAll()
        }
    }

    /// True when a request that has waited `reAlertAfter` since it arrived is
    /// also due for its next nudge (never nudged, or last nudge was a full
    /// interval ago) and hasn't used up its nudge budget.
    private func reAlertDue(id: UUID, receivedAt: Date, now: Date) -> Bool {
        guard now.timeIntervalSince(receivedAt) >= Self.reAlertAfter else { return false }
        let s = reAlertState[id]
        guard (s?.count ?? 0) < Self.maxReAlerts else { return false }
        if let last = s?.lastAt, now.timeIntervalSince(last) < Self.reAlertAfter { return false }
        return true
    }

    private func noteReAlert(id: UUID, now: Date) {
        let prior = reAlertState[id]?.count ?? 0
        reAlertState[id] = (prior + 1, now)
    }

    private func checkReAlert() {
        let now = Date()
        for req in permissionQueue where req.kind == .toolUse {
            guard reAlertDue(id: req.id, receivedAt: req.receivedAt, now: now) else { continue }
            noteReAlert(id: req.id, now: now)
            playAlert(toolName: req.toolName)
            if mirrorToNotificationCenter { permissionMirror?.mirror(req) }
            bounceDockForAttention()
            return   // one nudge per tick
        }
        for q in questionQueue {
            guard reAlertDue(id: q.id, receivedAt: q.receivedAt, now: now) else { continue }
            noteReAlert(id: q.id, now: now)
            playAlert()
            bounceDockForAttention()
            return
        }
    }

    /// Ask the OS to draw the user to the app (a critical attention request:
    /// bounces the Dock icon until the app is activated). This is a menu-bar
    /// (LSUIElement) app so there is usually no Dock icon to bounce — the call
    /// is a harmless no-op then, and the replayed sound + re-posted notification
    /// carry the nudge. It still fires for the rare case the app is run with a
    /// Dock presence, and documents the intent in one place.
    private func bounceDockForAttention() {
        NSApp.requestUserAttention(.criticalRequest)
    }

    /// Oldest unanswered blocking request for a session (matched by cwd) —
    /// drives the "waiting Xm" chip on multi-session rows.
    func pendingWaitStart(forCwd cwd: String) -> Date? {
        guard !cwd.isEmpty else { return nil }
        let perm = permissionQueue.first { $0.kind == .toolUse && $0.cwd == cwd }?.receivedAt
        let ques = questionQueue.first { $0.cwd == cwd }?.receivedAt
        switch (perm, ques) {
        case let (p?, q?): return min(p, q)
        case let (p?, nil): return p
        case let (nil, q?): return q
        default: return nil
        }
    }
}
