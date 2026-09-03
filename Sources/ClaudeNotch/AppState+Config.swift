import Foundation

// A settings file changed while sessions were running (the `ConfigChange` hook).
//
// Two things follow from it. The cheap one: the sandbox posture the notch shows
// is read from exactly these files, so a change means the cached answer is
// wrong now rather than in up to a minute. The one that matters: settings are
// where permissions, allow rules and sandboxing live, so "your permission rules
// changed while three sessions were running" is a security fact, and the notch
// exists to say those out loud.

extension AppState {

    /// Sources that decide what an agent may do. A `skills` change is
    /// recorded but not announced: it changes what Claude knows, not what it
    /// is allowed to do, and a card for every skill edit would train you to
    /// ignore the card that matters.
    nonisolated static func configChangeIsSecurity(source: String) -> Bool {
        switch source {
        case "user_settings", "project_settings", "local_settings", "policy_settings":
            return true
        default:
            return false
        }
    }

    /// Human name for a `ConfigChange` source. An unknown source is reported
    /// as itself rather than swallowed: a new source added by a future CLI
    /// release should read oddly, not vanish.
    nonisolated static func configChangeLabel(source: String) -> String {
        switch source {
        case "user_settings":    return L("Your settings changed", comment: "Card title: ~/.claude/settings.json was edited")
        case "project_settings": return L("Project settings changed", comment: "Card title: the project's .claude/settings.json was edited")
        case "local_settings":   return L("Local project settings changed", comment: "Card title: .claude/settings.local.json was edited")
        case "policy_settings":  return L("Managed policy changed", comment: "Card title: the administrator's managed settings changed")
        case "skills":           return L("Skills changed", comment: "Card title: the installed skills changed")
        case "":                 return L("Configuration changed", comment: "Card title: a settings file changed, source unknown")
        default:                 return String(format: L("Configuration changed (%@)", comment: "Card title for an unrecognized config source. %@ is the source name"), source)
        }
    }

    /// How long after the app writes settings.json itself its own change stops
    /// counting as news. Installing hooks and merging allow rules both rewrite
    /// that file, and every running session fires ConfigChange at us for it —
    /// so without this the app announces its own edits, several times over.
    nonisolated static let selfSettingsWriteGrace: TimeInterval = 10

    /// A settings file changed mid-session.
    func noteConfigChanged(source: String, filePath: String) {
        // The sandbox badge is read from these files. Drop the cache and
        // re-read for every live session, so the badge is right immediately
        // rather than up to a cache TTL later.
        sandboxCache.removeAll()
        for session in Array(sessions.values) {
            refreshSandbox(cwd: session.cwd, sessionId: session.id, model: session.model)
        }

        // Managed settings are where the policy comes from, so re-read it.
        refreshPolicy()

        let title = Self.configChangeLabel(source: source)
        let detail = Self.configChangeDetail(source: source, filePath: filePath)

        // Record it, unless a card is about to. enqueuePermission writes its own
        // history entry for a notification card, deliberately, because a
        // notification has no Allow/Deny to record later. Appending here as well
        // filed every permission-bearing settings change twice: one hook, two
        // identical rows in the activity log, same second. The log this is meant
        // to make scannable was the thing being made unscannable.
        func record() {
            appendHistory(HistoryEntry(
                timestamp: Date(),
                kind: .notification,
                toolName: "ConfigChange",
                title: title,
                detail: detail,
                project: currentProject,
                outcome: .info))
        }

        // A source that changes what Claude knows rather than what it may do.
        guard Self.configChangeIsSecurity(source: source) else { record(); return }
        // Our own write, or a burst of writes for the same source (an editor
        // saving twice, or several sessions reporting the same edit). Still
        // recorded, just not announced.
        guard Date().timeIntervalSince(HookInstaller.lastSelfWriteAt) > Self.selfSettingsWriteGrace else { record(); return }
        if let last = lastConfigCardAt[source], Date().timeIntervalSince(last) < 5 { record(); return }
        lastConfigCardAt[source] = Date()

        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: title,
            detail: detail,
            toolName: "ConfigChange",
            source: "Claude Code",
            cwd: currentCwd,
            resolver: { _, _ in }))
    }

    /// The path, shortened to something that fits a card. Home is `~`, and a
    /// long path keeps its tail — the file name is the informative end.
    nonisolated static func configChangeDetail(source: String, filePath: String) -> String {
        guard !filePath.isEmpty else {
            return String(format: L("Source: %@", comment: "Card detail when a config change carried no file path. %@ is the source name"),
                          source.isEmpty ? "unknown" : source)
        }
        let home = NSHomeDirectory()
        var path = filePath
        if !home.isEmpty, path.hasPrefix(home) { path = "~" + path.dropFirst(home.count) }
        guard path.count > 60 else { return path }
        return "…" + String(path.suffix(59))
    }
}
