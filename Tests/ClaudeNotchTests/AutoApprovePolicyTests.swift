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

/// The choices, through the real queue: what gets allowed without a card,
/// what still waits, and what History says about it.
@MainActor
final class AutoApproveQueueTests: XCTestCase {
    private func state(scope: AutoApproveScope, dangerous: AutoApproveDangerous) -> AppState {
        let state = AppState()
        state.allowRules.removeAll()
        state.permissionQueue.removeAll()
        state.enforceBudget = false
        state.mirrorToNotificationCenter = false
        state.soundMuted = true
        state.strictMode = false
        state.autoApprove = true
        state.autoApproveScope = scope
        state.autoApproveDangerous = dangerous
        return state
    }

    private func request(_ tool: String, _ detail: String) -> (PermissionRequest, () -> PermissionDecision?) {
        var decision: PermissionDecision?
        // EventServer runs the danger scan and passes its reasons in; do the
        // same, so the request is flagged exactly as a real one would be.
        let reasons = ToolPreviewParser.dangerReasons(for: tool, input: ["command": detail])
        let req = PermissionRequest(kind: .toolUse, title: "Run", detail: detail, toolName: tool,
                                    source: "Test", cwd: "/tmp", dangerReasons: reasons,
                                    resolver: { d, _ in decision = d })
        return (req, { decision })
    }

    func testTheDangerousCommandUsedHereIsFlagged() {
        XCTAssertTrue(request("Bash", "rm -rf ~/project").0.isDangerous)
    }

    func testDefaultChoiceStillHoldsADestructiveCommand() {
        let s = state(scope: .everything, dangerous: .ask)
        let (req, decision) = request("Bash", "rm -rf ~/project")
        s.enqueuePermission(req)
        XCTAssertNil(decision())
        XCTAssertEqual(s.permissionQueue.count, 1)
    }

    func testApproveThemTooAllowsAndLogsItAsDestructive() {
        let s = state(scope: .everything, dangerous: .allow)
        let (req, decision) = request("Bash", "rm -rf ~/project")
        s.enqueuePermission(req)
        XCTAssertEqual(decision(), .allow)
        XCTAssertTrue(s.permissionQueue.isEmpty)
        // Look the entry up rather than taking the newest: AppState() loads
        // whatever History other tests on this machine persisted.
        let entry = s.history.first { $0.detail.contains("rm -rf ~/project") }
        XCTAssertEqual(entry?.outcome, .dangerous)
        XCTAssertTrue(entry?.detail.contains("auto-approved") ?? false)
    }

    func testBiometricChoiceShowsTheCardFirst() {
        let s = state(scope: .everything, dangerous: .biometric)
        let (req, decision) = request("Bash", "rm -rf ~/project")
        s.enqueuePermission(req)
        XCTAssertNil(decision(), "only a successful Touch ID may allow it")
        XCTAssertEqual(s.permissionQueue.count, 1)
        // Take the card away before the prompt it scheduled can run: a test
        // runner has nobody to put a finger on the sensor.
        s.permissionQueue.removeAll()
    }

    func testCommandsOnlyLeavesAnEditForTheCard() {
        let s = state(scope: .commands, dangerous: .ask)
        let (cmd, cmdDecision) = request("Bash", "swift build")
        let (edit, editDecision) = request("Edit", "Sources/App.swift")
        s.enqueuePermission(cmd)
        s.enqueuePermission(edit)
        XCTAssertEqual(cmdDecision(), .allow)
        XCTAssertNil(editDecision())
        XCTAssertEqual(s.permissionQueue.count, 1)
    }

    func testFilesOnlyLeavesACommandForTheCard() {
        let s = state(scope: .files, dangerous: .allow)
        let (cmd, cmdDecision) = request("Bash", "rm -rf ~/project")
        let (edit, editDecision) = request("Edit", "Sources/App.swift")
        s.enqueuePermission(cmd)
        s.enqueuePermission(edit)
        XCTAssertNil(cmdDecision(), "a command is outside Files only, destructive or not")
        XCTAssertEqual(editDecision(), .allow)
    }

    func testStrictModeStillHoldsADestructiveCommandWhenApproveThemTooIsChosen() {
        let s = state(scope: .everything, dangerous: .allow)
        s.strictMode = true
        let (req, decision) = request("Bash", "rm -rf ~/project")
        s.enqueuePermission(req)
        XCTAssertNil(decision())
    }
}
