import AppKit

/// One ClaudeNotch at a time. The copy launched last takes over.
///
/// Two copies of the bundle at different paths (the installed one and a
/// development build, or an old download left in ~/Downloads) both run when
/// both are opened: Launch Services only fronts an already-running copy when
/// it is the same bundle. Only one of them can hold the hook port, so the
/// other shows "Not listening" in Settings while looking perfectly alive, and
/// whichever window you are looking at may be the deaf one. The copy you just
/// opened is the one you meant, so it asks the others to quit and, if they
/// have not within a few seconds, ends them. EventServer keeps retrying the
/// port, so it picks it up as soon as the old copy lets go.
enum SingleInstance {
    struct Candidate: Equatable {
        let pid: pid_t
        let bundleID: String?
    }

    /// The copies to end: the same bundle id, any process but this one. Pure,
    /// for tests.
    nonisolated static func others(of bundleID: String?, selfPID: pid_t, among running: [Candidate]) -> [pid_t] {
        guard let bundleID, !bundleID.isEmpty else { return [] }
        return running.filter { $0.bundleID == bundleID && $0.pid != selfPID }.map(\.pid)
    }

    @MainActor
    static func takeOver() {
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
        let pids = others(of: Bundle.main.bundleIdentifier, selfPID: me,
                          among: apps.map { Candidate(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier) })
        let targets = apps.filter { pids.contains($0.processIdentifier) }
        guard !targets.isEmpty else { return }
        for app in targets {
            DebugLog.append("startup", "another copy is running (pid \(app.processIdentifier), \(app.bundleURL?.path ?? "?")); asking it to quit")
            app.terminate()
        }
        // A copy stuck on a modal or hung does not answer the quit event.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            for app in targets where !app.isTerminated {
                DebugLog.append("startup", "pid \(app.processIdentifier) did not quit; ending it")
                app.forceTerminate()
            }
        }
    }
}
