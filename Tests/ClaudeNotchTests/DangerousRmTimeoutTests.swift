import XCTest
@testable import ClaudeNotch

/// Claude Code 2.1.281 denies a dangerous `rm` on its own after two minutes in
/// auto and bypass mode. The card has to know which requests that is, or it
/// sits there looking answerable for three minutes after the CLI said no.
final class DangerousRmTimeoutTests: XCTestCase {

    func testRecursiveRmForms() {
        for cmd in ["rm -rf build", "rm -r dist", "rm -fR node_modules", "rm --recursive out",
                    "sudo rm -rf /tmp/x", "cd app && rm -rf .build", "ls; rm -r a", "(rm -rf b)",
                    "rm -v -rf c"] {
            XCTAssertTrue(DangerousRmTimeout.isRecursiveRm(cmd), cmd)
        }
    }

    func testNotRecursiveRm() {
        for cmd in ["rm file.txt", "rm -f a.log", "git rm -r --cached x", "echo rm -rf", "npm run rm-rf-build",
                    "grep -r rm src", "trim -rf"] {
            XCTAssertFalse(DangerousRmTimeout.isRecursiveRm(cmd), cmd)
        }
    }

    func testOnlyInAutoAndBypassMode() {
        let input: [String: Any] = ["command": "rm -rf build"]
        XCTAssertTrue(DangerousRmTimeout.applies(toolName: "Bash", toolInput: input, permissionMode: "auto"))
        XCTAssertTrue(DangerousRmTimeout.applies(toolName: "Bash", toolInput: input, permissionMode: "bypassPermissions"))
        XCTAssertFalse(DangerousRmTimeout.applies(toolName: "Bash", toolInput: input, permissionMode: "default"))
        XCTAssertFalse(DangerousRmTimeout.applies(toolName: "Bash", toolInput: input, permissionMode: ""))
        XCTAssertFalse(DangerousRmTimeout.applies(toolName: "Edit", toolInput: input, permissionMode: "auto"))
    }

    func testCardExpiresOnTheCLIClock() {
        let req = PermissionRequest(kind: .toolUse, title: "Run shell command", detail: "rm -rf build", toolName: "Bash",
                                    source: "Claude Code", cwd: "/tmp", receivedAt: Date().addingTimeInterval(-121)) { _, _ in }
        XCTAssertFalse(req.hasExpired, "without the CLI deadline the notch's own 285 s window applies")
        req.cliDeadline = DangerousRmTimeout.window
        XCTAssertTrue(req.hasExpired)
    }

    func testClock() {
        XCTAssertEqual(DangerousRmTimeout.clock(120), "2:00")
        XCTAssertEqual(DangerousRmTimeout.clock(101.2), "1:42")
        XCTAssertEqual(DangerousRmTimeout.clock(-3), "0:00")
    }
}
