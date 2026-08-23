import Foundation

// MARK: - A session doing the same thing over and over

extension AppState {

    /// Count this tool call against the ones the session has already made, and
    /// say so at the two thresholds `ToolRepeat` speaks at.
    ///
    /// Called for every tool call, so it stays cheap: one dictionary bump and a
    /// comparison. `ToolRepeat` decides what counts as the same call and when
    /// it is worth saying; this handles which session and putting it on screen.
    func noteToolRepeat(tool: String, input: [String: Any], sessionId: String, cwd: String = "") {
        guard runawayAlertsEnabled else { return }
        let signature = ToolRepeat.signature(tool: tool, input: input)
        guard !signature.isEmpty else { return }

        let key = sessionKey(sessionId: sessionId, cwd: cwd.isEmpty ? currentCwd : cwd)
        let mark = "\(key)|\(signature)"

        // Evicting wholesale rather than by age: the counts are a heuristic for
        // one session's behaviour, not a record, and a cleared table costs at
        // worst one late card rather than a wrong one.
        if toolRepeatCounts[mark] == nil, toolRepeatCounts.count >= AppState.toolRepeatCountsCap {
            toolRepeatCounts.removeAll()
        }
        let count = (toolRepeatCounts[mark] ?? 0) + 1
        toolRepeatCounts[mark] = count

        guard ToolRepeat.worthAnnouncing(count: count) else { return }

        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: ToolRepeat.cardTitle(count: count, tool: tool),
            detail: ToolRepeat.cardDetail(count: count, preview: ToolRepeat.preview(signature)),
            toolName: "Loop",
            source: "ClaudeNotch",
            cwd: sessions[key]?.cwd ?? currentCwd,
            resolver: { _, _ in }))
    }

    /// Forget a session's counts when it ends, so a long-lived app does not
    /// carry a finished session's tallies into the next one.
    func clearToolRepeats(sessionId: String, cwd: String = "") {
        let prefix = "\(sessionKey(sessionId: sessionId, cwd: cwd.isEmpty ? currentCwd : cwd))|"
        for key in toolRepeatCounts.keys where key.hasPrefix(prefix) {
            toolRepeatCounts.removeValue(forKey: key)
        }
    }
}
