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
