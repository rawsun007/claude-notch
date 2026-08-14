import Foundation

// Is the Claude Code CLI itself out of date?
//
// The app already checks for updates to ClaudeNotch. The thing it exists to
// watch has its own release train, ships several times a week, and the notch
// keeps growing features that need a minimum CLI version (the sandbox badge
// needs 2.1.219+, the deprecated-permission fix is about 2.1.210). So "your
// Claude Code is three versions behind" is both knowable and worth saying.
//
// Everything that can be pure is: which install a path implies, what command
// updates that install, and how to read a version out of the CLI and out of the
// npm registry. The network call and the shell-out are the only impure parts.

enum ClaudeCLIUpdate {

    /// How Claude Code got onto this machine, which decides how it updates.
    enum Method: String, Equatable {
        /// Anthropic's own installer: a versions directory with a symlinked
        /// launcher. Updates itself with `claude update`.
        case native
        /// A global npm install (including one under Homebrew's node prefix).
        case npm
        /// A Homebrew formula or cask, i.e. a real Cellar/Caskroom path.
        case homebrew
        /// Anything else, including "we could not find the CLI at all".
        case unknown
    }

    /// One version's changelog section.
    struct ReleaseNotes: Equatable {
        let version: String
        let items: [String]
    }

    struct Status: Equatable {
        /// What `claude --version` reports. Empty when the CLI was not found.
        var installed: String = ""
        /// The newest published version, from the npm registry. Empty until the
        /// check succeeds — an unknown latest must never read as "up to date".
        var latest: String = ""
        var method: Method = .unknown
        /// The absolute path the version came from, for the tooltip.
        var path: String = ""
        var checkedAt: Date? = nil
        /// What changed in the versions between the installed one and the
        /// newest, newest first. Empty when the notes could not be fetched, or
        /// when there is nothing to update to — in which case the UI shows no
        /// notes section at all rather than an empty heading.
        var notes: [ReleaseNotes] = []

        /// True only when both versions are known and latest is genuinely
        /// newer. A failed check leaves this false, so the UI says nothing
        /// rather than inventing news.
        var updateAvailable: Bool {
            guard !installed.isEmpty, !latest.isEmpty else { return false }
            return UpdateChecker.isNewer(latest, than: installed)
        }

        /// The command that updates THIS install.
        var command: String { ClaudeCLIUpdate.command(for: method, cliPath: path) }
    }

    // MARK: - Which install is this

    /// Read the install method off the resolved binary path.
    ///
    /// Path-based because it is the one signal available without running
    /// anything: asking the CLI would cost a subprocess, and asking npm or brew
    /// costs several.
    nonisolated static func method(forPath path: String) -> Method {
        guard !path.isEmpty else { return .unknown }
        // Homebrew first: a Homebrew npm install lives under node_modules
        // inside the Homebrew prefix, and npm is what updates it, so the
        // node_modules test has to win over the /opt/homebrew one.
        if path.contains("/node_modules/") { return .npm }
        if path.contains("/Cellar/") || path.contains("/Caskroom/") { return .homebrew }
        if path.contains("/.local/share/claude/") || path.contains("/.local/bin/") { return .native }
        if path.contains("/.npm-global/") || path.contains("/.nvm/") { return .npm }
        return .unknown
    }

    /// What to run to update that install.
    ///
    /// `claude update` is the fallback for anything unrecognized: it is the
    /// CLI's own updater, it is non-destructive, and when it cannot update the
    /// install it says so rather than breaking it.
    nonisolated static func command(for method: Method, cliPath: String) -> String {
        let claude = cliPath.isEmpty ? "claude" : shellQuoted(cliPath)
        switch method {
        case .native, .unknown: return "\(claude) update"
        case .npm:              return "npm install -g @anthropic-ai/claude-code@latest"
        case .homebrew:         return "brew upgrade claude-code"
        }
    }

    /// Single-quote a path for the shell. The path comes from `command -v`, not
    /// from a payload, but this string is executed, so it is quoted anyway.
    nonisolated static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Reading versions

    /// `claude --version` prints "2.1.231 (Claude Code)". Take the leading
    /// dotted number and nothing else.
    nonisolated static func parseInstalledVersion(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return "" }
        return String(trimmed[match])
    }

    /// The npm registry's document for the `latest` tag. Falls back to
    /// `dist-tags.latest`, so pointing this at the full package document
    /// instead would still work rather than silently reporting nothing.
    nonisolated static func parseLatestVersion(_ data: Data) -> String {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
        if let version = obj["version"] as? String { return parseInstalledVersion(version) }
        if let tags = obj["dist-tags"] as? [String: Any], let latest = tags["latest"] as? String {
            return parseInstalledVersion(latest)
        }
        return ""
    }

    static let registryURL = "https://registry.npmjs.org/@anthropic-ai/claude-code/latest"

    /// Anthropic's published changelog. The CLI keeps its own copy at
    /// ~/.claude/cache/changelog.md, but that copy is only as new as the last
    /// time the CLI refreshed it, so it lags exactly when it matters: right
    /// after a version you do not have yet is published.
    static let changelogURL = "https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md"

    static let localChangelogPath: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/cache/changelog.md")
    }()

    /// Ask the CLI what version it is. Runs a subprocess, so it belongs off the
    /// main thread.
    nonisolated static func readInstalled() -> (version: String, path: String) {
        guard let path = TerminalAutomator.resolveClaudePath() else { return ("", "") }
        guard let out = Shell.output(path, ["--version"]) else { return ("", path) }
        return (parseInstalledVersion(out), path)
    }

    /// The newest published version, or "" when the check could not be made.
    /// Deliberately quiet on failure: a network blip is not news.
    nonisolated static func fetchLatest(timeout: TimeInterval = 15,
                                        completion: @escaping @Sendable (String) -> Void) {
        guard let url = URL(string: registryURL) else { completion(""); return }
        var request = URLRequest(url: url)
        // Plain JSON. The abbreviated-packument media type
        // (application/vnd.npm.install-v1+json) is only accepted on the package
        // document; asking for it on the /latest tag returns 406, which read as
        // "check failed" forever. The tag document is a few hundred bytes
        // anyway, which is the reason to ask for it rather than the packument.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { completion(""); return }
            completion(parseLatestVersion(data))
        }.resume()
    }

    /// Async wrapper, so the caller can read both facts in order without
    /// nesting completion handlers inside an actor hop.
    nonisolated static func fetchLatest(timeout: TimeInterval = 15) async -> String {
        await withCheckedContinuation { continuation in
            fetchLatest(timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    // MARK: - What changed

    /// Split a changelog into `## <version>` sections, in file order.
    ///
    /// Only `- ` bullets are taken. Anything else in a section (blank lines,
    /// prose, a nested list) is skipped rather than guessed at: this text is
    /// rendered as a list of changes, and a stray paragraph rendered as a
    /// bullet reads as a change that did not happen.
    nonisolated static func parseChangelog(_ text: String) -> [ReleaseNotes] {
        var out: [ReleaseNotes] = []
        var version = ""
        var items: [String] = []

        func flush() {
            if !version.isEmpty, !items.isEmpty {
                out.append(ReleaseNotes(version: version, items: items))
            }
            version = ""
            items = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flush()
                version = parseInstalledVersion(String(line.dropFirst(3)))
                continue
            }
            guard !version.isEmpty, line.hasPrefix("- ") else { continue }
            let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !item.isEmpty { items.append(item) }
        }
        flush()
        return out
    }

    /// At most this many version sections, and bullets within one section, are
    /// worth putting on a settings page. Someone ten versions behind wants to
    /// know it is a lot, not to read all of it here.
    static let maxNoteSections = 3
    static let maxNoteItems = 6

    /// The sections describing what you would GAIN by updating: versions newer
    /// than the installed one, up to and including the newest, newest first.
    ///
    /// Returns [] when there is no update, when the versions are unknown, or
    /// when the changelog has nothing for them — all three mean the UI shows
    /// nothing rather than an empty heading.
    nonisolated static func notes(_ all: [ReleaseNotes],
                                  installed: String, latest: String) -> [ReleaseNotes] {
        guard !installed.isEmpty, !latest.isEmpty,
              UpdateChecker.isNewer(latest, than: installed) else { return [] }
        return all
            .filter { UpdateChecker.isNewer($0.version, than: installed)
                      && !UpdateChecker.isNewer($0.version, than: latest) }
            .prefix(maxNoteSections)
            .map { ReleaseNotes(version: $0.version, items: Array($0.items.prefix(maxNoteItems))) }
    }

    /// The changelog text: published copy first, the CLI's cached copy as a
    /// fallback for an offline machine. Empty when neither can be read, which
    /// costs the notes section and nothing else.
    nonisolated static func fetchChangelog(timeout: TimeInterval = 15) async -> String {
        if let url = URL(string: changelogURL) {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let text = String(data: data, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        guard let data = FileManager.default.contents(atPath: localChangelogPath),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    // MARK: - Presentation

    /// One line describing where the install stands. Pure, so the wording is
    /// testable and lives in one place.
    nonisolated static func summary(_ status: Status) -> String {
        if status.installed.isEmpty {
            return L("Claude Code was not found on this Mac.", comment: "Settings: the Claude Code CLI could not be located")
        }
        if status.updateAvailable {
            return String(format: L("Version %1$@ is installed. %2$@ is available.",
                                    comment: "Settings. %1$@ is the installed CLI version, %2$@ the newer one"),
                          status.installed, status.latest)
        }
        if status.latest.isEmpty {
            return String(format: L("Version %@ is installed.", comment: "Settings. %@ is the installed CLI version"),
                          status.installed)
        }
        return String(format: L("Version %@ is installed, which is the newest.",
                                comment: "Settings. %@ is the installed CLI version"),
                      status.installed)
    }
}
