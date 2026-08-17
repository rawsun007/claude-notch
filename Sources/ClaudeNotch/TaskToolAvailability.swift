import Foundation

// Whether Claude Code is still giving this app anything to build a task meter
// out of.
//
// The meter is fed by TodoWrite and by the TaskCreated / TaskCompleted hooks.
// Claude Code 2.1.233 took the todo tools away from Opus 4.8, Sonnet 5, Fable 5,
// Mythos 5 and newer unless CLAUDE_CODE_ENABLE_TODO_TOOLS=1 is set, so on a
// current model the meter has nothing to show and never says why. A feature
// that shows nothing looks exactly like a feature that is broken.
//
// The app cannot ask Claude Code which tools it has. What it can do is notice
// that a session has done a substantial amount of work without ever mentioning
// a task, which on a model that has the tools essentially does not happen, and
// then say the one thing that turns the meter back on.
enum TaskToolAvailability {

    /// Tool calls a session can make before "no tasks yet" stops being a
    /// plausible explanation. A session that has run twenty tools without a
    /// checklist is not about to start.
    static let toolCallsBeforeConcluding = 20

    /// The setting that brings the tools back.
    static let envVar = "CLAUDE_CODE_ENABLE_TODO_TOOLS"

    /// The first release that withheld them, and the models it applies to.
    static let removedIn = "2.1.233"

    /// Has this session done enough without a task for the absence to be the
    /// tools being gone rather than the work not needing them?
    nonisolated static func looksDisabled(toolCalls: Int, everReportedTask: Bool,
                                          cliVersion: String) -> Bool {
        guard !everReportedTask else { return false }
        guard toolCalls >= toolCallsBeforeConcluding else { return false }
        // On a CLI too old to have removed them, an empty meter means the work
        // had no checklist, which is ordinary and not worth a word.
        return CLIVersion.atLeast(cliVersion.isEmpty ? removedIn : cliVersion, removedIn)
    }

    /// Is the flag that restores them already set in a settings env block?
    /// Reading it is how the hint knows to stop offering advice already taken.
    nonisolated static func isEnabled(env: [String: String]) -> Bool {
        guard let raw = env[envVar]?.trimmingCharacters(in: .whitespaces) else { return false }
        return !raw.isEmpty && raw != "0" && raw.lowercased() != "false"
    }

    /// What to tell the user, once.
    nonisolated static var hintTitle: String {
        L("Task progress is off in Claude Code",
          comment: "Settings hint title when the todo tools are unavailable on this model")
    }

    nonisolated static var hintDetail: String {
        String(format: L("Claude Code %1$@ removed the to-do tools from its newer models, so sessions no longer report a checklist and the task meter stays empty. To bring it back, set %2$@=1 in the env block of ~/.claude/settings.json.",
                         comment: "Settings hint body. %1$@ is a Claude Code version, %2$@ is an environment variable name"),
               removedIn, envVar)
    }
}
