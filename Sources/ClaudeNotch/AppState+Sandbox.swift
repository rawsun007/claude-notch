import Foundation

// Sandbox posture per session: is this agent fenced in, and how tightly.
//
// The reading itself is in SandboxReader (pure, testable). This is the part
// that decides WHEN to read: settings files change rarely, hooks arrive every
// second, so the answer is cached per directory and re-read on a slow cadence.

extension AppState {

    /// How long a cached read stays good. Settings files change when a human
    /// edits them, so a minute of staleness costs nothing; re-reading four
    /// files per hook would cost real I/O on every keystroke of an active
    /// session.
    static let sandboxCacheTTL: TimeInterval = 60

    /// Refresh (from cache when fresh) the sandbox status for a session's cwd
    /// and store it on the session.
    func refreshSandbox(cwd: String, sessionId: String, model: String = "") {
        // The caller rarely knows the model (a hook that only carries a cwd),
        // so fall back to whatever the session last reported. An unknown model
        // infers to Claude, which is the right default here too.
        let key0 = !sessionId.isEmpty ? sessionId : cwd
        let resolvedModel = model.isEmpty ? (sessions[key0]?.model ?? "") : model
        let agent = AgentKind.infer(fromModel: resolvedModel)
        let key = "\(agent.rawValue)|\(cwd)"
        let now = Date()

        let status: SandboxReader.Status?
        if let hit = sandboxCache[key], now.timeIntervalSince(hit.readAt) < Self.sandboxCacheTTL {
            status = hit.status
        } else {
            status = Self.readSandbox(cwd: cwd, agent: agent)
            sandboxCache[key] = (status, now)
        }

        upsertSession(id: sessionId, cwd: cwd) { s in
            if s.sandbox != status { s.sandbox = status }
        }
    }

    /// Which reader answers for which agent. Grok has no sandbox contract the
    /// app can read, so it reports nothing rather than borrowing Claude's.
    nonisolated static func readSandbox(cwd: String, agent: AgentKind) -> SandboxReader.Status? {
        switch agent {
        case .claude: return SandboxReader.readClaude(cwd: cwd)
        case .codex:  return SandboxReader.readCodex()
        case .grok:   return nil
        }
    }

    /// The sandbox governing a permission ask. A PermissionRequest carries no
    /// session id, only the directory it fired in, so match on that: every
    /// session in a directory is governed by the same settings files.
    func sandbox(forCwd cwd: String) -> SandboxReader.Status? {
        guard showSandboxBadge else { return nil }
        let wanted = Self.normalizedCwd(cwd)
        guard !wanted.isEmpty else { return nil }
        return sessions.values.first { $0.cwd == wanted && $0.sandbox != nil }?.sandbox
    }

    func setShowSandboxBadge(_ on: Bool) {
        showSandboxBadge = on
        schedulePersist()
    }

    /// The sandbox status to show in the header, which describes the primary
    /// session — the same one the header's meter and permission-mode badge
    /// describe.
    var currentSandbox: SandboxReader.Status? { primarySession?.sandbox }
}
