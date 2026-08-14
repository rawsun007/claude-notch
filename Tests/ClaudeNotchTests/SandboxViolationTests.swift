import XCTest
@testable import ClaudeNotch

/// Claude Code 2.1.224 puts sandbox denials into the Bash tool result inside a
/// `<sandbox_violations>` block. That block's inner format is not a documented
/// contract, so the parser is built to degrade rather than guess: it reports
/// every line it finds, classifies the shapes it knows, and keeps the raw text
/// for the rest. These tests pin both halves — what it recognizes, and what it
/// does when it recognizes nothing.
final class SandboxViolationTests: XCTestCase {

    private func parse(_ response: Any?) -> [SandboxViolationParser.Violation] {
        SandboxViolationParser.violations(in: response)
    }

    private func wrap(_ body: String) -> String {
        "some command output\n<sandbox_violations>\n\(body)\n</sandbox_violations>\n"
    }

    // MARK: - The common case: no violations at all

    func testOrdinaryOutputProducesNothing() {
        XCTAssertTrue(parse("total 24\ndrwxr-xr-x  5 me staff").isEmpty)
        XCTAssertTrue(parse(nil).isEmpty)
        XCTAssertTrue(parse(NSNull()).isEmpty)
        XCTAssertTrue(parse(["stdout": "", "stderr": ""]).isEmpty)
        XCTAssertTrue(parse(42).isEmpty)
    }

    /// Truncated output can cut the block in half. Half a violation list
    /// presented as the whole one is worse than none.
    func testAnUnterminatedBlockIsIgnored() {
        XCTAssertTrue(parse("<sandbox_violations>\nBlocked network request to a.com").isEmpty)
    }

    // MARK: - Where the block can live

    func testTheBlockIsFoundInStderrAndInAStringResult() {
        let body = "Blocked network request to api.example.com"
        XCTAssertEqual(parse(wrap(body)).count, 1)
        XCTAssertEqual(parse(["stderr": wrap(body)]).count, 1)
        XCTAssertEqual(parse(["stdout": "ok", "stderr": wrap(body)]).count, 1)
        XCTAssertEqual(parse(["content": wrap(body)]).count, 1)
    }

    // MARK: - Classification

    func testANetworkDenialNamesTheHost() throws {
        let v = try XCTUnwrap(parse(wrap("Blocked network request to api.example.com (allowManagedDomainsOnly)")).first)
        XCTAssertEqual(v.kind, .network)
        XCTAssertEqual(v.target, "api.example.com")
        XCTAssertTrue(SandboxViolationParser.summary(v).contains("api.example.com"))
    }

    func testAHostWithAPortSurvives() throws {
        let v = try XCTUnwrap(parse(wrap("Blocked network request to registry.npmjs.org:443")).first)
        XCTAssertEqual(v.target, "registry.npmjs.org:443")
    }

    func testAFileDenialNamesThePath() throws {
        let v = try XCTUnwrap(parse(wrap("denied write to /Users/me/.aws/credentials")).first)
        XCTAssertEqual(v.kind, .file)
        XCTAssertEqual(v.target, "/Users/me/.aws/credentials")
    }

    func testAQuotedTargetIsRead() throws {
        let v = try XCTUnwrap(parse(wrap("credential file deny for '~/.npmrc'")).first)
        XCTAssertEqual(v.target, "~/.npmrc")
    }

    /// A line this build cannot classify is still a violation, and still shown.
    func testAnUnrecognizedLineIsKeptVerbatim() throws {
        let v = try XCTUnwrap(parse(wrap("seccomp: syscall 41 refused")).first)
        XCTAssertEqual(v.raw, "seccomp: syscall 41 refused")
        XCTAssertEqual(SandboxViolationParser.summary(v), "seccomp: syscall 41 refused")
    }

    // MARK: - Shape of the list

    func testBulletsAndBlankLinesAreCleanedUp() {
        let items = parse(wrap("- Blocked network request to a.example.com\n\n  • denied read of /etc/hosts\n"))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].target, "a.example.com")
        XCTAssertEqual(items[1].kind, .file)
    }

    /// A loop can produce hundreds of denials in one command; the card and the
    /// history file are not the place to render all of them.
    func testTheListIsCapped() {
        let body = (1...50).map { "Blocked network request to h\($0).example.com" }.joined(separator: "\n")
        XCTAssertEqual(parse(wrap(body)).count, SandboxViolationParser.maxViolations)
    }

    func testALongLineIsTruncated() {
        let long = "Blocked network request to " + String(repeating: "a", count: 500)
        XCTAssertEqual(parse(wrap(long)).first?.raw.count, SandboxViolationParser.maxLineLength)
    }

    /// This text goes into a card and into the history file on disk. A blocked
    /// curl carries the header it was blocked with.
    func testACredentialInAViolationIsRedacted() throws {
        let line = "Blocked network request to api.example.com for curl -H 'Authorization: Bearer sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKKK'"
        let v = try XCTUnwrap(parse(wrap(line)).first)
        XCTAssertFalse(v.raw.contains("sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKKK"), v.raw)
        XCTAssertEqual(v.target, "api.example.com")
    }

    // MARK: - Golden table

    /// Line in, (kind, target) out. The table is what the card and the history
    /// entry are built from.
    func testGoldenViolationTable() {
        let cases: [(line: String, kind: SandboxViolationParser.Kind, target: String)] = [
            ("Blocked network request to api.anthropic.com", .network, "api.anthropic.com"),
            ("Blocked network request to 10.0.0.5:8080", .network, "10.0.0.5:8080"),
            ("network egress denied: github.com", .network, "github.com"),
            ("denied write to /tmp/out.txt", .file, "/tmp/out.txt"),
            ("read denied for path ~/.ssh/id_rsa", .file, "~/.ssh/id_rsa"),
            ("credential file deny for '/etc/passwd'", .file, "/etc/passwd"),
            ("something entirely new", .other, ""),
        ]
        for c in cases {
            let items = parse(wrap(c.line))
            XCTAssertEqual(items.count, 1, c.line)
            XCTAssertEqual(items.first?.kind, c.kind, c.line)
            XCTAssertEqual(items.first?.target, c.target, c.line)
        }
    }
}
