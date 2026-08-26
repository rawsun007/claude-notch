import Foundation

// MARK: - An instruction file long enough to be skimmed

extension AppState {

    /// Say once, per project, when its CLAUDE.md is too long or shouts too much.
    ///
    /// Keyed on the directory, like the missing/stale advice next to it: the
    /// answer is a property of the project, not of the session that happened to
    /// open it. Gated behind the same nudge switch, and behind the same
    /// tool-call floor, so a scratch session that opens a file and leaves does
    /// not get opinions about the repo.
    func adviseInstructionsBloatIfNeeded(sessionId: String, cwd: String = "") {
        guard compactAdviceEnabled else { return }
        let key = sessionKey(sessionId: sessionId, cwd: cwd)
        guard let session = sessions[key], !session.cwd.isEmpty else { return }
        guard session.toolCallCount >= ProjectInstructions.toolCallsBeforeAdvising else { return }
        guard !instructionBloatAdvised.contains(session.cwd) else { return }

        // Only a file that exists and is current: a missing or stale one is
        // already somebody else's card, and two cards about one file is noise.
        guard case .current(let path) = ProjectInstructions.status(cwd: session.cwd),
              let finding = InstructionsBloat.read(path: path),
              finding.worthSaying
        else { return }

        instructionBloatAdvised.insert(session.cwd)
        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: InstructionsBloat.cardTitle(finding),
            detail: InstructionsBloat.cardDetail(finding),
            toolName: "Instructions",
            source: "ClaudeNotch",
            cwd: session.cwd,
            resolver: { _, _ in }))
    }
}
