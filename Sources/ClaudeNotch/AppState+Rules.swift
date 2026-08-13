import AppKit
import Foundation

// Always-allow rules: adding one by hand, and getting them out of the app.
//
// Until now a rule could only be created by clicking "Always Allow" on a card,
// and only be seen in a menu-bar submenu. They are the app's security policy,
// so they deserve somewhere you can read the whole list, add to it, and take a
// copy for Claude Code itself.

extension AppState {

    /// The rules in a stable display order: by tool, then by what they match,
    /// so the list does not reshuffle when the underlying set rehashes.
    var sortedAllowRules: [AllowRule] {
        allowRules.sorted {
            $0.tool == $1.tool
                ? $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending
                : $0.tool.localizedCaseInsensitiveCompare($1.tool) == .orderedAscending
        }
    }

    /// Add a rule typed by hand. An empty command means the whole tool.
    ///
    /// Returns false when the tool name is empty or the rule already exists, so
    /// the editor can say which of the two happened instead of appearing to do
    /// nothing.
    @discardableResult
    func addAllowRule(tool: String, command: String) -> Bool {
        let tool = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty else { return false }
        let rule = command.isEmpty
            ? AllowRule(tool: tool, commandRegex: nil)
            : AllowRule.exactCommand(tool: tool, command: command)
        guard !allowRules.contains(rule) else { return false }
        allowRules.insert(rule)
        schedulePersist()
        return true
    }

    // MARK: - Export

    /// The rules as a Claude Code settings fragment.
    ///
    /// Claude Code keeps its own allowlist in `permissions.allow`, and until now
    /// there was no way to get the notch's list into it: you would re-approve
    /// everything from scratch in a terminal session the app was not watching.
    ///
    /// A rule that cannot be expressed as a Claude Code permission is left out
    /// rather than approximated — a rule that means something subtly different
    /// from the one you read in the list is worse than a missing one.
    nonisolated static func claudePermissionsJSON(_ rules: [AllowRule]) -> String {
        // Uniqued: two rules can now export to one permission (a `Write(path)`
        // and an `Edit(path)` for the same file both become `Edit(path)`), and
        // a settings file listing the same permission twice is noise the user
        // then has to clean up by hand.
        let allow = Set(rules.compactMap(\.claudePermission)).sorted()
        let payload: [String: Any] = ["permissions": ["allow": allow]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Rules that `claudePermissionsJSON` has to leave out, so the UI can say
    /// so instead of quietly exporting a shorter list.
    nonisolated static func unexportableRules(_ rules: [AllowRule]) -> [AllowRule] {
        rules.filter { $0.claudePermission == nil }
    }

    /// Rules exported under a different tool name than the one in the list,
    /// because Claude Code 2.1.210 deprecated their `Tool(path)` form. The UI
    /// names them: the export is correct, but a rule that reads `Write` in the
    /// notch and `Edit` in settings.json needs saying out loud once.
    nonisolated static func renamedOnExport(_ rules: [AllowRule]) -> [AllowRule] {
        rules.filter(\.exportRenamesTool)
    }

    /// Copy the settings fragment to the clipboard.
    func copyAllowRulesAsJSON() {
        NSPasteboard.copyString(Self.claudePermissionsJSON(sortedAllowRules))
    }

    /// Merge the rules into `~/.claude/settings.json`, keeping a backup.
    ///
    /// Additive and idempotent: existing entries survive, ours are appended
    /// only when absent, and nothing else in the file is touched. Returns how
    /// many were newly added, or nil when the file could not be written.
    @discardableResult
    func mergeAllowRulesIntoClaudeSettings() -> Int? {
        let path = HookInstaller.settingsPath
        let url = URL(fileURLWithPath: path)
        var settings: [String: Any] = [:]
        if let existing = try? Data(contentsOf: url) {
            if let obj = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
                settings = obj
            } else {
                // Unparseable settings: refuse rather than replace a file we
                // cannot read with one we invented.
                return nil
            }
            let ts = Int(Date().timeIntervalSince1970)
            try? existing.write(to: URL(fileURLWithPath: path + ".before-claudenotch-rules.\(ts)"))
        }

        var permissions = (settings["permissions"] as? [String: Any]) ?? [:]
        var allow = (permissions["allow"] as? [String]) ?? []
        var added = 0
        for entry in sortedAllowRules.compactMap(\.claudePermission) where !allow.contains(entry) {
            allow.append(entry)
            added += 1
        }
        permissions["allow"] = allow
        settings["permissions"] = permissions

        guard let out = try? JSONSerialization.data(withJSONObject: settings,
                                                    options: [.prettyPrinted, .sortedKeys]),
              (try? out.write(to: url, options: .atomic)) != nil else { return nil }
        return added
    }
}
