import Foundation

/// What Auto-Approve answers for you, chosen when you turn it on.
enum AutoApproveScope: String, Codable, CaseIterable, Sendable {
    /// Every tool request.
    case everything
    /// Shell commands only (Claude Code's Bash, Codex's shell tools).
    case commands
    /// Reading and editing files only; commands still get a card.
    case files

    var label: String {
        switch self {
        case .everything: return L("Everything", comment: "Auto-Approve scope: every tool request")
        case .commands:   return L("Commands only", comment: "Auto-Approve scope: shell commands only")
        case .files:      return L("File reads and edits only", comment: "Auto-Approve scope: reading and editing files only")
        }
    }

    var explanation: String {
        switch self {
        case .everything: return L("Every tool request is allowed without a card.", comment: "Auto-Approve scope explanation")
        case .commands:   return L("Terminal commands are allowed without a card. File edits and everything else still ask.", comment: "Auto-Approve scope explanation")
        case .files:      return L("Reading, searching and editing files is allowed without a card. Terminal commands still ask.", comment: "Auto-Approve scope explanation")
        }
    }
}

/// What Auto-Approve does with a command the danger check flags (rm -rf,
/// sudo, force pushes and the like), for requests inside its scope.
enum AutoApproveDangerous: String, Codable, CaseIterable, Sendable {
    /// Show the red card, as without Auto-Approve.
    case ask
    /// Ask for Touch ID straight away, no click on the card; the card stays
    /// if that is cancelled or fails.
    case biometric
    /// Allow it too. Switching this on needs the Mac owner's authentication.
    case allow

    var label: String {
        switch self {
        case .ask:       return L("Show the card", comment: "Auto-Approve dangerous-command choice")
        case .biometric: return String(format: L("Confirm with %@", comment: "Auto-Approve dangerous-command choice. %@ is Touch ID or Face ID"), BiometricAuth.label)
        case .allow:     return L("Approve them too", comment: "Auto-Approve dangerous-command choice")
        }
    }

    var explanation: String {
        switch self {
        case .ask:
            return L("Destructive commands still wait on the red card for you.", comment: "Auto-Approve dangerous-command explanation")
        case .biometric:
            return String(format: L("The %@ prompt comes up on its own, so a finger allows it with no click. Cancel it and the card stays.", comment: "Auto-Approve dangerous-command explanation. %@ is Touch ID or Face ID"), BiometricAuth.label)
        case .allow:
            return L("Destructive commands run with no prompt at all, including deleting files and force pushes. Each one is still logged in History. Turning this on asks for Touch ID or your Mac password.", comment: "Auto-Approve dangerous-command explanation")
        }
    }
}

/// The answer Auto-Approve gives one request.
enum AutoApproveVerdict: Equatable, Sendable {
    /// Allow it without a card.
    case allow
    /// Show the card and bring up the biometric prompt for it at once.
    case confirmWithBiometrics
    /// Not Auto-Approve's to answer: the ordinary card.
    case showCard
}

enum AutoApprovePolicy {
    /// Tool names that run a shell command.
    nonisolated static let commandTools: Set<String> = [
        "Bash", "BashOutput", "KillShell", "KillBash",
        "shell", "local_shell", "exec", "exec_command", "unified_exec",
    ]
    /// Tool names that read, search or edit files.
    nonisolated static let fileTools: Set<String> = [
        "Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "NotebookRead",
        "Glob", "Grep", "LS", "apply_patch",
    ]

    nonisolated static func covers(_ scope: AutoApproveScope, toolName: String) -> Bool {
        switch scope {
        case .everything: return true
        case .commands:   return commandTools.contains(toolName)
        case .files:      return fileTools.contains(toolName)
        }
    }

    /// Pure, for tests. `strictBlocks` is Strict Mode refusing a blanket
    /// approval for this request; it wins over every choice here, since it
    /// is the setting for "don't let anything approve this for me".
    nonisolated static func verdict(enabled: Bool,
                                    scope: AutoApproveScope,
                                    dangerous: AutoApproveDangerous,
                                    toolName: String,
                                    isDangerous: Bool,
                                    strictBlocks: Bool) -> AutoApproveVerdict {
        guard enabled, covers(scope, toolName: toolName), !strictBlocks else { return .showCard }
        guard isDangerous else { return .allow }
        switch dangerous {
        case .ask:       return .showCard
        case .biometric: return .confirmWithBiometrics
        case .allow:     return .allow
        }
    }

    /// Switching to `next` needs the owner to authenticate first only when it
    /// starts allowing destructive commands with no prompt.
    nonisolated static func needsAuthentication(from current: AutoApproveDangerous, to next: AutoApproveDangerous) -> Bool {
        next == .allow && current != .allow
    }
}
