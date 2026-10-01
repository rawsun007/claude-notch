import XCTest
@testable import ClaudeNotch

/// PostToolBatch and UserPromptExpansion, the hook events added in 2026. Only
/// names and short typed text are read from their payloads.
final class ToolBatchAndExpansionTests: XCTestCase {
    func testBatchSummaryRanksByCount() {
        let calls: [[String: Any]] = [["tool_name": "Grep"], ["tool_name": "Read"], ["tool_name": "Read"],
                                      ["tool_name": "Read"], ["tool_name": "Grep"], ["tool_name": "Glob"]]
        let b = EventServer.toolBatchSummary(from: ["tool_calls": calls])
        XCTAssertEqual(b?.count, 6)
        XCTAssertEqual(b?.summary, "Read ×3, Grep ×2, Glob")
    }

    func testBatchSummaryCapsTheList() {
        let calls = ["A", "B", "C", "D", "E", "F"].map { ["tool_name": $0] as [String: Any] }
        XCTAssertEqual(EventServer.toolBatchSummary(from: ["tool_calls": calls])?.summary, "A, B, C, D, +2 more")
    }

    func testBatchSummaryNeedsCalls() {
        XCTAssertNil(EventServer.toolBatchSummary(from: [:]))
        XCTAssertNil(EventServer.toolBatchSummary(from: ["tool_calls": []]))
    }

    func testExpansionLine() {
        let l = EventServer.promptExpansionLine(from: ["command_name": "deploy", "command_args": "staging  ", "expansion_type": "slash_command"])
        XCTAssertEqual(l?.title, "/deploy")
        XCTAssertEqual(l?.detail, "staging")
        XCTAssertEqual(EventServer.promptExpansionLine(from: ["command_name": "/review", "expansion_type": "mcp_prompt"])?.title, "/review (MCP prompt)")
        XCTAssertNil(EventServer.promptExpansionLine(from: ["command_name": "  "]))
    }

    func testExpansionCapsTypedText() {
        let l = EventServer.promptExpansionLine(from: ["command_name": "x", "command_args": String(repeating: "a", count: 5000)])
        XCTAssertEqual(l?.detail.count, 200)
    }
}
