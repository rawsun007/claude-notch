import Foundation

/// The `claudenotch://` URL scheme: the app's scriptable surface.
///
/// Anything that can open a URL can now drive the notch — a Shortcut, a
/// Raycast script, an Alfred workflow, a `Cmd-click` in a terminal, a link in
/// a note. The verbs mirror what the menu bar already offers, so nothing here
/// can do something a user could not do with two clicks.
///
/// A URL is untrusted input. It can arrive from a web page the user merely
/// visited, so the parser is deliberately narrow:
///
///   * only the verbs below are recognised, everything else is dropped;
///   * a project is a *name*, never a path — a value containing a separator or
///     a `..` is rejected here, and the handler still resolves the name
///     against sessions already on disk rather than launching what it was
///     given. A page cannot point the agent at a directory of its choosing.
///
/// Supported forms (host or first path segment carries the verb):
///
///     claudenotch://open
///     claudenotch://settings
///     claudenotch://history
///     claudenotch://standup
///     claudenotch://compose            claudenotch://compose/myproject
///     claudenotch://resume             claudenotch://resume/myproject
///                                      claudenotch://resume?project=myproject
enum NotchURLAction: Equatable {
    /// Bring the notch card up, as hovering it would.
    case open
    case settings
    case history
    /// Copy today's standup to the clipboard.
    case standup
    /// Open the composer, optionally aimed at a named project.
    case compose(project: String?)
    /// Resume a session: the newest one overall, or the newest in a project.
    case resume(project: String?)
}

enum NotchURL {

    static let scheme = "claudenotch"

    /// Parse a URL into an action, or nil when it is not one of ours.
    ///
    /// Pure and `nonisolated` so the tests can call it directly: this is the
    /// untrusted-input boundary and it is where the security of the scheme
    /// lives.
    nonisolated static func parse(_ url: URL) -> NotchURLAction? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        // claudenotch://resume/foo puts the verb in the host; claudenotch:///resume/foo
        // puts it in the path. Accept both rather than making the caller know
        // which form URLComponents produced.
        var segments = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        var verb = url.host ?? ""
        if verb.isEmpty {
            guard !segments.isEmpty else { return nil }
            verb = segments.removeFirst()
        }

        let project = projectArgument(segments.first, url: url)
        // A malformed project is not the same as an absent one: silently
        // resuming "the most recent session anywhere" because the argument was
        // rejected would be the wrong project, quietly.
        if project == .invalid { return nil }
        let name = project.name

        switch verb.lowercased() {
        case "open":     return .open
        case "settings": return .settings
        case "history":  return .history
        case "standup":  return .standup
        case "compose":  return .compose(project: name)
        case "resume":   return .resume(project: name)
        default:         return nil
        }
    }

    /// A project name from the path or the `project=` query, validated.
    private enum ProjectArgument: Equatable {
        case absent
        case invalid
        case named(String)

        var name: String? { if case .named(let n) = self { return n }; return nil }
    }

    private nonisolated static func projectArgument(_ segment: String?, url: URL) -> ProjectArgument {
        let raw = segment ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "project" })?.value
        guard let raw else { return .absent }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .absent }
        guard isSafeProjectName(trimmed) else { return .invalid }
        return .named(trimmed)
    }

    /// A project is the last component of a working directory, so it can never
    /// legitimately contain a separator, a `..`, a `~`, or a control character.
    /// Rejecting those here means the rest of the app cannot be handed a path
    /// dressed up as a name.
    nonisolated static func isSafeProjectName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128 else { return false }
        guard !name.hasPrefix("."), !name.hasPrefix("~") else { return false }
        guard !name.contains("/"), !name.contains("\\"), !name.contains("..") else { return false }
        return !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
