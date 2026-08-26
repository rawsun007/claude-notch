import XCTest
@testable import ClaudeNotch

/// Where a CLI exists it is the cheaper way in, because a command costs nothing
/// until it runs while an MCP server spends context every session. The advice
/// is only worth giving when the command is actually installed.
final class CLIOverMCPTests: XCTestCase {

    // MARK: - Reading a tool name

    func testTheServerNameIsPulledOut() {
        XCTAssertEqual(CLIOverMCP.serverName(fromTool: "mcp__github__create_issue"), "github")
        XCTAssertEqual(CLIOverMCP.serverName(fromTool: "mcp__GitHub__x"), "github")
    }

    /// Server names contain hyphens, so the split has to be on the double
    /// underscore rather than on anything inside the name.
    func testHyphenatedServersSurvive() {
        XCTAssertEqual(CLIOverMCP.serverName(fromTool: "mcp__google-cloud__run"), "google-cloud")
    }

    func testOrdinaryToolsAreNotMCP() {
        for tool in ["Bash", "Read", "Edit", "", "mcp__", "mcp__nounderscores"] {
            XCTAssertNil(CLIOverMCP.serverName(fromTool: tool), tool)
        }
    }

    // MARK: - Mapping to a command

    func testKnownServersMapToTheirCommand() {
        XCTAssertEqual(CLIOverMCP.command(forTool: "mcp__github__list_prs"), "gh")
        XCTAssertEqual(CLIOverMCP.command(forTool: "mcp__aws__s3_ls"), "aws")
        XCTAssertEqual(CLIOverMCP.command(forTool: "mcp__kubernetes__pods"), "kubectl")
    }

    /// Real server names are often decorated, so a substring match is what
    /// makes this useful rather than exact-only.
    func testDecoratedServerNamesStillMatch() {
        XCTAssertEqual(CLIOverMCP.command(forTool: "mcp__claude_ai_github__x"), "gh")
    }

    func testUnknownServersHaveNoAdvice() {
        XCTAssertNil(CLIOverMCP.command(forTool: "mcp__figma__get_file"))
        XCTAssertNil(CLIOverMCP.command(forTool: "Bash"))
    }

    func testTheCardNamesTheCommand() {
        XCTAssertTrue(CLIOverMCP.cardTitle(command: "gh").contains("gh"))
        XCTAssertTrue(CLIOverMCP.cardDetail(command: "gh").contains("gh"))
    }

    // MARK: - On a session

    @MainActor
    private func mcpCards(_ s: AppState) -> Int {
        s.permissionQueue.filter { $0.toolName == "MCP" }.count
    }

    /// `gh` is installed in this repo's environment, so this is the real path.
    @MainActor
    func testAnInstalledCommandIsSuggestedOnce() throws {
        let s = AppState()
        s.cliPresenceCache["gh"] = true      // pinned, so the test does not depend on the machine
        s.noteMCPToolUse(tool: "mcp__github__create_issue")
        s.noteMCPToolUse(tool: "mcp__github__list_prs")
        XCTAssertEqual(mcpCards(s), 1, "once per command, not once per call")
    }

    /// The case that must stay silent: suggesting a command somebody does not
    /// have is homework, not advice.
    @MainActor
    func testAMissingCommandIsNeverSuggested() {
        let s = AppState()
        s.cliPresenceCache["gh"] = false
        s.noteMCPToolUse(tool: "mcp__github__create_issue")
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }

    @MainActor
    func testOrdinaryToolsRaiseNothing() {
        let s = AppState()
        s.cliPresenceCache["gh"] = true
        for tool in ["Bash", "Read", "mcp__figma__get_file"] { s.noteMCPToolUse(tool: tool) }
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }

    @MainActor
    func testTheNudgeSettingSilencesIt() {
        let s = AppState()
        s.setCompactAdviceEnabled(false)
        s.cliPresenceCache["gh"] = true
        s.noteMCPToolUse(tool: "mcp__github__create_issue")
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }
}
