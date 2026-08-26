import Foundation

// MARK: - A session that changed code and never checked it

extension AppState {

    /// Count an edit, or note that the session ran something that could fail.
    /// Called for every tool call, so it stays to two comparisons.
    func noteVerificationSignal(tool: String, input: [String: Any],
                                sessionId: String, cwd: String = "") {
        let isEdit = VerificationNudge.isEdit(tool: tool)
        let isCheck = VerificationNudge.isVerification(tool: tool, input: input)
        guard isEdit || isCheck else { return }
        upsertSession(id: sessionId, cwd: cwd.isEmpty ? currentCwd : cwd) { s in
            if isEdit { s.editCount += 1 }
            if isCheck { s.ranVerification = true }
        }
    }

    /// At the end of a turn, say so once if the session never checked itself.
    ///
    /// Once per session, not once per turn: the same session carrying on after
    /// being told is not news again, and a card at the end of every turn is how
    /// this gets switched off. Gated on the same nudge setting as the other
    /// advice cards, because it is the same question, "should this app offer
    /// advice".
    func adviseVerificationIfNeeded(sessionId: String, cwd: String = "") {
        guard compactAdviceEnabled else { return }
        let key = sessionKey(sessionId: sessionId, cwd: cwd.isEmpty ? currentCwd : cwd)
        guard let session = sessions[key], !session.verificationAdvised else { return }
        guard VerificationNudge.worthAdvising(edits: session.editCount,
                                              verified: session.ranVerification) else { return }

        upsertSession(id: sessionId, cwd: session.cwd) { $0.verificationAdvised = true }
        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: VerificationNudge.cardTitle(edits: session.editCount),
            detail: VerificationNudge.cardDetail(),
            toolName: "Verify",
            source: "ClaudeNotch",
            cwd: session.cwd,
            resolver: { _, _ in }))
    }
}
