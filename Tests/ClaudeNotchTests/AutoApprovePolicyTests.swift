import XCTest
@testable import ClaudeNotch

final class AutoApprovePolicyTests: XCTestCase {
    private func verdict(enabled: Bool = true, scope: AutoApproveScope = .everything,
                         dangerous: AutoApproveDangerous = .ask, tool: String = "Bash",
                         isDangerous: Bool = false, strict: Bool = false) -> AutoApproveVerdict {
        AutoApprovePolicy.verdict(enabled: enabled, scope: scope, dangerous: dangerous,
                                  toolName: tool, isDangerous: isDangerous, strictBlocks: strict)
    }

    func testOffShowsTheCard() {
        XCTAssertEqual(verdict(enabled: false), .showCard)
        XCTAssertEqual(verdict(enabled: false, dangerous: .allow, isDangerous: true), .showCard)
    }

    func testEverythingAllowsAnySafeTool() {
        for tool in ["Bash", "Edit", "WebFetch", "mcp__github__create_issue"] {
            XCTAssertEqual(verdict(tool: tool), .allow, tool)
        }
    }

    func testCommandsOnlyCoversShellToolsOfBothAgents() {
        for tool in ["Bash", "exec_command", "shell", "unified_exec"] {
            XCTAssertEqual(verdict(scope: .commands, tool: tool), .allow, tool)
        }
        for tool in ["Edit", "Write", "WebFetch", "apply_patch"] {
            XCTAssertEqual(verdict(scope: .commands, tool: tool), .showCard, tool)
        }
    }

    func testFilesOnlyCoversReadsAndEditsNotCommands() {
        for tool in ["Read", "Edit", "Write", "MultiEdit", "Grep", "apply_patch"] {
            XCTAssertEqual(verdict(scope: .files, tool: tool), .allow, tool)
        }
        XCTAssertEqual(verdict(scope: .files, tool: "Bash"), .showCard)
        XCTAssertEqual(verdict(scope: .files, tool: "WebFetch"), .showCard)
    }

    func testDangerousFollowsTheChoice() {
        XCTAssertEqual(verdict(dangerous: .ask, isDangerous: true), .showCard)
        XCTAssertEqual(verdict(dangerous: .biometric, isDangerous: true), .confirmWithBiometrics)
        XCTAssertEqual(verdict(dangerous: .allow, isDangerous: true), .allow)
    }

    func testDangerousOutsideTheScopeStillAsks() {
        XCTAssertEqual(verdict(scope: .files, dangerous: .allow, tool: "Bash", isDangerous: true), .showCard)
    }

    func testStrictModeWinsOverEveryChoice() {
        XCTAssertEqual(verdict(strict: true), .showCard)
        XCTAssertEqual(verdict(dangerous: .allow, isDangerous: true, strict: true), .showCard)
        XCTAssertEqual(verdict(dangerous: .biometric, isDangerous: true, strict: true), .showCard)
    }

    func testOnlyTurningOnSilentDangerousApprovalNeedsAuthentication() {
        XCTAssertTrue(AutoApprovePolicy.needsAuthentication(from: .ask, to: .allow))
        XCTAssertTrue(AutoApprovePolicy.needsAuthentication(from: .biometric, to: .allow))
        XCTAssertFalse(AutoApprovePolicy.needsAuthentication(from: .allow, to: .allow))
        XCTAssertFalse(AutoApprovePolicy.needsAuthentication(from: .allow, to: .ask))
        XCTAssertFalse(AutoApprovePolicy.needsAuthentication(from: .ask, to: .biometric))
    }
}
