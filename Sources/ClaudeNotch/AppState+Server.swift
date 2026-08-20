import Foundation

// Whether the hook server is actually listening, and what to say when it is not.
//
// The app used to log a failed bind and carry on looking normal: menu bar icon
// present, notch behaving, no cards. That is indistinguishable from a quiet
// day, and it is the worst possible way to fail, because the reason the port is
// taken may be that another program is sitting on it answering Claude Code's
// permission prompts. Whoever answers those decides whether a tool call runs.
//
// So a dead server is a state the app holds and shows, not a line in a log
// nobody reads.
extension AppState {

    enum ServerStatus: Equatable {
        case listening
        /// The port is taken by another process. The dangerous one.
        case portTaken(port: Int)
        /// Anything else the socket refused to do.
        case failed(reason: String)

        var isHealthy: Bool { self == .listening }
    }

    /// The server came up. Clears any previous failure, so a retry that works
    /// puts the app back to normal without a restart.
    func noteServerListening() {
        guard serverStatus != .listening else { return }
        serverStatus = .listening
    }

    /// The server could not listen. Records the state, writes a history row,
    /// and raises a card that says the true thing.
    func noteServerFailed(_ status: ServerStatus) {
        guard status != .listening, serverStatus != status else { return }
        serverStatus = status

        // The card writes its own history row on the way in, so this does not
        // add one: two rows for one event is noise in the drawer and in every
        // export built from it. The danger reason is what marks the row (and
        // the card) as something other than a routine ping.
        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: Self.serverFailureTitle(status),
            detail: Self.serverFailureDetail(status),
            toolName: "EventServer",
            source: "ClaudeNotch",
            cwd: currentCwd,
            originatorBundleID: nil,
            preview: nil,
            dangerReasons: [L("ClaudeNotch is not receiving Claude Code's prompts",
                              comment: "Why the hook-server card is marked dangerous")],
            resolver: { _, _ in }))
    }

    /// Read the managed policy and say so once.
    ///
    /// Called at launch and whenever a settings file changes, since managed
    /// settings are exactly the kind that change without the user doing it.
    func refreshPolicy() {
        let path = PolicyLimits.defaultPath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = PolicyLimits.read(path: path)
            Task { @MainActor in
                guard let self, status != self.policy else { return }
                self.policy = status
                self.announcePolicyIfNeeded()
            }
        }
    }

    /// A managed machine gets one card, keyed on the notice text so a changed
    /// notice is shown again and an unchanged one is not.
    func announcePolicyIfNeeded() {
        guard policy.isManaged else { return }
        let key = policy.monitoringNotice ?? policy.denied.joined(separator: ",")
        guard key != announcedPolicyNotice else { return }
        announcedPolicyNotice = key

        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: PolicyLimits.cardTitle(policy),
            detail: PolicyLimits.cardDetail(policy),
            toolName: "Policy",
            source: "Managed settings",
            cwd: currentCwd,
            resolver: { _, _ in }))
    }

    /// The headline. Says what is wrong with the app, not what is wrong with a
    /// socket: "bind failed, errno 48" is true and useless.
    nonisolated static func serverFailureTitle(_ status: ServerStatus) -> String {
        switch status {
        case .listening:
            return ""
        case .portTaken:
            return L("Another program is receiving Claude Code's prompts",
                     comment: "Card title when the hook port is already taken by another process")
        case .failed:
            return L("ClaudeNotch cannot receive Claude Code's prompts",
                     comment: "Card title when the hook server could not start for any other reason")
        }
    }

    /// What it means and what to type. A port conflict is not necessarily an
    /// attack — a leftover copy of this app does it too — so the wording says
    /// what is true either way and hands over the command that settles it.
    nonisolated static func serverFailureDetail(_ status: ServerStatus) -> String {
        switch status {
        case .listening:
            return ""
        case .portTaken(let port):
            return String(format: L("Port %d is taken, so permission prompts are going to whatever is on it and this app will show nothing. That may be an old copy of ClaudeNotch, or it may not. Check with: lsof -nP -iTCP:%d -sTCP:LISTEN",
                                    comment: "Card detail for a taken hook port. %d is the port number, twice"),
                          port, port)
        case .failed(let reason):
            return String(format: L("The hook server did not start (%@), so nothing will appear here until it does. Quitting and reopening ClaudeNotch is the first thing to try.",
                                    comment: "Card detail when the hook server failed for a non-conflict reason. %@ is the underlying error"),
                          reason)
        }
    }

    /// One short line for the menu bar, where there is no room for the rest.
    nonisolated static func serverFailureMenuLabel(_ status: ServerStatus) -> String? {
        switch status {
        case .listening:  return nil
        case .portTaken:  return L("Not receiving prompts: port taken",
                                   comment: "Menu bar row when another process holds the hook port")
        case .failed:     return L("Not receiving prompts: server down",
                                   comment: "Menu bar row when the hook server failed to start")
        }
    }
}
