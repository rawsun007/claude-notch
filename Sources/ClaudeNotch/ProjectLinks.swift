import Foundation

/// Every URL and package name that points at this project.
///
/// These were written out wherever they were needed: the repo in
/// UpdateChecker, the releases page in two places, the changelog in two more,
/// the Homebrew cask in four. Each copy is a chance to get one wrong, and one
/// already was: the upgrade command shipped as a bare `claudenotch`, which
/// Homebrew refuses the moment that token exists in a second tap, while the
/// install command beside it was fully qualified.
enum ProjectLinks {
    /// owner/repo, the form the GitHub API wants.
    static let repo = "rawsun007/claude-notch"

    /// Fully qualified. A bare cask name is ambiguous as soon as the token
    /// exists in another tap, and Homebrew refuses rather than guessing.
    static let brewCask = "rawsun007/tap/claudenotch"

    static let github = "https://github.com/\(repo)"
    static let latestRelease = "\(github)/releases/latest"
    static let latestDMG = "\(latestRelease)/download/ClaudeNotch.dmg"
    static let changelog = "https://rawsun007.github.io/claude-notch/changelog/"

    static let brewUpgrade = "brew upgrade --cask \(brewCask)"

    /// The updater, for people who did not install with Homebrew. Written with
    /// ~ rather than an expanded home directory: shorter on screen, and it
    /// survives being pasted somewhere else.
    static let updateCommand = "~/.claudenotch/bin/claudenotch-update.sh"

    /// Anthropic's own pages, for the things this app reads but must not touch.
    /// Switching usage credits on, setting a spend limit or buying more is a
    /// billing change on someone's account: it belongs to them, on Anthropic's
    /// site, behind their login, not to a menu bar app holding a token it
    /// borrowed from another program.
    static let planSettings = "https://claude.ai/settings/usage"
    static let creditsHelp = "https://support.claude.com/articles/12429409"
}
