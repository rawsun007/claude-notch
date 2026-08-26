import Foundation

// An MCP server doing a job the machine already has a command for.
//
// Anthropic's own guidance is blunt about this: where a CLI exists, it is the
// most context-efficient way to talk to an external service, because the model
// already knows the tool or can read its --help, and nothing has to be loaded
// up front. An MCP server for the same service costs tool definitions in every
// session whether or not it gets used.
//
// This only speaks when both halves are true: the session actually used an MCP
// tool for a service, and the corresponding command is installed on this
// machine. Recommending `gh` to somebody who does not have it is not advice, it
// is homework.
//
// Pure and nonisolated: parsing a tool name and looking up a table.
enum CLIOverMCP {

    /// MCP server name to the command that covers the same ground.
    ///
    /// Deliberately short. Every entry here is a service whose CLI is the
    /// documented, first-class way in, not merely something with a binary.
    static let equivalents: [String: String] = [
        "github": "gh",
        "aws": "aws",
        "gcloud": "gcloud",
        "google-cloud": "gcloud",
        "docker": "docker",
        "kubernetes": "kubectl",
        "sentry": "sentry-cli",
        "vercel": "vercel",
        "supabase": "supabase",
        "stripe": "stripe",
        "heroku": "heroku",
    ]

    /// The server name out of an MCP tool name, or nil when it is not one.
    ///
    /// Claude Code spells them `mcp__<server>__<tool>`. The server half can
    /// contain hyphens, so the split is on the double underscore rather than on
    /// anything inside the name.
    nonisolated static func serverName(fromTool tool: String) -> String? {
        guard tool.hasPrefix("mcp__") else { return nil }
        let rest = tool.dropFirst("mcp__".count)
        guard let range = rest.range(of: "__") else { return nil }
        let server = String(rest[rest.startIndex..<range.lowerBound])
        return server.isEmpty ? nil : server.lowercased()
    }

    /// The command that covers this MCP tool, if there is one this app knows.
    ///
    /// Matched on the whole server name and on its parts, so both
    /// `mcp__github__x` and a server called `claude_ai_GitHub` resolve.
    nonisolated static func command(forTool tool: String) -> String? {
        guard let server = serverName(fromTool: tool) else { return nil }
        if let direct = equivalents[server] { return direct }
        for (key, cli) in equivalents where server.contains(key) { return cli }
        return nil
    }

    // MARK: - What it says

    nonisolated static func cardTitle(command: String) -> String {
        String(format: L("This session is using an MCP server for something %@ does",
                         comment: "Card title suggesting a CLI instead of an MCP server. %@ is a command name"),
               command)
    }

    nonisolated static func cardDetail(command: String) -> String {
        String(format: L("%@ is installed here. A command costs nothing until it runs, while an MCP server spends context on tool definitions in every session, used or not.",
                         comment: "Card body explaining why a CLI is cheaper than an MCP server. %@ is a command name"),
               command)
    }
}
