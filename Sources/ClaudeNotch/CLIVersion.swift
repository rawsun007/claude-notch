import Foundation

// Which Claude Code build a session is running, and what that build is capable
// of telling us.
//
// The notch shows facts that only exist above a certain CLI version. The
// sandbox posture is read from settings keys that landed in 2.1.219; the
// /add-dir chip is fed by a hook added in the same release; the fork label
// comes from a SessionStart field added in 2.1.214. Two sessions side by side
// can be running different builds — one started this morning, one left open
// since last week — and the older one cannot produce the data the badge is
// made of.
//
// Without this, a session on an older build reads as "not sandboxed" and "no
// directories added", which are claims, not absences. Silence is the honest
// answer there, and the row tooltip already says which version it is.
//
// Pure and `nonisolated` throughout: version arithmetic is the kind of thing
// that should be settled by tests, not by running the app.
enum CLIVersion {

    /// A thing the notch can only show when the session's CLI can report it.
    enum Feature: CaseIterable {
        /// Sandbox posture: `sandbox.network.strictAllowlist` and the settings
        /// shape SandboxReader reads.
        case sandboxPosture
        /// The `DirectoryAdded` hook behind the /add-dir chip.
        case addedDirectories
        /// SessionStart reporting source "fork" instead of "resume".
        case forkSource
        /// The `PostCompact` hook that ends the compacting cue.
        case postCompact
        /// The `Elicitation` / `ElicitationResult` hooks.
        case elicitation

        /// The first release that shipped it, from Claude Code's changelog.
        var floor: String {
            switch self {
            case .sandboxPosture, .addedDirectories: return "2.1.219"
            case .forkSource:                        return "2.1.214"
            case .postCompact, .elicitation:         return "2.1.76"
            }
        }
    }

    /// Whether a session running `version` can produce what `feature` shows.
    ///
    /// An unknown version answers yes. Not knowing which build a session is on
    /// is not evidence that it is an old one, and hiding a badge whose data we
    /// are already holding would be worse than showing it.
    nonisolated static func supports(_ feature: Feature, version: String) -> Bool {
        guard !version.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        return atLeast(version, feature.floor)
    }

    /// `version >= floor`, comparing numerically component by component.
    nonisolated static func atLeast(_ version: String, _ floor: String) -> Bool {
        compare(version, floor) != .orderedAscending
    }

    /// Order two version strings. A version we cannot read any number out of
    /// sorts as 0, which loses to every real release — but `supports` never
    /// reaches here with an empty string, so an unreadable version only ever
    /// costs a badge, never a wrong claim.
    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let lhs = components(a), rhs = components(b)
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// "2.1.219" → [2, 1, 219]. A pre-release or build suffix ("2.2.0-beta.1")
    /// is dropped rather than parsed: 2.2.0-beta is on the 2.2.0 side of every
    /// floor this app cares about, and ordering it below the release it
    /// precedes would hide the badge from exactly the people testing it.
    nonisolated static func components(_ version: String) -> [Int] {
        let core = version
            .trimmingCharacters(in: .whitespaces)
            .prefix { $0.isNumber || $0 == "." }
        return core.split(separator: ".").compactMap { Int($0) }
    }
}
