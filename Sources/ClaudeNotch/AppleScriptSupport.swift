import AppKit

/// AppleScript support: the same verbs as `claudenotch://`, plus the readable
/// state a URL cannot give back.
///
/// The dictionary lives in Resources/ClaudeNotch.sdef, which names each class
/// here. Scripting is what makes the app usable from Shortcuts (through its
/// "Run AppleScript" action), from a Stream Deck, and from anyone's own
/// menu-bar script, and unlike the URL scheme it can answer questions:
/// `tell application "ClaudeNotch" to get today spend`.
///
/// Everything below runs on the main thread — Cocoa scripting dispatches
/// commands and KVC property reads there — so the app state is reached through
/// `MainActor.assumeIsolated` rather than by hopping queues and losing the
/// return value.

// MARK: - Readable properties

/// The scriptable properties hang off the application object, which is what
/// `tell application "ClaudeNotch" to get …` addresses. The `scripting`
/// prefix keeps them from colliding with anything AppKit may add later.
extension NSApplication {

    private var notchState: AppState? {
        (delegate as? AppDelegate)?.state
    }

    @objc var scriptingTodaySpend: Double {
        MainActor.assumeIsolated { notchState?.todaySpendUSD ?? 0 }
    }

    @objc var scriptingSessionCount: Int {
        MainActor.assumeIsolated { notchState?.activeSessionCount ?? 0 }
    }

    @objc var scriptingWorkingCount: Int {
        MainActor.assumeIsolated { notchState?.workingSessionCount ?? 0 }
    }

    @objc var scriptingCurrentProject: String {
        MainActor.assumeIsolated { notchState?.currentProject ?? "" }
    }

    @objc var scriptingCurrentActivity: String {
        MainActor.assumeIsolated { notchState?.lastActivity ?? "" }
    }

    /// Cards holding a decision: what a "do I need to go back to my Mac"
    /// script is really asking about.
    @objc var scriptingPendingCount: Int {
        MainActor.assumeIsolated {
            guard let s = notchState else { return 0 }
            return s.permissionQueue.count + s.questionQueue.count
        }
    }
}

// MARK: - Commands

/// Shared plumbing: the app delegate, and the optional project argument.
///
/// A project reaching us from a script gets the same treatment as one from a
/// URL. A script is more trusted than a web page, but "more trusted" is not
/// "allowed to hand us a path": the name is still resolved against sessions
/// already on disk, so one validator serves both doors.
private extension NSScriptCommand {

    @MainActor var notchDelegate: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    /// The direct parameter as a validated project name.
    ///
    /// Returns `.some(nil)` when the caller passed nothing, and `nil` when what
    /// they passed cannot be a project name — the caller reports that as a
    /// script error rather than silently doing the wrong thing.
    var projectArgument: String?? {
        guard let raw = directParameter as? String else { return .some(nil) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .some(nil) }
        guard NotchURL.isSafeProjectName(trimmed) else { return nil }
        return .some(trimmed)
    }

    func failBadProject() {
        scriptErrorNumber = errOSAInvalidID
        scriptErrorString = "That is not a project name. Pass the folder's name, not its path."
    }
}

/// Finding the session to resume means reading hundreds of transcripts, so the
/// command suspends while that happens off the main thread. Doing it inline
/// would freeze the notch for as long as the scan took, and returning before
/// the answer was known would make the boolean result a lie.
@objc(NotchResumeCommand)
final class NotchResumeCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let project = projectArgument else { failBadProject(); return false }
        suspendExecution()
        MainActor.assumeIsolated {
            guard let delegate = notchDelegate else {
                resumeExecution(withResult: false)
                return
            }
            delegate.resumeForScripting(project: project) { [weak self] found in
                self?.resumeExecution(withResult: found)
            }
        }
        return nil
    }
}

@objc(NotchComposeCommand)
final class NotchComposeCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let project = projectArgument else { failBadProject(); return nil }
        MainActor.assumeIsolated { notchDelegate?.composeForScripting(project: project) }
        return nil
    }
}

/// Returns the text as well as copying it, so a script can post the standup
/// somewhere instead of routing it through the clipboard. Building it shells
/// out to git across every recent project, so this suspends too.
@objc(NotchStandupCommand)
final class NotchStandupCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()
        MainActor.assumeIsolated {
            guard let delegate = notchDelegate else {
                resumeExecution(withResult: "")
                return
            }
            delegate.standupForScripting { [weak self] text in
                self?.resumeExecution(withResult: text)
            }
        }
        return nil
    }
}

@objc(NotchShowSettingsCommand)
final class NotchShowSettingsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { notchDelegate?.run(.settings) }
        return nil
    }
}

@objc(NotchShowHistoryCommand)
final class NotchShowHistoryCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { notchDelegate?.run(.history) }
        return nil
    }
}

@objc(NotchShowNotchCommand)
final class NotchShowNotchCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { notchDelegate?.run(.open) }
        return nil
    }
}
