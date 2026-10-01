import Foundation

/// Claude Code's own deadline on a dangerous `rm`.
///
/// Since CLI 2.1.281, in auto mode and under `--dangerously-skip-permissions`,
/// the prompt for a dangerous recursive `rm` waits two minutes for an answer and
/// then denies the command itself, with a hint to rewrite it, so an unattended
/// session keeps going. The notch holds a card for `EventServer.decisionWindow`
/// (285 s), so without this the card would sit there looking live for nearly
/// three minutes after the CLI had already said no, and anything pressed in it
/// would be thrown away. This gives the card the CLI's real deadline.
///
/// `CLAUDE_CODE_DISABLE_DANGEROUS_RM_TIMEOUT=1` turns the CLI's timeout off. That
/// lives in the session's environment, which no hook payload carries, so a
/// session with it set gets a card that says "denies itself" when it will not.
/// Erring that way is the safe one: the user answers sooner than needed.
enum DangerousRmTimeout {
    /// The CLI's wait, in seconds.
    static let window: TimeInterval = 120

    /// The permission modes the CLI applies the timeout in.
    nonisolated static let modes: Set<String> = ["auto", "bypassPermissions"]

    /// Does Claude Code put its own two-minute deadline on this request?
    nonisolated static func applies(toolName: String, toolInput: [String: Any], permissionMode: String) -> Bool {
        guard modes.contains(permissionMode), toolName == "Bash",
              let command = toolInput["command"] as? String else { return false }
        return isRecursiveRm(command)
    }

    /// A recursive `rm` anywhere in the command: `rm -r`, `-rf`, `-fR`,
    /// `--recursive`, at the start, after `sudo`, or after `;`, `&&`, `||`, `|`
    /// or a subshell's `(`. Pure, for tests.
    nonisolated static func isRecursiveRm(_ command: String) -> Bool {
        let pattern = #"(^|[;&|(]\s*|\bsudo\s+)rm(\s+-[A-Za-z]+|\s+--[a-z-]+)*\s+(-[A-Za-z]*[rR][A-Za-z]*|--recursive)\b"#
        return command.range(of: pattern, options: .regularExpression) != nil
    }

    /// "1:42", for the countdown on the card.
    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
