import XCTest
@testable import ClaudeNotch

/// The Settings page offers to run a command in the user's terminal that
/// replaces the Claude Code binary every session on the machine will launch.
/// Two things must be right: the version comparison that decides whether to
/// offer it at all, and the command chosen for how this copy was installed.
/// Running `npm install -g` against a native install, or the reverse, does
/// nothing useful and looks like the app is broken.
final class ClaudeCLIUpdateTests: XCTestCase {

    // MARK: - Which install is this

    /// Real paths from real installs, including the awkward one: a Homebrew
    /// node prefix holding an npm install, which npm updates, not brew.
    func testGoldenInstallMethodTable() {
        let cases: [(path: String, method: ClaudeCLIUpdate.Method)] = [
            ("/Users/me/.local/bin/claude", .native),
            ("/Users/me/.local/share/claude/versions/2.1.231", .native),
            ("/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe", .npm),
            ("/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude", .npm),
            ("/Users/me/.nvm/versions/node/v22.3.0/bin/claude", .npm),
            ("/Users/me/.npm-global/bin/claude", .npm),
            ("/opt/homebrew/Cellar/claude-code/2.1.231/bin/claude", .homebrew),
            ("/usr/local/bin/claude", .unknown),
            ("", .unknown),
        ]
        for c in cases {
            XCTAssertEqual(ClaudeCLIUpdate.method(forPath: c.path), c.method, c.path)
        }
    }

    /// A Homebrew-installed npm package is updated by npm. The path contains
    /// both signals, and testing them in the wrong order picks the wrong one.
    func testANpmInstallUnderHomebrewIsNpmNotHomebrew() {
        let path = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
        XCTAssertEqual(ClaudeCLIUpdate.method(forPath: path), .npm)
        XCTAssertEqual(ClaudeCLIUpdate.command(for: .npm, cliPath: path),
                       "npm install -g @anthropic-ai/claude-code@latest")
    }

    // MARK: - The command

    func testGoldenCommandTable() {
        let path = "/Users/me/.local/bin/claude"
        XCTAssertEqual(ClaudeCLIUpdate.command(for: .native, cliPath: path),
                       "'/Users/me/.local/bin/claude' update")
        // An install we cannot classify still gets the CLI's own updater: it is
        // non-destructive, and it explains itself when it cannot help.
        XCTAssertEqual(ClaudeCLIUpdate.command(for: .unknown, cliPath: path),
                       "'/Users/me/.local/bin/claude' update")
        XCTAssertEqual(ClaudeCLIUpdate.command(for: .homebrew, cliPath: path),
                       "brew upgrade claude-code")
        // No path found: fall back to whatever the shell resolves.
        XCTAssertEqual(ClaudeCLIUpdate.command(for: .native, cliPath: ""), "claude update")
    }

    /// This string is executed in a shell. A space or a quote in the path must
    /// not become two words or an injection.
    func testAnAwkwardPathIsQuoted() {
        let path = "/Users/me/my tools/claude"
        XCTAssertEqual(ClaudeCLIUpdate.command(for: .native, cliPath: path),
                       "'/Users/me/my tools/claude' update")
        XCTAssertEqual(ClaudeCLIUpdate.shellQuoted("/tmp/a'b; rm -rf /"),
                       "'/tmp/a'\\''b; rm -rf /'")
    }

    // MARK: - Reading versions

    func testTheCLIVersionLineIsParsed() {
        XCTAssertEqual(ClaudeCLIUpdate.parseInstalledVersion("2.1.231 (Claude Code)"), "2.1.231")
        XCTAssertEqual(ClaudeCLIUpdate.parseInstalledVersion("  2.1.231 (Claude Code)\n"), "2.1.231")
        XCTAssertEqual(ClaudeCLIUpdate.parseInstalledVersion("claude 2.1.231"), "2.1.231")
        XCTAssertEqual(ClaudeCLIUpdate.parseInstalledVersion(""), "")
        XCTAssertEqual(ClaudeCLIUpdate.parseInstalledVersion("command not found"), "")
    }

    func testTheRegistryDocumentIsParsed() {
        let json = #"{"name":"@anthropic-ai/claude-code","version":"2.1.232","dist":{}}"#
        XCTAssertEqual(ClaudeCLIUpdate.parseLatestVersion(Data(json.utf8)), "2.1.232")
        XCTAssertEqual(ClaudeCLIUpdate.parseLatestVersion(Data("not json".utf8)), "")
        XCTAssertEqual(ClaudeCLIUpdate.parseLatestVersion(Data("{}".utf8)), "")
    }

    /// Pointed at the package document rather than the tag document, the answer
    /// is under dist-tags. Reading one shape and not the other would report
    /// "no update" forever, which is the quietest possible way to be wrong.
    func testThePackageDocumentShapeAlsoParses() {
        let json = #"{"name":"@anthropic-ai/claude-code","dist-tags":{"latest":"2.1.232"}}"#
        XCTAssertEqual(ClaudeCLIUpdate.parseLatestVersion(Data(json.utf8)), "2.1.232")
    }

    /// The tag endpoint answers 406 to the abbreviated-packument media type,
    /// which the first cut of this asked for: every check failed, and a failed
    /// check is silent by design, so it looked like "you are up to date".
    func testTheRegistryURLIsTheTagDocument() {
        XCTAssertEqual(ClaudeCLIUpdate.registryURL,
                       "https://registry.npmjs.org/@anthropic-ai/claude-code/latest")
    }

    // MARK: - When to offer the update

    func testAnUpdateIsOfferedOnlyWhenBothVersionsAreKnown() {
        var status = ClaudeCLIUpdate.Status(installed: "2.1.231", latest: "2.1.232")
        XCTAssertTrue(status.updateAvailable)

        // A failed check must not read as "up to date"...
        status.latest = ""
        XCTAssertFalse(status.updateAvailable)
        // ...and neither must a CLI we could not find.
        status = ClaudeCLIUpdate.Status(installed: "", latest: "2.1.232")
        XCTAssertFalse(status.updateAvailable)
    }

    func testTheSameOrNewerInstalledVersionIsNotAnUpdate() {
        XCTAssertFalse(ClaudeCLIUpdate.Status(installed: "2.1.232", latest: "2.1.232").updateAvailable)
        // Running a build newer than the registry's latest happens on the
        // native installer's own channel; it is not a reason to nag.
        XCTAssertFalse(ClaudeCLIUpdate.Status(installed: "2.1.233", latest: "2.1.232").updateAvailable)
    }

    /// Patch numbers pass 9 constantly on this release train, so a string
    /// comparison would call 2.1.9 newer than 2.1.231.
    func testVersionsAreComparedNumerically() {
        XCTAssertTrue(ClaudeCLIUpdate.Status(installed: "2.1.9", latest: "2.1.231").updateAvailable)
        XCTAssertFalse(ClaudeCLIUpdate.Status(installed: "2.1.231", latest: "2.1.9").updateAvailable)
    }

    // MARK: - Wording

    func testGoldenSummaryTable() {
        let notFound = ClaudeCLIUpdate.summary(ClaudeCLIUpdate.Status())
        XCTAssertTrue(notFound.localizedCaseInsensitiveContains("not found"), notFound)

        let behind = ClaudeCLIUpdate.summary(.init(installed: "2.1.231", latest: "2.1.232"))
        XCTAssertTrue(behind.contains("2.1.231") && behind.contains("2.1.232"), behind)

        let current = ClaudeCLIUpdate.summary(.init(installed: "2.1.232", latest: "2.1.232"))
        XCTAssertTrue(current.contains("2.1.232"), current)
        XCTAssertFalse(current.localizedCaseInsensitiveContains("available"), current)

        // Check failed: state the installed version and claim nothing else.
        let unknown = ClaudeCLIUpdate.summary(.init(installed: "2.1.231", latest: ""))
        XCTAssertTrue(unknown.contains("2.1.231"), unknown)
        XCTAssertFalse(unknown.localizedCaseInsensitiveContains("newest"), unknown)
        XCTAssertFalse(unknown.localizedCaseInsensitiveContains("available"), unknown)
    }
}
