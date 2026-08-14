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
            guard s.sandbox != status else { return }
            s.sandbox = status
            // Only on a change, and only under the debug flag: this is the one
            // fact in the notch the user cannot check by looking anywhere else,
            // so when the badge looks wrong the log has to be able to say what
            // was read and for which directory.
            DebugLog.append("sandbox", "\(key) -> \(SandboxReader.badge(status)) \(status.map(String.init(describing:)) ?? "none")")
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

    /// The sandbox refused something this session tried to do.
    ///
    /// The badge says a fence exists; this is the fence being hit. Worth a card
    /// rather than a silent counter: a blocked command is why the session is
    /// about to work around something, or give up, and the reason is invisible
    /// in the terminal unless you are reading tool output.
    func noteSandboxViolations(_ items: [SandboxViolationParser.Violation],
                               toolName: String, cwd: String, sessionId: String) {
        guard !items.isEmpty else { return }
        let first = items[0]
        let title = SandboxViolationParser.summary(first)
        let detail = items.count > 1
            ? String(format: L("%d more blocked in the same command", comment: "Sandbox violation card detail. %d is how many further violations there were"),
                     items.count - 1)
            : first.raw

        upsertSession(id: sessionId, cwd: cwd) { s in
            s.sandboxViolations += items.count
        }

        for item in items {
            appendHistory(HistoryEntry(
                timestamp: Date(),
                kind: .notification,
                toolName: toolName.isEmpty ? "Bash" : toolName,
                title: SandboxViolationParser.summary(item),
                detail: item.raw,
                project: (cwd as NSString).lastPathComponent,
                outcome: .denied))
        }

        // Deduped: a retry loop against the same blocked host would otherwise
        // put a card up per attempt.
        let key = "\(first.kind)|\(first.target)|\(first.raw)"
        if key == lastSandboxViolationKey,
           Date().timeIntervalSince(lastSandboxViolationAt) < 20 { return }
        lastSandboxViolationKey = key
        lastSandboxViolationAt = Date()

        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: title,
            detail: detail,
            toolName: "Sandbox",
            source: "Claude Code",
            cwd: cwd,
            resolver: { _, _ in }))
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
