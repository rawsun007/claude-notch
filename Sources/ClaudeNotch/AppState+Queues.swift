import Foundation
import AppKit

// The pending permission, question, and completed queues, and how they resolve.

extension AppState {
    /// Speak a card to VoiceOver as it appears. Nothing here moves focus: the
    /// notch stays a non-activating panel so the keyboard remains wherever the
    /// user left it, which means an announcement is the only cue a VoiceOver
    /// user gets that Claude is blocked and waiting.
    func announce(_ mode: NotchMode) {
        guard Announcer.isVoiceOverRunning else { return }
        switch mode {
        case .permission(let req):
            Announcer.say(Announcer.announcement(for: req, pending: permissionQueue.count))
        case .question(let q):
            Announcer.say(Announcer.announcement(for: q))
        case .completed(let task):
            // Not blocking anything, so it waits its turn rather than cutting in.
            // A contradiction is the one thing here worth interrupting for: it
            // is the case where the spoken "task finished" is itself misleading.
            var line = "Task finished. \(task.title)"
            var priority = NSAccessibilityPriorityLevel.medium
            if let verdict = task.audit.message {
                line += ". \(verdict)"
                if case .contradicted = task.audit { priority = .high }
            }
            Announcer.say(line, priority: priority)
        case .autoInfo(let req):
            // A sighted user sees a card saying something was allowed on their
            // behalf. Saying nothing here means a VoiceOver user is the only
            // one who never learns an auto-approve rule fired, which is exactly
            // the thing they would want to audit. Low priority: it is done,
            // nothing is waiting, and it must not cut across a blocking card.
            Announcer.say("Auto-approved. \(PermissionCard.spokenAsk(for: req))",
                          priority: .low)
        case .compose:
            // The composer takes the keyboard, so unlike every other card the
            // user needs to know where their typing is about to go.
            if case .denyReason = composePurpose {
                Announcer.say("Deny with a reason. Type the reason for Claude, then Command Return to send.")
            } else {
                Announcer.say("Message composer. Type a message, then Command Return to send it to your session.")
            }
        case .idle, .history, .responseDetail, .thinking:
            break
        }
    }

    /// Judge the most recent finished task for a session, once its closing
    /// message has landed.
    ///
    /// The card is queued at Stop time and audited a beat later, so this has to
    /// find the card again and update it in place. CompletedTask is a class
    /// compared by id, so changing its verdict does not alter `mode` and
    /// nothing would redraw on its own: the change has to be announced.
    func auditLatestCompleted(sessionId: String, cwd: String) {
        guard completionAuditEnabled else { return }
        let match = completedQueue.last { $0.cwd == cwd } ?? completedQueue.last
        guard let task = match else { return }
        let verdict = CompletionAudit.audit(completionEvidence(sessionId: sessionId, cwd: cwd))
        guard verdict != task.audit else { return }
        objectWillChange.send()
        task.audit = verdict
        // The card may already be on screen and sized for no banner.
        recompute()
        if case .completed(let shown) = mode, shown.id == task.id,
           let line = verdict.message {
            Announcer.say(line, priority: {
                if case .contradicted = verdict { return .high }
                return .medium
            }())
        }
    }

    /// `bypassRules: true` skips the always-allow and auto-approve
    /// short-circuits so the card is always shown — used by the menu-bar demos,
    /// which must demonstrate the UI even if the user has Bash always-allowed
    /// or Auto-Approve turned on.
    func enqueuePermission(_ req: PermissionRequest, bypassRules: Bool = false) {
        // Budget hard-stop: when enforcement is on and the relevant cap is
        // already exceeded, force a decision before any allow-rule or
        // auto-approve can spend past the cap. The card shows Deny / Allow once
        // / Raise cap.
        if !bypassRules, req.kind == .toolUse, enforceBudget,
           let block = budgetBlock(for: req) {
            req.budgetBlock = block
            if req.source != "Demo" {
                recordToolRequested(req.toolName, dangerousShown: req.isDangerous)
            }
            permissionQueue.append(req)
            play(.permission, toolName: req.toolName)
            if mirrorToNotificationCenter { permissionMirror?.mirror(req) }
            recompute()
            return
        }

        if !bypassRules, !req.isDangerous, let matched = allowRules.first(where: { $0.matches(req) }) {
            // Auto-allowed by a rule the user installed earlier. Still
            // log it to history so they can see what we approved silently.
            // Dangerous commands are exempt — even a tool-wide always-allow
            // rule must not skip the hold-to-confirm / Touch ID guardrail.
            appendHistory(HistoryEntry(
                timestamp: Date(),
                kind: req.kind == .notification ? .notification : .permission,
                toolName: req.toolName,
                title: req.title,
                detail: req.detail + "  (auto-allowed by rule: \(matched.displayLabel))",
                project: (req.cwd as NSString).lastPathComponent,
                outcome: req.kind == .notification ? .info : .allowed
            ))
            if req.kind == .toolUse {
                recordToolRequested(req.toolName, dangerousShown: false)
                recordDecision(.allow, auto: true)
            }
            req.resolver(.allow, nil)
            return
        }

        // Auto-approve mode: allow immediately and show a brief, button-less
        // "live activity" card of what's changing. Dangerous commands are
        // exempt — they still require an explicit hold-to-confirm.
        if !bypassRules, autoApprove, req.kind == .toolUse, !req.isDangerous {
            req.resolver(.allow, nil)
            appendHistory(HistoryEntry(
                timestamp: Date(),
                kind: .permission,
                toolName: req.toolName,
                title: req.title,
                detail: req.detail,
                project: (req.cwd as NSString).lastPathComponent,
                outcome: .allowed
            ))
            recordToolRequested(req.toolName, dangerousShown: false)
            recordDecision(.allow, auto: true)
            showAutoInfo(req)
            return
        }

        if req.kind == .toolUse, req.source != "Demo" {
            recordToolRequested(req.toolName, dangerousShown: req.isDangerous)
        }

        // Snooze: log notifications quietly, skip showing them.
        if req.kind == .notification, isSnoozed {
            appendHistory(HistoryEntry(
                timestamp: Date(),
                kind: .notification,
                toolName: req.toolName,
                title: req.title,
                detail: req.detail + "  (snoozed)",
                project: (req.cwd as NSString).lastPathComponent,
                outcome: .info
            ))
            return
        }

        // Group similar tool requests: if the last queued item is the same tool
        // with the same input and arrived in the last 5 seconds, fold this
        // request into it. The merged item's resolver fires every callback.
        if req.kind == .toolUse,
           let last = permissionQueue.last,
           last.kind == .toolUse,
           last.toolName == req.toolName,
           (last.originalDetail ?? last.detail) == req.detail,
           Date().timeIntervalSince(last.receivedAt) < 5 {
            let prev = last.resolver
            let newReq = PermissionRequest(
                kind: last.kind,
                title: last.title,
                detail: "(×\(last.groupCount + 1)) \(last.originalDetail ?? last.detail)",
                toolName: last.toolName,
                source: last.source,
                cwd: last.cwd,
                originatorBundleID: last.originatorBundleID,
                preview: last.preview,
                dangerReasons: last.dangerReasons,
                resolver: { decision, reason in
                    prev(decision, reason)
                    req.resolver(decision, reason)
                }
            )
            newReq.groupCount = last.groupCount + 1
            newReq.originalDetail = last.originalDetail ?? last.detail
            permissionQueue[permissionQueue.count - 1] = newReq
            // Re-point the native notification at the merged request so its
            // count stays accurate and its action resolves the live item.
            if mirrorToNotificationCenter {
                permissionMirror?.withdraw(last.id)
                permissionMirror?.mirror(newReq)
            }
            recompute()
            return
        }

        permissionQueue.append(req)
        // Record notifications immediately — they don't have an Allow/Deny.
        if req.kind == .notification {
            appendHistory(HistoryEntry(
                timestamp: Date(),
                kind: .notification,
                toolName: req.toolName,
                title: req.title,
                detail: req.detail,
                project: (req.cwd as NSString).lastPathComponent,
                outcome: .info
            ))
        }
        play(.permission, toolName: req.toolName)
        // Mirror blocking cards to native notifications (lock screen / other
        // Space; auto-suppressed during Focus). Notifications aren't blocking,
        // so they don't need a remote-actionable surface.
        if req.kind == .toolUse, mirrorToNotificationCenter {
            permissionMirror?.mirror(req)
        }
        recompute()
    }

    /// Show a transient, button-less card of an auto-approved action. A new
    /// one replaces the current (live-activity style); clears after a few
    /// seconds, or immediately when the user presses Esc.
    private func showAutoInfo(_ req: PermissionRequest) {
        // Soft, distinct "Pop" — and debounced, so a burst of auto-approved
        // edits doesn't machine-gun the sound (which read as an error).
        if Date().timeIntervalSince(lastAutoSoundAt) > 0.8 {
            play(.autoApproved)
            lastAutoSoundAt = Date()
        }
        autoInfo = req
        recompute()
        autoInfoTimer?.invalidate()
        autoInfoTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.autoInfo = nil
                self.recompute()
            }
        }
    }

    /// Demo entry point: show the auto-approve "live activity" card exactly as
    /// it appears when Auto-Approve silently allows a tool call.
    func demoAutoApprove(_ req: PermissionRequest) {
        showAutoInfo(req)
    }

    /// An external agent (Codex, etc.) is starting a tool. That agent owns its
    /// own approval, so we never gate; we pop a brief no-button info card so the
    /// notch shows what is running. When `needsApproval` is true (the agent is
    /// about to prompt for a risky command), the card is framed as a heads-up so
    /// the user knows to go approve it in the agent. Also records session
    /// activity.
    func noteExternalActivity(tool: String, detail: String, needsApproval: Bool = false,
                              dangerReasons: [String] = [], sessionId: String = "") {
        noteActivity(detail.isEmpty ? tool : "\(tool): \(String(detail.prefix(80)))", sessionId: sessionId)
        let title = needsApproval ? "Codex needs your approval" : tool
        let body: String
        if needsApproval {
            body = detail.isEmpty ? "Approve it in Codex" : "\(detail)\n\nApprove or deny it in Codex."
        } else {
            body = detail.isEmpty ? "Running" : detail
        }
        let req = PermissionRequest(
            kind: needsApproval ? .notification : .toolUse,
            title: title,
            detail: body,
            toolName: tool,
            source: "Codex",
            cwd: currentCwd,
            dangerReasons: needsApproval ? dangerReasons : [],
            resolver: { _, _ in })
        showAutoInfo(req)
    }

    func dismissAutoInfo() {
        guard autoInfo != nil else { return }
        autoInfoTimer?.invalidate()
        autoInfoTimer = nil
        autoInfo = nil
        recompute()
    }

    func enqueueCompleted(_ task: CompletedTask) {
        claudeActionStatus = "done"
        if isSnoozed {
            appendHistory(HistoryEntry(
                timestamp: Date(),
                kind: .completed,
                toolName: "Stop",
                title: task.title,
                detail: task.detail + "  (snoozed)",
                project: (task.cwd as NSString).lastPathComponent,
                outcome: .info
            ))
            return
        }
        completedQueue.append(task)
        appendHistory(HistoryEntry(
            timestamp: Date(),
            kind: .completed,
            toolName: "Stop",
            title: task.title,
            detail: task.detail,
            project: (task.cwd as NSString).lastPathComponent,
            outcome: .info
        ))
        // A chime to an empty room is just noise for whoever else is in it. The
        // card still queues and waits; only the sound is held, and it is played
        // once on return rather than once per task.
        if userIsAway {
            noteCompletedWhileAway()
        } else {
            playChime()
        }
        recompute()
        // Fire a native banner if the user has switched away from the notch.
        if completionNotificationsEnabled, !NSApp.isActive {
            let project = (task.cwd as NSString).lastPathComponent
            permissionMirror?.sendCompletion(project: project, snippet: task.detail,
                                             agentName: task.entityName,
                                             cwd: task.cwd,
                                             originatorBundleID: task.originatorBundleID)
        }
    }

    func enqueueQuestion(_ req: QuestionRequest) {
        questionQueue.append(req)
        play(.question)
        recompute()
    }

    func resolveCurrentQuestion(_ answers: [[String]]?) {
        guard !questionQueue.isEmpty else { return }
        let first = questionQueue.removeFirst()
        first.resolver(answers)
        let title: String
        let outcome: HistoryEntry.Outcome
        if let answers, !answers.isEmpty {
            outcome = .answered(count: answers.flatMap { $0 }.count)
            title = first.questions.first?.text ?? "Question"
            if first.source != "Demo" {
                stats.questionsAnswered += 1
                markActiveToday()
                schedulePersist()
            }
        } else {
            outcome = .dismissed
            title = first.questions.first?.text ?? "Question"
        }
        appendHistory(HistoryEntry(
            timestamp: Date(),
            kind: .question,
            toolName: "AskUserQuestion",
            title: title,
            detail: first.source,
            project: (first.cwd as NSString).lastPathComponent,
            outcome: outcome
        ))
        if answers != nil {
            play(.approved)
        } else {
            play(.dismissed)
        }
        recompute()
        returnKeyboardToTerminal(preferred: first.originatorBundleID)
    }

    func resolveCurrentPermission(_ decision: PermissionDecision, alwaysAllow: AllowScope = .none, reason: String? = nil) {
        guard let first = permissionQueue.first else { return }
        resolvePermission(first, decision: decision, alwaysAllow: alwaysAllow, reason: reason)
    }

    /// Resolve a specific queued request (not necessarily the head). Used by the
    /// deny-with-reason flow, which resolves the request the composer was opened
    /// for, and by resolveCurrentPermission for the common head case.
    func resolvePermission(_ req: PermissionRequest, decision: PermissionDecision, alwaysAllow: AllowScope = .none, reason: String? = nil) {
        guard let idx = permissionQueue.firstIndex(where: { $0.id == req.id }) else { return }
        permissionQueue.remove(at: idx)
        // Pull any mirrored notification — whether resolved here or from its own
        // action (idempotent: a no-op if nothing was posted).
        permissionMirror?.withdraw(req.id)
        if decision == .allow {
            switch alwaysAllow {
            case .none:
                noteManualApproval(req)
            case .tool:
                allowRules.insert(AllowRule(tool: req.toolName, commandRegex: nil))
                clearApprovalCount(for: req)
                schedulePersist()
            case .exactCommand:
                let escaped = NSRegularExpression.escapedPattern(for: req.detail)
                allowRules.insert(AllowRule(tool: req.toolName, commandRegex: "^\(escaped)$"))
                clearApprovalCount(for: req)
                schedulePersist()
            }
        }
        // Grouped requests fold N tool calls into one card — count each one so
        // the decision tally matches the tool tally (recorded per request).
        if req.kind == .toolUse, req.source != "Demo" {
            for _ in 0..<max(1, req.groupCount) { recordDecision(decision, auto: false) }
        }
        req.resolver(decision, reason)
        // Confirm what just happened. Resolving usually lands on idle, which
        // announces nothing, so without this a VoiceOver user presses Return
        // and hears silence — no way to tell allow from deny from a missed key.
        if req.kind == .toolUse {
            let verb: String
            switch decision {
            case .allow: verb = alwaysAllow == .none ? "Allowed" : "Always allowed"
            case .deny:  verb = "Denied"
            case .ask:   verb = "Dismissed"
            }
            Announcer.say("\(verb). \(req.title)", priority: .medium)
        }
        // Notifications were already logged at enqueue time.
        if req.kind != .notification {
            let outcome: HistoryEntry.Outcome
            switch decision {
            case .allow: outcome = req.isDangerous ? .dangerous : .allowed
            case .deny:  outcome = .denied
            case .ask:   outcome = .dismissed
            }
            let detail = (reason?.isEmpty == false) ? "\(req.detail)  (reason: \(reason!))" : req.detail
            appendHistory(HistoryEntry(
                timestamp: Date(),
                kind: .permission,
                toolName: req.toolName,
                title: req.title,
                detail: detail,
                project: (req.cwd as NSString).lastPathComponent,
                outcome: outcome
            ))
        }
        playFeedback(for: decision)
        recompute()
        returnKeyboardToTerminal(preferred: req.originatorBundleID)
    }

    /// Resolve EVERY queued permission at once — for the "Claude fired 5 edits
    /// at the same time, I don't want to click 5 times" case. Skips dangerous
    /// ones (those stay queued for an explicit hold-to-confirm).
    func resolveAllPermissions(_ decision: PermissionDecision) {
        let originator = permissionQueue.first?.originatorBundleID
        let count = permissionQueue.count
        var remaining: [PermissionRequest] = []
        for req in permissionQueue {
            if decision == .allow && req.isDangerous {
                remaining.append(req)   // never batch-allow a destructive command
                continue
            }
            if req.kind == .toolUse, req.source != "Demo" {
                for _ in 0..<max(1, req.groupCount) { recordDecision(decision, auto: false) }
            }
            permissionMirror?.withdraw(req.id)
            req.resolver(decision, nil)
            if req.kind != .notification {
                appendHistory(HistoryEntry(
                    timestamp: Date(),
                    kind: .permission,
                    toolName: req.toolName,
                    title: req.title,
                    detail: req.detail,
                    project: (req.cwd as NSString).lastPathComponent,
                    outcome: decision == .allow ? .allowed : (decision == .deny ? .denied : .dismissed)
                ))
            }
        }
        let settled = count - remaining.count
        permissionQueue = remaining
        playFeedback(for: decision)
        // Say how many were settled in one go, and flag anything held back —
        // a destructive request that survives a batch allow is exactly the
        // thing a VoiceOver user must not assume was handled.
        if settled > 0 {
            let verb = decision == .allow ? "Allowed" : (decision == .deny ? "Denied" : "Dismissed")
            var line = "\(verb) \(settled) request\(settled == 1 ? "" : "s")."
            if !remaining.isEmpty {
                line += " \(remaining.count) destructive request\(remaining.count == 1 ? "" : "s") still waiting."
            }
            Announcer.say(line, priority: .medium)
        }
        recompute()
        returnKeyboardToTerminal(preferred: originator)
    }

    private func playFeedback(for decision: PermissionDecision) {
        switch decision {
        case .allow: play(.approved)     // small success "tick"
        case .deny:  play(.dismissed)    // soft dismiss
        case .ask:   break
        }
    }

    func dismissCurrentCompleted() {
        guard !completedQueue.isEmpty else { return }
        let first = completedQueue.removeFirst()
        recompute()
        returnKeyboardToTerminal(preferred: first.originatorBundleID)
    }

    func clearAllowlist() {
        allowRules.removeAll()
        schedulePersist()
    }

    func removeAllowRule(_ rule: AllowRule) {
        allowRules.remove(rule)
        schedulePersist()
    }

    func pingThinking(label: String) {
        thinkingLabel = label
        claudeActionStatus = "thinking"
        thinkingExpiresAt = Date().addingTimeInterval(8)
        recompute()
        thinkingTask?.cancel()
        thinkingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_500_000_000)
            guard let self else { return }
            await MainActor.run {
                if let exp = self.thinkingExpiresAt, exp <= Date() {
                    self.thinkingExpiresAt = nil
                    self.recompute()
                }
            }
        }
    }
}
