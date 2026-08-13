import Foundation

// What a session's agent is allowed to do at the OS level.
//
// Claude Code 2.1.219+ can run tool calls inside a sandbox: the filesystem is
// fenced, network egress goes through a proxy that only lets an allowlist
// through (`sandbox.network.strictAllowlist`), and credentials in the
// environment can be masked so a sandboxed command never sees the real secret
// (`sandbox.credentials`). Codex has its own, simpler `sandbox_mode`.
//
// None of that arrives on a hook payload, so the app reads it the same way the
// CLI does: from the settings files, keyed by the session's cwd. Everything
// here is pure and takes its input as text, so the merge rules are testable
// without a filesystem.

enum SandboxReader {

    // MARK: - Status

    /// The effective sandbox posture for one session. `enabled == false` means
    /// tool calls run with the full rights of the user who launched the CLI.
    struct Status: Equatable {
        /// Sandboxing is on for this session's directory.
        var enabled: Bool = false
        /// Codex only: `read-only` / `workspace-write`. Empty for Claude Code,
        /// whose sandbox is described by the fields below instead.
        var mode: String = ""
        /// Network egress is denied unless a rule matches, with no implicit
        /// fallthrough. Fail-closed, so it is ON if any settings layer sets it.
        var strictAllowlist: Bool = false
        /// Domains the sandbox proxy will let through / always refuse.
        var allowedDomains: Int = 0
        var deniedDomains: Int = 0
        /// Credentials the sandbox substitutes on egress, so the command reads
        /// a sentinel rather than the real secret (`sandbox.credentials`).
        var maskedCredentials: Int = 0
        /// Commands configured to run OUTSIDE the sandbox
        /// (`sandbox.excludedCommands`).
        var excludedCommands: Int = 0
        /// The model may opt a command out of the sandbox
        /// (`sandbox.allowUnsandboxedCommands`).
        var allowUnsandboxedCommands: Bool = false
        /// No network egress at all is possible (Codex `read-only`, or
        /// `workspace-write` without `network_access`).
        var networkBlocked: Bool = false

        /// Whether anything can still reach outside the sandbox. A sandbox with
        /// an escape hatch is a weaker promise than one without, and the two
        /// must not look the same in the notch.
        var hasEscapeHatch: Bool { excludedCommands > 0 || allowUnsandboxedCommands }
    }

    /// Which badge a status deserves. Pure and free of SwiftUI so the rule
    /// itself is testable: the colours and strings are NotchMarkdown's job.
    ///
    /// `.none` covers both "no sandbox" and "nothing said either way" — an
    /// unsandboxed session is the norm, and a permanent warning on every row
    /// is one nobody can act on.
    enum Badge: Equatable {
        case none
        case sandboxed
        /// Sandboxed, but something is allowed out of it. A weaker promise
        /// than `.sandboxed`, and it must not look the same.
        case sandboxedWithExceptions
    }

    nonisolated static func badge(_ status: Status?) -> Badge {
        guard let status, status.enabled else { return .none }
        return status.hasEscapeHatch ? .sandboxedWithExceptions : .sandboxed
    }

    // MARK: - One settings layer

    /// The sandbox keys of a single settings file, before merging. Optionals
    /// are "this file said nothing", which is what lets a higher-precedence
    /// layer override rather than silently reset a lower one.
    struct Layer: Equatable {
        var enabled: Bool?
        var strictAllowlist: Bool?
        var allowUnsandboxedCommands: Bool?
        var allowedDomains: Set<String> = []
        var deniedDomains: Set<String> = []
        var excludedCommands: Set<String> = []
        var credentialCount: Int = 0
        /// Credential masking is honoured only from user, managed, or
        /// `--settings` settings: a repo you cloned must not be able to
        /// redefine what your secrets look like. Set by the caller from which
        /// file the layer came out of, not by the parser.
        var trustedForCredentials: Bool = false

        var isEmpty: Bool {
            enabled == nil && strictAllowlist == nil && allowUnsandboxedCommands == nil
                && allowedDomains.isEmpty && deniedDomains.isEmpty
                && excludedCommands.isEmpty && credentialCount == 0
        }
    }

    /// Parse the `sandbox` block out of one settings.json. Returns nil for
    /// unreadable JSON or a file with no `sandbox` key at all, so a missing
    /// file and a file that says nothing about sandboxing behave alike.
    nonisolated static func parseLayer(_ data: Data, trustedForCredentials: Bool = false) -> Layer? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sandbox = root["sandbox"] as? [String: Any] else { return nil }

        var layer = Layer()
        layer.trustedForCredentials = trustedForCredentials
        layer.enabled = sandbox["enabled"] as? Bool
        layer.allowUnsandboxedCommands = sandbox["allowUnsandboxedCommands"] as? Bool
        layer.excludedCommands = stringSet(sandbox["excludedCommands"])

        if let network = sandbox["network"] as? [String: Any] {
            layer.strictAllowlist = network["strictAllowlist"] as? Bool
            layer.allowedDomains = stringSet(network["allowedDomains"])
            layer.deniedDomains = stringSet(network["deniedDomains"])
        }

        // `credentials` is an object of named rules (files, env, and the 2.1.219
        // masking options: extract, decode, awsPairs, sigv4). All the notch
        // needs is how many secrets are being masked, so count the leaves.
        if let credentials = sandbox["credentials"] as? [String: Any] {
            layer.credentialCount = credentialLeafCount(credentials)
        }

        return layer.isEmpty ? nil : layer
    }

    /// Merge settings layers, LOWEST precedence first (user, project, local,
    /// managed). The rules mirror the CLI:
    ///
    /// - `enabled` / `allowUnsandboxedCommands`: the last layer that states a
    ///   value wins, so managed settings can turn a project's choice around.
    /// - `strictAllowlist`: true if ANY layer sets it. Fail-closed — the CLI
    ///   ORs it too, and a stricter reading is the safe way to be wrong.
    /// - domain and command lists: the union, because that is the set the
    ///   proxy ends up matching against.
    /// - credentials: counted only from layers marked trusted.
    nonisolated static func merge(_ layers: [Layer]) -> Status {
        var status = Status()
        var allowed: Set<String> = []
        var denied: Set<String> = []
        var excluded: Set<String> = []
        var credentials = 0

        for layer in layers {
            if let enabled = layer.enabled { status.enabled = enabled }
            if let unsandboxed = layer.allowUnsandboxedCommands {
                status.allowUnsandboxedCommands = unsandboxed
            }
            if layer.strictAllowlist == true { status.strictAllowlist = true }
            allowed.formUnion(layer.allowedDomains)
            denied.formUnion(layer.deniedDomains)
            excluded.formUnion(layer.excludedCommands)
            if layer.trustedForCredentials { credentials += layer.credentialCount }
        }

        status.allowedDomains = allowed.count
        status.deniedDomains = denied.count
        status.excludedCommands = excluded.count
        status.maskedCredentials = credentials
        return status
    }

    // MARK: - Reading the files

    /// Settings files that decide a Claude Code session's sandbox, lowest
    /// precedence first, paired with whether credential rules from them count.
    ///
    /// Project settings are read from the session's cwd only. A session's cwd
    /// IS its project root in every normal case, and walking parents would let
    /// an unrelated `.claude` above the checkout describe a session it has no
    /// say over.
    nonisolated static let managedSettingsPath =
        "/Library/Application Support/ClaudeCode/managed-settings.json"

    nonisolated static func settingsPaths(cwd: String, home: String,
                                          managedPath: String = managedSettingsPath)
        -> [(path: String, trusted: Bool)] {
        var paths: [(String, Bool)] = [("\(home)/.claude/settings.json", true)]
        if !cwd.isEmpty {
            paths.append(("\(cwd)/.claude/settings.json", false))
            paths.append(("\(cwd)/.claude/settings.local.json", false))
        }
        paths.append((managedPath, true))
        return paths
    }

    /// The effective Claude Code sandbox status for a directory. nil when no
    /// settings file mentions sandboxing at all — which is not the same as
    /// "off", and the notch shows nothing rather than claiming either way.
    nonisolated static func readClaude(cwd: String,
                                       home: String = NSHomeDirectory(),
                                       managedPath: String = managedSettingsPath) -> Status? {
        var layers: [Layer] = []
        for (path, trusted) in settingsPaths(cwd: cwd, home: home, managedPath: managedPath) {
            guard let data = FileManager.default.contents(atPath: path),
                  let layer = parseLayer(data, trustedForCredentials: trusted) else { continue }
            layers.append(layer)
        }
        guard !layers.isEmpty else { return nil }
        return merge(layers)
    }

    /// Codex's sandbox, from `~/.codex/config.toml`. Only what the file states
    /// is reported: Codex's default has changed between releases, and guessing
    /// it wrong would put a confident wrong badge in the notch.
    nonisolated static func parseCodexConfig(_ text: String) -> Status? {
        var table = ""
        var mode: String?
        var networkAccess: Bool?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                table = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            if table.isEmpty, key == "sandbox_mode" { mode = value }
            if table == "sandbox_workspace_write", key == "network_access" { networkAccess = (value == "true") }
        }

        guard let mode else { return nil }
        switch mode {
        case "read-only":
            return Status(enabled: true, mode: mode, networkBlocked: true)
        case "workspace-write":
            return Status(enabled: true, mode: mode, networkBlocked: networkAccess != true)
        case "danger-full-access":
            return Status(enabled: false, mode: mode)
        default:
            // An unknown mode is not a sandbox we can describe honestly.
            return nil
        }
    }

    nonisolated static func readCodex(home: String = NSHomeDirectory()) -> Status? {
        let path = "\(home)/.codex/config.toml"
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return parseCodexConfig(text)
    }

    // MARK: - Helpers

    nonisolated private static func stringSet(_ value: Any?) -> Set<String> {
        guard let list = value as? [Any] else { return [] }
        return Set(list.compactMap { $0 as? String }.filter { !$0.isEmpty })
    }

    /// How many individual secrets a `sandbox.credentials` block masks. The
    /// block groups rules by kind (`files`, `env`, …), each an array or an
    /// object keyed by name, so count the entries under each kind rather than
    /// the kinds themselves.
    nonisolated private static func credentialLeafCount(_ credentials: [String: Any]) -> Int {
        var count = 0
        for (_, group) in credentials {
            if let list = group as? [Any] { count += list.count }
            else if let dict = group as? [String: Any] { count += dict.count }
        }
        return count
    }
}
