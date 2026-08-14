import Foundation

// Keeping an eye on the CLI the app exists to watch.
//
// The version check is one subprocess and one small HTTP GET, so it runs on a
// slow timer and whenever the user opens Settings. See ClaudeCLIUpdate for the
// pure parts.

extension AppState {

    /// Re-check at most this often on the automatic path. Claude Code ships
    /// several times a week, not several times an hour.
    nonisolated static let cliUpdateCheckInterval: TimeInterval = 6 * 3600

    func ensureCLIUpdateTimer() {
        guard cliUpdateTimer == nil else { return }
        refreshCLIUpdate()
        cliUpdateTimer = Timer.scheduledTimer(withTimeInterval: Self.cliUpdateCheckInterval,
                                              repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshCLIUpdate() }
        }
    }

    /// Read the installed version and ask the registry for the newest one.
    ///
    /// `force` is for the button in Settings: the automatic path skips a check
    /// that ran recently, so opening Settings repeatedly does not hit the
    /// network every time, but asking for one explicitly always asks.
    func refreshCLIUpdate(force: Bool = false) {
        if !force, let checkedAt = claudeCLI.checkedAt,
           Date().timeIntervalSince(checkedAt) < Self.cliUpdateCheckInterval / 6 {
            return
        }
        cliUpdateChecking = true
        Task { [weak self] in
            // The subprocess goes off the main thread; the network call is
            // already off it.
            let local = await Task.detached(priority: .utility) {
                ClaudeCLIUpdate.readInstalled()
            }.value
            let latest = await ClaudeCLIUpdate.fetchLatest()
            guard let self else { return }
            var status = self.claudeCLI
            status.installed = local.version
            status.path = local.path
            status.method = ClaudeCLIUpdate.method(forPath: local.path)
            // Keep the last known latest when the check failed, so a dropped
            // connection does not turn "update available" into "up to date".
            if !latest.isEmpty { status.latest = latest }
            status.checkedAt = Date()

            // Only fetch the notes when there is something to update to. On an
            // up-to-date machine this is a network call for text nobody will
            // see, and an empty list is what the UI needs anyway.
            if status.updateAvailable {
                let changelog = await ClaudeCLIUpdate.fetchChangelog()
                status.notes = ClaudeCLIUpdate.notes(ClaudeCLIUpdate.parseChangelog(changelog),
                                                     installed: status.installed,
                                                     latest: status.latest)
            } else {
                status.notes = []
            }

            self.claudeCLI = status
            self.cliUpdateChecking = false

            // The update we launched has landed: stop watching for it.
            if !status.updateAvailable { self.cliUpdateLaunchedAt = nil }
        }
    }

    /// Re-check shortly after an update is launched, until the installed
    /// version moves.
    ///
    /// Without this the card kept saying an update was available after the
    /// update had been installed: the automatic check runs every six hours,
    /// opening the page re-checks at most hourly, and while an update was
    /// pending the only button on the row was Update. The user had done what
    /// the app asked and the app went on asking.
    private func startPostUpdateWatch() {
        cliUpdateLaunchedAt = Date()
        cliRecheckTimer?.invalidate()
        cliRecheckTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else { timer.invalidate(); return }
                // Give up after a few minutes: the terminal window may be
                // sitting at a password prompt, or the user may have closed it.
                if let launched = self.cliUpdateLaunchedAt,
                   Date().timeIntervalSince(launched) > Self.postUpdateWatchWindow {
                    self.cliUpdateLaunchedAt = nil
                }
                guard self.cliUpdateLaunchedAt != nil else {
                    timer.invalidate()
                    self.cliRecheckTimer = nil
                    return
                }
                self.refreshCLIUpdate(force: true)
            }
        }
    }

    nonisolated static let postUpdateWatchWindow: TimeInterval = 5 * 60

    /// Sessions running an older CLI than the one installed.
    ///
    /// A session loads its binary at launch and keeps it, so updating changes
    /// nothing until each one restarts. Without saying so, updating and then
    /// watching a session still behave the old way reads as the update having
    /// failed. Needs the session registry, which is the only place the app
    /// learns a session's version.
    var sessionsOnOlderCLI: [LiveSession] {
        let installed = claudeCLI.installed
        guard !installed.isEmpty else { return [] }
        return sessions.values
            .filter { !$0.cliVersion.isEmpty && UpdateChecker.isNewer(installed, than: $0.cliVersion) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Run the update command in a terminal window the user can watch.
    ///
    /// Not run silently in the background on purpose: this replaces the binary
    /// every session on the machine is about to launch, it can ask for input
    /// (npm and Homebrew both do), and its output is the only evidence it
    /// worked. Handing it to a terminal keeps the user in charge of it.
    func updateClaudeCLI() {
        let command = claudeCLI.command
        TerminalAutomator.runUpdateCommand(command)
        startPostUpdateWatch()
        appendHistory(HistoryEntry(
            timestamp: Date(),
            kind: .notification,
            toolName: "Update",
            title: L("Updating Claude Code", comment: "History entry when the user starts a CLI update"),
            detail: command,
            project: currentProject,
            outcome: .info))
    }
}
