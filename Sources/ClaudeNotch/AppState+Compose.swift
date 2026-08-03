import Foundation
import AppKit

// Composing a message to a session, and the response detail card.

extension AppState {
    /// Open the composer. `project` (a cwd) means "send by opening a new
    /// terminal in that folder running claude"; nil means "type into the
    /// currently active terminal".
    func beginCompose(project: String? = nil) {
        composeText = ""
        composeError = nil
        composePurpose = .message
        composeContextLabel = nil
        composeProjectCwd = project
        // Resolve the active-terminal target NOW, before we become key —
        // otherwise frontmost might briefly become ClaudeNotch.
        composeTarget = pickComposeTarget()
        isComposing = true
        recompute()
    }

    /// Open the composer pointed at a finished session, so the user can reply
    /// without alt-tabbing. Types into the terminal that ran the session when
    /// we know it; otherwise opens a fresh terminal in the project folder.
    func beginReply(to task: CompletedTask) {
        // Drop the completed card we're replying to so it doesn't pop back up
        // when the composer closes.
        completedQueue.removeAll { $0.id == task.id }
        composeText = ""
        composeError = nil
        composePurpose = .message
        let project = (task.cwd as NSString).lastPathComponent
        composeContextLabel = project.isEmpty ? nil : project
        if let bid = task.originatorBundleID, !bid.isEmpty,
           !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
            composeProjectCwd = nil
            composeTarget = bid
        } else if !task.cwd.isEmpty {
            composeProjectCwd = task.cwd
            composeTarget = pickComposeTarget()
        } else {
            composeProjectCwd = nil
            composeTarget = pickComposeTarget()
        }
        isComposing = true
        recompute()
    }

    /// Open the composer to deny a held permission with a note. Reuses the
    /// compose editor (key window + focus + ⌘↩/⎋ handling) instead of trying to
    /// host a text field inside the always-non-key permission card.
    func beginDenyReason(for req: PermissionRequest) {
        composeText = ""
        composeError = nil
        composeProjectCwd = nil
        composeTarget = nil
        composeContextLabel = nil
        composePurpose = .denyReason(req)
        isComposing = true
        recompute()
    }

    func setComposeProject(_ cwd: String?) {
        composeProjectCwd = cwd
        composeError = nil
    }

    func sendCompose() {
        // Deny-with-reason mode: resolve the held permission instead of typing
        // into a terminal. An empty note just denies (same as a plain deny).
        if case .denyReason(let req) = composePurpose {
            let note = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
            isComposing = false
            composePurpose = .message
            composeText = ""
            composeError = nil
            resolvePermission(req, decision: .deny, reason: note.isEmpty ? nil : note)
            return
        }

        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { cancelCompose(); return }

        // Project mode: open a fresh terminal in that folder with the message
        // as Claude's first prompt. No Accessibility needed.
        if let cwd = composeProjectCwd, !cwd.isEmpty {
            TerminalAutomator.startClaude(in: cwd, message: text)
            play(.messageSent)
            cancelCompose()
            return
        }

        // Active-terminal mode: type into the running session via keystrokes.
        let target = composeTarget ?? pickComposeTarget()
        guard let bid = target else {
            composeError = "No terminal found. Pick a project below, or open a Claude session first."
            return
        }
        if !TerminalAutomator.isAccessibilityTrusted {
            // Typing into a terminal needs Accessibility. Don't fail silently —
            // pop the system prompt + open Settings, and keep the composer open
            // (with the text) so the user can grant it and hit Send again.
            promptAccessibility()
            composeError = "ClaudeNotch needs Accessibility to type into your terminal. I opened System Settings. Enable ClaudeNotch there, then press Send again. (Or pick a project above to open a fresh terminal instead.)"
            return
        }
        TerminalAutomator.sendText(text, toBundleID: bid)
        play(.messageSent)
        cancelCompose()
    }

    /// Send a reply typed into a completion notification's text field. Same
    /// routing as beginReply: type into the terminal that ran the session when
    /// it's still running, else open a fresh terminal in the project folder.
    func sendNotificationReply(_ text: String, cwd: String, originatorBundleID: String?) {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        if let bid = originatorBundleID, !bid.isEmpty,
           !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty,
           TerminalAutomator.isAccessibilityTrusted {
            TerminalAutomator.sendText(msg, toBundleID: bid)
            play(.messageSent)
        } else if !cwd.isEmpty {
            TerminalAutomator.startClaude(in: cwd, message: msg)
            play(.messageSent)
        }
    }

    /// Pop the macOS Accessibility prompt and jump to the right Settings pane.
    func promptAccessibility() {
        TerminalAutomator.requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func cancelCompose() {
        let target = composeTarget
        let wasDeny = composePurpose != .message
        composeText = ""
        isComposing = false
        composePurpose = .message
        composeError = nil
        composeTarget = nil
        composeProjectCwd = nil
        composeContextLabel = nil
        recompute()
        // Cancelling a deny-reason returns to the still-queued permission card,
        // which is interactive — don't hand the keyboard back to the terminal.
        if !wasDeny { returnKeyboardToTerminal(preferred: target) }
    }

    private func pickComposeTarget() -> String? {
        // 1. App that was frontmost just before us (NSWorkspace tracker)
        if let bid = frontmost.lastNonSelf?.bundleIdentifier, !bid.isEmpty {
            return bid
        }
        // 2. Last bundle that fired a hook
        if let bid = lastOriginatorBundleID { return bid }
        // 3. Best-guess: any running terminal
        let candidates = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.microsoft.VSCode",
            "com.anthropic.claudefordesktop",
            "co.zeit.hyper",
            "io.alacritty"
        ]
        for b in candidates {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: b).isEmpty {
                return b
            }
        }
        return nil
    }

    // MARK: - Response detail

    func showResponseDetail() {
        guard !fullClaudeResponse.isEmpty else { return }
        detailResponseText = fullClaudeResponse
        detailProject = currentProject
        isResponseDetailOpen = true
        recompute()
    }

    /// Show a specific session's last reply (from tapping its row in the
    /// multi-session list). No-op if that session hasn't replied yet.
    func showSessionResponse(_ session: LiveSession) {
        guard !session.fullResponse.isEmpty else { return }
        detailResponseText = session.fullResponse
        detailProject = session.project
        isResponseDetailOpen = true
        recompute()
    }

    func closeResponseDetail() {
        isResponseDetailOpen = false
        recompute()
        returnToPreviousApp()
    }

    /// Copy the reply currently shown in the detail card (⌘C / Copy button).
    func copyDetailResponse() {
        guard !detailResponseText.isEmpty else { return }
        NSPasteboard.copyString(detailResponseText)
    }

    // MARK: - History drawer

    func openHistory() {
        guard !history.isEmpty else { return }
        isHistoryOpen = true
        recompute()
        refreshProjectSpend()
        refreshBackgroundAgents()
    }
}
