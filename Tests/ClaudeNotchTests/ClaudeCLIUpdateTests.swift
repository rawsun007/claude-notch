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

    // MARK: - Release notes

    private let changelog = """
    # Changelog

    ## 2.1.232

    - Subagent forking is now on by default
    - Type `@` in the prompt to mention another Claude session

    ## 2.1.231

    - Fixed MCP OAuth sign-in failing with a redirect URI mismatch

    ## 2.1.230

    Some prose that is not a bullet.

    - Fixed a crash on resume

    ## 2.1.229

    - Documented `claude remote-control --continue`
    """

    func testTheChangelogSplitsIntoVersionSections() {
        let all = ClaudeCLIUpdate.parseChangelog(changelog)
        XCTAssertEqual(all.map(\.version), ["2.1.232", "2.1.231", "2.1.230", "2.1.229"])
        XCTAssertEqual(all.first?.items.count, 2)
        // Prose inside a section is not a change; rendered as a bullet it would
        // read as one.
        XCTAssertEqual(all[2].items, ["Fixed a crash on resume"])
    }

    func testOnlyTheVersionsYouWouldGainAreShown() {
        let all = ClaudeCLIUpdate.parseChangelog(changelog)
        let notes = ClaudeCLIUpdate.notes(all, installed: "2.1.230", latest: "2.1.232")
        // Newer than installed, no newer than latest, newest first. The version
        // you are ON is not news, and one you cannot get yet is not either.
        XCTAssertEqual(notes.map(\.version), ["2.1.232", "2.1.231"])
    }

    /// The user's rule: if we do not have the notes, show nothing.
    func testNothingIsShownWhenThereIsNothingToSay() {
        let all = ClaudeCLIUpdate.parseChangelog(changelog)
        // Already current.
        XCTAssertTrue(ClaudeCLIUpdate.notes(all, installed: "2.1.232", latest: "2.1.232").isEmpty)
        // Check failed, so latest is unknown.
        XCTAssertTrue(ClaudeCLIUpdate.notes(all, installed: "2.1.232", latest: "").isEmpty)
        // CLI not found.
        XCTAssertTrue(ClaudeCLIUpdate.notes(all, installed: "", latest: "2.1.232").isEmpty)
        // An update exists but the changelog could not be fetched.
        XCTAssertTrue(ClaudeCLIUpdate.notes([], installed: "2.1.231", latest: "2.1.232").isEmpty)
        // An update exists but the changelog has no section for it.
        XCTAssertTrue(ClaudeCLIUpdate.notes(all, installed: "2.1.232", latest: "2.1.240").isEmpty)
    }

    /// Someone ten versions behind wants to know it is a lot, not to read all
    /// of it on a settings page.
    func testTheNotesAreCapped() {
        let manySections = (1...10).map { i in
            "## 2.2.\(i)\n\n" + (1...12).map { "- item \($0)" }.joined(separator: "\n")
        }.reversed().joined(separator: "\n\n")
        let all = ClaudeCLIUpdate.parseChangelog(manySections)
        let notes = ClaudeCLIUpdate.notes(all, installed: "2.1.0", latest: "2.2.10")
        XCTAssertEqual(notes.count, ClaudeCLIUpdate.maxNoteSections)
        XCTAssertTrue(notes.allSatisfy { $0.items.count <= ClaudeCLIUpdate.maxNoteItems })
        // Newest first, so the cap keeps the versions you care about most.
        XCTAssertEqual(notes.first?.version, "2.2.10")
    }

    func testAnEmptyOrJunkChangelogParsesToNothing() {
        XCTAssertTrue(ClaudeCLIUpdate.parseChangelog("").isEmpty)
        XCTAssertTrue(ClaudeCLIUpdate.parseChangelog("no headings here\n- a bullet").isEmpty)
        // A heading with no bullets is not a section worth showing.
        XCTAssertTrue(ClaudeCLIUpdate.parseChangelog("## 2.1.232\n\nnothing\n").isEmpty)
    }

    // MARK: - The script that reaches the shell

    /// `status` is read-only in zsh, and these scripts run under zsh. Assigning
    /// to it made every update report "read-only variable: status" and skipped
    /// the line saying whether the update worked.
    func testTheScriptDoesNotAssignToAReadOnlyZshVariable() {
        let script = TerminalAutomator.updateScript(command: "claude update")
        XCTAssertFalse(script.contains("status=$?"), script)
        XCTAssertTrue(script.contains("rc=$?"), script)
    }

    /// The line that SHOWS the user what is about to run must not run any of
    /// it. A path can contain `$(` or a backtick, and inside double quotes the
    /// shell would execute that while merely echoing.
    func testTheCommandIsDisplayedWithoutBeingExpanded() {
        let script = TerminalAutomator.updateScript(command: "'/tmp/$(touch /tmp/x)/claude' update")
        // Displayed through a quoted here-document, which expands nothing.
        XCTAssertTrue(script.contains("<<'CLAUDENOTCH_CMD'"), script)
        XCTAssertFalse(script.contains("echo \"$ "), script)
    }

    func testTheScriptReportsBothOutcomes() {
        let script = TerminalAutomator.updateScript(command: "claude update")
        XCTAssertTrue(script.contains("if [ $rc -eq 0 ]"), script)
        // Open sessions keep the binary they launched with, and not saying so
        // makes a successful update look like it did nothing.
        XCTAssertTrue(script.localizedCaseInsensitiveContains("restart"), script)
        XCTAssertTrue(script.localizedCaseInsensitiveContains("exited with status"), script)
    }

    /// The window must not close on completion: the output is the only
    /// evidence of what happened.
    func testTheScriptDoesNotExecAwayTheShell() {
        XCTAssertFalse(TerminalAutomator.updateScript(command: "claude update").contains("exec "))
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
