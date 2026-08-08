import XCTest
@testable import ClaudeNotch

/// A tool call arrives as text and agents put credentials in commands. That
/// text is displayed, spoken by VoiceOver, shown in a notification the lock
/// screen may render, written to `state.json` for five hundred entries, and
/// exported to CSV. None of those need the secret.
///
/// Both directions are load-bearing. A missed secret is the bug this exists to
/// stop; a mangled command is worse, because the card exists so someone can
/// judge whether to allow it, and a wall of `[redacted]` cannot be judged.
/// @MainActor to reach PermissionCard, matching how AnnouncerTests does it.
@MainActor
final class SecretRedactorTests: XCTestCase {

    private func redact(_ s: String) -> String { SecretRedactor.redact(s) }
    private func assertUnchanged(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(redact(s), s, file: file, line: line)
    }

    // MARK: - Vendor formats

    func testVendorTokensGoWhole() {
        XCTAssertEqual(redact("curl -H \"Authorization: Bearer ghp_\(String(repeating: "a", count: 36))\""),
                       "curl -H \"Authorization: Bearer [redacted]\"")
        XCTAssertEqual(redact("export ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwx"),
                       "export ANTHROPIC_API_KEY=[redacted]")
        XCTAssertEqual(redact("aws configure set aws_access_key_id AKIAIOSFODNN7EXAMPLE"),
                       "aws configure set aws_access_key_id [redacted]")
        XCTAssertEqual(redact("echo AIza\(String(repeating: "b", count: 35))"), "echo [redacted]")
        XCTAssertEqual(redact("slack post xoxb-123456789012-abcdefghijkl"), "slack post [redacted]")
    }

    func testJWTGoesWhole() {
        XCTAssertEqual(
            redact("curl -H 'Authorization: Bearer eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0NTY.SflKxwRJSMeKKF2QT4'"),
            "curl -H 'Authorization: Bearer [redacted]'")
    }

    func testPrivateKeyBlockGoesEntirely() {
        let cmd = "echo \"-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nsecretline\n-----END RSA PRIVATE KEY-----\" > k.pem"
        let out = redact(cmd)
        XCTAssertFalse(out.contains("MIIEow"))
        XCTAssertFalse(out.contains("secretline"))
        XCTAssertTrue(out.hasSuffix("> k.pem"), "the rest of the command survives: \(out)")
    }

    // MARK: - Values, where the name is kept so the command stays readable

    func testAssignmentKeepsTheName() {
        XCTAssertEqual(redact("export STRIPE_SECRET=hunter2andmore"), "export STRIPE_SECRET=[redacted]")
        XCTAssertEqual(redact("MY_API_KEY=abc123 ./run.sh"), "MY_API_KEY=[redacted] ./run.sh")
    }

    /// The unquoted rule stops at the first space, which would leave the tail of
    /// a quoted secret in place. The quoted rule runs first for that reason.
    func testQuotedValueWithSpaces() {
        XCTAssertEqual(redact("export DB_PASSWORD='p@ss w0rd'"), "export DB_PASSWORD='[redacted]'")
        XCTAssertEqual(redact("export DB_PASSWORD=\"two words\""), "export DB_PASSWORD=\"[redacted]\"")
    }

    /// A `\b` before `--` never fires, because a space and a dash are both
    /// non-word characters. The flag rule silently did nothing for the ordinary
    /// ` --token x` and caught ` --with-token x` only by accident, through the
    /// word boundary inside it.
    func testFlagValueAtAWordStart() {
        XCTAssertEqual(redact("mycli --token abc123xyz"), "mycli --token [redacted]")
        XCTAssertEqual(redact("mycli --password=s3cr3t"), "mycli --password=[redacted]")
        XCTAssertEqual(redact("gh auth login --with-token abcdefghijklmnop"),
                       "gh auth login --with-token [redacted]")
        XCTAssertEqual(redact("deploy --api-key K123 --force"), "deploy --api-key [redacted] --force")
    }

    func testConnectionStringPassword() {
        XCTAssertEqual(redact("psql postgres://admin:hunter2@db.example.com/app"),
                       "psql postgres://admin:[redacted]@db.example.com/app")
    }

    // MARK: - The false-positive side

    /// If these were mangled the card could not be judged, which is worse than
    /// the leak this file exists to stop.
    func testOrdinaryCommandsAreUntouched() {
        assertUnchanged("git status")
        assertUnchanged("rm -rf /tmp/build")
        assertUnchanged("swift build -c release")
        assertUnchanged("curl https://api.example.com/v1/users")
        assertUnchanged("git commit -m 'add token parsing'")
        assertUnchanged("cat ~/.ssh/id_rsa")
        assertUnchanged("")
    }

    /// Names that merely look credential-shaped, and one flag that is a
    /// well-known trap: `--password-stdin` takes no argument, so the separator
    /// has to be an equals or whitespace.
    func testNearMissesAreUntouched() {
        assertUnchanged("export PATH=/usr/local/bin:$PATH")
        assertUnchanged("export NODE_ENV=production")
        assertUnchanged("export AUTH_MODE=oauth")
        assertUnchanged("docker login --password-stdin")
        assertUnchanged("echo $GITHUB_TOKEN")
        assertUnchanged("sk-test")
    }

    func testContainsSecretAgreesWithRedact() {
        XCTAssertTrue(SecretRedactor.containsSecret("export API_KEY=abc123"))
        XCTAssertFalse(SecretRedactor.containsSecret("git status"))
    }

    // MARK: - The sinks

    /// One call covers the drawer, the settings page, `state.json` and every
    /// export, because all of them are built from the stored entry.
    func testHistoryEntryRedactsOnTheWayIn() {
        let entry = HistoryEntry(timestamp: Date(), kind: .permission, toolName: "Bash",
                                 title: "Run shell command",
                                 detail: "export STRIPE_SECRET=hunter2andmore",
                                 project: "app", outcome: .allowed)
        let stored = entry.redacted()
        XCTAssertEqual(stored.detail, "export STRIPE_SECRET=[redacted]")
        XCTAssertEqual(stored.id, entry.id, "identity has to survive so the list does not reshuffle")
        XCTAssertEqual(stored.outcome, entry.outcome)
        XCTAssertEqual(stored.project, "app")
    }

    /// VoiceOver reads the card aloud, and a spoken credential carries further
    /// than a displayed one.
    func testSpokenAskIsRedacted() {
        let req = PermissionRequest(kind: .toolUse, title: "Run shell command",
                                    detail: "curl -H 'Authorization: Bearer eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0NTY.SflKxwRJSMeKKF2QT4'",
                                    toolName: "Bash", source: "Claude Code", cwd: "/tmp",
                                    resolver: { _, _ in })
        let spoken = PermissionCard.spokenAsk(for: req)
        XCTAssertTrue(spoken.contains("[redacted]"))
        XCTAssertFalse(spoken.contains("SflKxwRJSMeKKF2QT4"))
    }

    /// The rule has to keep matching the true command. Redacting the request
    /// itself would store a rule against `--token [redacted]`, which would then
    /// approve every other command sharing that shape: a far worse bug than the
    /// one being fixed.
    func testTheRequestItselfIsNotRedacted() {
        let raw = "deploy --token abc123xyz"
        let req = PermissionRequest(kind: .toolUse, title: "Run shell command", detail: raw,
                                    toolName: "Bash", source: "Claude Code", cwd: "/tmp",
                                    resolver: { _, _ in })
        XCTAssertEqual(req.detail, raw, "redaction belongs at the sinks, not at the source")

        let rule = AllowRule.exactCommand(tool: "Bash", command: req.detail)
        XCTAssertTrue(rule.matches(req), "the rule still matches the command it was learned from")

        let other = PermissionRequest(kind: .toolUse, title: "Run shell command",
                                      detail: "deploy --token DIFFERENT", toolName: "Bash",
                                      source: "Claude Code", cwd: "/tmp", resolver: { _, _ in })
        XCTAssertFalse(rule.matches(other), "a different secret must not satisfy the rule")
    }
}
