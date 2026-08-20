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


// MARK: - Pull requests and merge requests

/// What a code review is called on the host it lives on.
///
/// Claude Code resolves the open review for a branch and hands it over in one
/// set of fields whatever the host is, parsing GitHub's `/pull/42` and GitLab's
/// `/-/merge_requests/42` into the same number. Only the wording differs, and
/// the wording matters: a GitLab user reading "#42" next to a pull-request icon
/// is being told about something their host does not have.
enum ReviewHost: Equatable {
    case github, gitlab, bitbucket, unknown

    /// Read from the URL rather than guessed from the number. The path shape is
    /// the only thing that distinguishes them.
    nonisolated static func infer(from url: String) -> ReviewHost {
        let lower = url.lowercased()
        if lower.contains("/-/merge_requests/") { return .gitlab }
        if lower.contains("/pull-requests/") { return .bitbucket }
        if lower.contains("/pull/") { return .github }
        // Fall back on the domain, for a URL shape this does not know.
        if lower.contains("gitlab") { return .gitlab }
        if lower.contains("bitbucket") { return .bitbucket }
        if lower.contains("github") { return .github }
        return .unknown
    }

    /// GitLab writes !42. Everyone else writes #42.
    var sigil: String { self == .gitlab ? "!" : "#" }

    /// The SF Symbol for the chip.
    var symbol: String {
        self == .gitlab ? "arrow.triangle.merge" : "arrow.triangle.pull"
    }

    var noun: String {
        switch self {
        case .gitlab:    return L("Merge request", comment: "GitLab's name for a code review")
        case .bitbucket: return L("Pull request", comment: "Bitbucket's name for a code review")
        case .github, .unknown: return L("Pull request", comment: "GitHub's name for a code review")
        }
    }

    /// The chip's text: !42 or #42.
    nonisolated static func chipLabel(url: String, number: Int) -> String {
        "\(infer(from: url).sigil)\(number)"
    }

    /// "Merge request !42" / "Pull request #42", for VoiceOver and tooltips.
    nonisolated static func spoken(url: String, number: Int) -> String {
        let host = infer(from: url)
        return "\(host.noun) \(host.sigil)\(number)"
    }
}
