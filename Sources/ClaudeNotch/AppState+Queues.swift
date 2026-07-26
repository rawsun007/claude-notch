import Foundation
import AppKit

// The pending permission, question, and completed queues, and how they resolve.

extension AppState {
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
            playAlert(toolName: req.toolName)
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
        playAlert(toolName: req.toolName)
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
            playSound("Pop")
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
        playChime()
        recompute()
        // Fire a native banner if the user has switched away from the notch.
        if completionNotificationsEnabled, !NSApp.isActive {
            let project = (task.cwd as NSString).lastPathComponent
            permissionMirror?.sendCompletion(project: project, snippet: task.detail,
                                             cwd: task.cwd,
                                             originatorBundleID: task.originatorBundleID)
        }
    }

    func enqueueQuestion(_ req: QuestionRequest) {
        questionQueue.append(req)
        playAlert()
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
            playSound("Tink")
        } else {
            playSound("Pop")
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
                break
            case .tool:
                allowRules.insert(AllowRule(tool: req.toolName, commandRegex: nil))
                schedulePersist()
            case .exactCommand:
                let escaped = NSRegularExpression.escapedPattern(for: req.detail)
                allowRules.insert(AllowRule(tool: req.toolName, commandRegex: "^\(escaped)$"))
                schedulePersist()
            }
        }
        // Grouped requests fold N tool calls into one card — count each one so
        // the decision tally matches the tool tally (recorded per request).
        if req.kind == .toolUse, req.source != "Demo" {
            for _ in 0..<max(1, req.groupCount) { recordDecision(decision, auto: false) }
        }
        req.resolver(decision, reason)
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
        permissionQueue = remaining
        playFeedback(for: decision)
        recompute()
        returnKeyboardToTerminal(preferred: originator)
    }

    private func playFeedback(for decision: PermissionDecision) {
        switch decision {
        case .allow: playSound("Tink")    // small success "tick"
        case .deny:  playSound("Pop")     // soft dismiss
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
