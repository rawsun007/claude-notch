import Foundation

// MARK: - An MCP server doing a command's job

extension AppState {

    /// Say once, per command, when a session uses an MCP tool for a service
    /// whose CLI is already installed here.
    ///
    /// Called on every tool call, so the cheap checks come first: most tool
    /// names are not MCP at all and leave immediately. Whether the command
    /// exists is only asked once per command and then remembered, because it is
    /// a filesystem lookup and the answer does not change mid-session.
    func noteMCPToolUse(tool: String) {
        guard compactAdviceEnabled, tool.hasPrefix("mcp__") else { return }
        guard let command = CLIOverMCP.command(forTool: tool) else { return }
        guard !cliOverMCPAdvised.contains(command) else { return }

        let installed: Bool
        if let known = cliPresenceCache[command] {
            installed = known
        } else {
            installed = Shell.succeeds("/usr/bin/env",
                                       ["sh", "-c", "command -v \(command) >/dev/null 2>&1"])
            cliPresenceCache[command] = installed
        }
        // Recommending a command somebody does not have is homework, not advice.
        guard installed else { return }

        cliOverMCPAdvised.insert(command)
        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: CLIOverMCP.cardTitle(command: command),
            detail: CLIOverMCP.cardDetail(command: command),
            toolName: "MCP",
            source: "ClaudeNotch",
            cwd: currentCwd,
            resolver: { _, _ in }))
    }
}
