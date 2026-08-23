import Foundation

// MARK: - When the model changes under a session

extension AppState {

    /// Compare the model a status line reports against the one the session is
    /// already on, and say so once if it dropped a tier.
    ///
    /// Must be called *before* the session's model is overwritten, since the
    /// old value is the entire signal. `ModelDrift` decides what counts; this
    /// only handles which session, whether it has been said already, and
    /// putting it on screen.
    func noteModelChange(sessionId: String, cwd: String, model: String) {
        guard modelChangeAlertsEnabled, !model.isEmpty else { return }
        let key = sessionKey(sessionId: sessionId, cwd: cwd)
        guard let session = sessions[key] else { return }
        guard let change = ModelDrift.change(from: session.model, to: model) else { return }

        let mark = "\(key)|\(change.from)>\(change.to)"
        guard !modelDriftAnnounced.contains(mark) else { return }
        if modelDriftAnnounced.count >= AppState.modelDriftAnnouncedCap {
            modelDriftAnnounced.removeAll()
        }
        modelDriftAnnounced.insert(mark)

        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: ModelDrift.cardTitle(change),
            detail: ModelDrift.cardDetail(change),
            toolName: "Model",
            source: "ClaudeNotch",
            cwd: session.cwd,
            resolver: { _, _ in }))
    }
}
