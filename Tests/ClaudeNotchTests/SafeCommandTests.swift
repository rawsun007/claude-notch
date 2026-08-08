import XCTest
@testable import ClaudeNotch

/// Strict Mode's allowlist. `dangerReasons` is a denylist and is never
/// finished, so this answers the other question: is the command *known* to be
/// harmless. Only a yes may skip the card.
///
/// The rule is one sentence: a safe command looks at things and changes
/// nothing. No building, no testing, no running a script, no network. Being
/// wrong in the strict direction costs a click; being wrong the other way costs
/// whatever the command did.
final class SafeCommandTests: XCTestCase {

    private func isSafe(_ command: String, tool: String = "Bash") -> Bool {
        SafeCommand.isSafe(tool: tool, detail: command)
    }

    func testReadOnlyShellCommands() {
        for command in ["git status", "git log --oneline -20", "git diff HEAD~1",
                        "git show abc123", "git blame file.swift", "git", "git --version",
                        "ls", "ls -la", "pwd", "cat README.md", "head -20 file", "wc -l x",
                        "grep -rn foo .", "rg pattern", "jq . data.json", "which swift",
                        "docker ps", "docker images", "npm list", "npm outdated",
                        "kubectl get pods", "pip3 freeze", "cargo tree", "go version",
                        "diff a b", "sort x", "echo hi"] {
            XCTAssertTrue(isSafe(command), "should be safe: \(command)")
        }
    }

    func testAbsolutePathIsJudgedOnTheSameList() {
        XCTAssertTrue(isSafe("/usr/bin/git status"))
        XCTAssertFalse(isSafe("/usr/bin/git push"))
    }

    func testLeadingEnvironmentPrefixIsNotTheCommand() {
        XCTAssertTrue(isSafe("FOO=bar ls"))
        XCTAssertFalse(isSafe("FOO=bar rm -r x"))
    }

    /// The subcommand carries the meaning. Each of these shares a first word
    /// with something on the list.
    func testMutatingSubcommandsOfSafeVerbs() {
        for command in ["git reset --hard", "git branch -D feature", "git stash",
                        "git config user.email a@b.c", "git push", "git commit -m x",
                        "git checkout main", "npm install", "npm publish",
                        "docker run alpine", "docker rm x", "kubectl delete pod x",
                        "brew install jq"] {
            XCTAssertFalse(isSafe(command), "should not be safe: \(command)")
        }
    }

    /// Ordinary, mostly fine, and all of it executes code somebody else wrote.
    /// In Strict Mode that is worth a click.
    func testBuildingAndRunningIsNotSafe() {
        for command in ["swift build", "swift test", "cargo build", "go build ./...",
                        "npm run build", "npm test", "make", "make deploy",
                        "python3 script.py", "node -e 'x'", "ruby x.rb"] {
            XCTAssertFalse(isSafe(command), "should not be safe: \(command)")
        }
    }

    /// Changes no file, but it is how a prompt injection arrives and how data
    /// leaves.
    func testNetworkIsNotSafe() {
        XCTAssertFalse(isSafe("curl https://example.com"))
        XCTAssertFalse(isSafe("wget http://x"))
        XCTAssertFalse(isSafe("gh pr create"))
    }

    /// A pipe can end in a shell, a redirect writes, a substitution runs, and a
    /// separator hides a second command behind a harmless first one.
    func testCompoundLinesAreNeverSafe() {
        for command in ["ls | sh", "ls; rm -rf x", "echo x > file", "cat $(whoami)",
                        "echo `id`", "git status && npm publish", "ls < input",
                        "git status\nnpm publish"] {
            XCTAssertFalse(isSafe(command), "should not be safe: \(command)")
        }
    }

    func testReadOnlyTools() {
        for tool in ["Grep", "Glob", "LS", "BashOutput", "TaskList", "read_file"] {
            XCTAssertTrue(isSafe("anything at all", tool: tool), tool)
        }
    }

    /// Read is absent on purpose: Claude Code prompts for it in directories you
    /// have not trusted yet, so it is a real question about a real boundary.
    func testToolsThatStillAsk() {
        for tool in ["Read", "Write", "Edit", "WebFetch", "WebSearch", "Task", "NotebookEdit"] {
            XCTAssertFalse(isSafe("anything at all", tool: tool), tool)
        }
    }

    /// The two checks must never disagree in the unsafe direction.
    func testAnythingTheDangerScanDislikesIsNotSafe() {
        for command in ["rm -rf /tmp/x", "sudo ls", "echo k >> ~/.ssh/authorized_keys"] {
            XCTAssertFalse(isSafe(command), "should not be safe: \(command)")
            XCTAssertFalse(ToolPreviewParser.dangerReasons(for: "Bash", input: ["command": command]).isEmpty,
                           "fixture should be flagged by the danger scan: \(command)")
        }
    }

    func testEdges() {
        XCTAssertFalse(isSafe(""))
        XCTAssertFalse(isSafe("   "))
        XCTAssertFalse(isSafe(String(repeating: "a", count: 500)))
    }
}

/// Strict Mode narrows the *blanket* approvals only. An exact-command rule is
/// a specific decision about a specific command, which is the opposite of a
/// blanket, and taking it away would make the setting mean "ignore what I told
/// you" and nobody would leave it on.
@MainActor
final class StrictModeQueueTests: XCTestCase {

    /// AppState() loads whatever is persisted on this machine, so anything the
    /// assertions depend on is set explicitly rather than inherited.
    private func cleanState(strict: Bool, autoApprove: Bool = false) -> AppState {
        let state = AppState()
        state.allowRules.removeAll()
        state.permissionQueue.removeAll()
        state.enforceBudget = false
        state.mirrorToNotificationCenter = false
        state.soundMuted = true
        state.autoApprove = autoApprove
        state.strictMode = strict
        return state
    }

    private func request(_ command: String) -> (PermissionRequest, () -> PermissionDecision?) {
        var decision: PermissionDecision?
        let req = PermissionRequest(kind: .toolUse, title: "Run shell command",
                                    detail: command, toolName: "Bash",
                                    source: "Test", cwd: "/tmp",
                                    resolver: { d, _ in decision = d })
        return (req, { decision })
    }

    func testAutoApproveStillPassesASafeCommand() {
        let state = cleanState(strict: true, autoApprove: true)
        let (req, decision) = request("git status")
        state.enqueuePermission(req)
        XCTAssertEqual(decision(), .allow)
        XCTAssertTrue(state.permissionQueue.isEmpty)
    }

    func testAutoApproveHoldsAnUnsafeCommandUnderStrictMode() {
        let state = cleanState(strict: true, autoApprove: true)
        let (req, decision) = request("swift build")
        state.enqueuePermission(req)
        XCTAssertNil(decision(), "nothing should have been decided for the user")
        XCTAssertEqual(state.permissionQueue.count, 1)
    }

    /// Without Strict Mode this is exactly the command Auto-Approve waves
    /// through, which is what makes the test above meaningful.
    func testTheSameCommandPassesWithStrictModeOff() {
        let state = cleanState(strict: false, autoApprove: true)
        let (req, decision) = request("swift build")
        state.enqueuePermission(req)
        XCTAssertEqual(decision(), .allow)
    }

    func testToolWideRuleStopsApplyingToUnsafeCommands() {
        let state = cleanState(strict: true)
        state.allowRules.insert(AllowRule(tool: "Bash", commandRegex: nil))
        let (req, decision) = request("swift build")
        state.enqueuePermission(req)
        XCTAssertNil(decision())
        XCTAssertEqual(state.permissionQueue.count, 1)
    }

    func testExactCommandRuleSurvivesStrictMode() {
        let state = cleanState(strict: true)
        state.allowRules.insert(AllowRule.exactCommand(tool: "Bash", command: "swift build"))
        let (req, decision) = request("swift build")
        state.enqueuePermission(req)
        XCTAssertEqual(decision(), .allow, "a rule made for one exact command is not a blanket")
    }
}
