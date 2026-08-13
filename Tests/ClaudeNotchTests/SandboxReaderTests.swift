import XCTest
@testable import ClaudeNotch

/// SandboxReader answers "what is this agent allowed to do" from the settings
/// files, which is a claim the notch then puts on screen next to a permission
/// prompt. Getting it wrong in the safe direction (claiming a sandbox that
/// isn't there) is the failure that matters, so the merge rules are pinned
/// here: precedence, the fail-closed OR on strictAllowlist, credential trust,
/// and the exact rendered summary for a table of realistic configurations.
final class SandboxReaderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func layer(_ json: String, trusted: Bool = false) -> SandboxReader.Layer? {
        SandboxReader.parseLayer(Data(json.utf8), trustedForCredentials: trusted)
    }

    /// Write `json` to `<dir>/.claude/<name>`.
    private func writeSettings(_ json: String, in dir: URL, name: String) throws {
        let claude = dir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try json.write(to: claude.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// A canonical one-line rendering of a Status. The golden table compares
    /// against these strings, so any field that changes meaning shows up as a
    /// diff in the expected literal rather than passing silently.
    private func summary(_ s: SandboxReader.Status?) -> String {
        guard let s else { return "none" }
        var parts = ["enabled=\(s.enabled)"]
        if !s.mode.isEmpty { parts.append("mode=\(s.mode)") }
        parts.append("strict=\(s.strictAllowlist)")
        parts.append("allow=\(s.allowedDomains)")
        parts.append("deny=\(s.deniedDomains)")
        parts.append("creds=\(s.maskedCredentials)")
        parts.append("excluded=\(s.excludedCommands)")
        parts.append("unsandboxed=\(s.allowUnsandboxedCommands)")
        parts.append("netBlocked=\(s.networkBlocked)")
        parts.append("escape=\(s.hasEscapeHatch)")
        return parts.joined(separator: " ")
    }

    // MARK: - Parsing one layer

    func testNoSandboxKeyIsNotALayer() {
        XCTAssertNil(layer(#"{"permissions": {"allow": ["Bash"]}}"#))
    }

    func testEmptySandboxBlockIsNotALayer() {
        // `"sandbox": {}` states nothing, so it must not count as a layer and
        // must not be read as "sandboxing is off".
        XCTAssertNil(layer(#"{"sandbox": {}}"#))
    }

    func testMalformedJSONIsNotALayer() {
        XCTAssertNil(layer(#"{"sandbox": {"enabled": true"#))
    }

    func testParsesTheFullSandboxBlock() throws {
        let l = try XCTUnwrap(layer(#"""
        {
          "sandbox": {
            "enabled": true,
            "allowUnsandboxedCommands": false,
            "excludedCommands": ["docker", "kubectl"],
            "network": {
              "strictAllowlist": true,
              "allowedDomains": ["api.anthropic.com", "github.com"],
              "deniedDomains": ["evil.example"]
            },
            "credentials": {
              "env": {"GITHUB_TOKEN": {"decode": "jwt"}, "AWS_SECRET_ACCESS_KEY": {}},
              "files": ["~/.aws/credentials"]
            }
          }
        }
        """#, trusted: true))
        XCTAssertEqual(l.enabled, true)
        XCTAssertEqual(l.strictAllowlist, true)
        XCTAssertEqual(l.allowUnsandboxedCommands, false)
        XCTAssertEqual(l.allowedDomains, ["api.anthropic.com", "github.com"])
        XCTAssertEqual(l.deniedDomains, ["evil.example"])
        XCTAssertEqual(l.excludedCommands, ["docker", "kubectl"])
        XCTAssertEqual(l.credentialCount, 3)   // two env entries + one file
    }

    // MARK: - Merge rules

    func testHigherPrecedenceLayerWinsOnEnabled() {
        let user = layer(#"{"sandbox": {"enabled": true}}"#)!
        let project = layer(#"{"sandbox": {"enabled": false}}"#)!
        // Lowest precedence first: the project layer is later, so it wins.
        XCTAssertFalse(SandboxReader.merge([user, project]).enabled)
        XCTAssertTrue(SandboxReader.merge([project, user]).enabled)
    }

    func testSilentLayerDoesNotResetALowerOne() {
        let user = layer(#"{"sandbox": {"enabled": true}}"#)!
        // Says nothing about `enabled`, so the user layer must survive.
        let project = layer(#"{"sandbox": {"excludedCommands": ["docker"]}}"#)!
        let merged = SandboxReader.merge([user, project])
        XCTAssertTrue(merged.enabled)
        XCTAssertEqual(merged.excludedCommands, 1)
    }

    func testStrictAllowlistIsOredAcrossLayers() {
        let user = layer(#"{"sandbox": {"network": {"strictAllowlist": true}}}"#)!
        let project = layer(#"{"sandbox": {"network": {"strictAllowlist": false}}}"#)!
        // Fail-closed, matching the CLI: any layer asking for strict gets it,
        // whichever order they merge in.
        XCTAssertTrue(SandboxReader.merge([user, project]).strictAllowlist)
        XCTAssertTrue(SandboxReader.merge([project, user]).strictAllowlist)
    }

    func testDomainListsAreUnionedNotReplaced() {
        let user = layer(#"{"sandbox": {"network": {"allowedDomains": ["a.com", "b.com"]}}}"#)!
        let project = layer(#"{"sandbox": {"network": {"allowedDomains": ["b.com", "c.com"]}}}"#)!
        XCTAssertEqual(SandboxReader.merge([user, project]).allowedDomains, 3)
    }

    func testCredentialsCountOnlyFromTrustedLayers() {
        let untrusted = layer(#"{"sandbox": {"credentials": {"env": {"A": {}, "B": {}}}}}"#,
                              trusted: false)!
        let trusted = layer(#"{"sandbox": {"credentials": {"env": {"C": {}}}}}"#, trusted: true)!
        // A checked-in project file must not be able to claim your secrets are
        // masked; only user and managed settings are honoured.
        XCTAssertEqual(SandboxReader.merge([untrusted]).maskedCredentials, 0)
        XCTAssertEqual(SandboxReader.merge([untrusted, trusted]).maskedCredentials, 1)
    }

    // MARK: - Precedence order of the real files

    func testSettingsPathOrderAndCredentialTrust() {
        let paths = SandboxReader.settingsPaths(cwd: "/w/proj", home: "/Users/x",
                                                managedPath: "/managed.json")
        XCTAssertEqual(paths.map(\.path), [
            "/Users/x/.claude/settings.json",
            "/w/proj/.claude/settings.json",
            "/w/proj/.claude/settings.local.json",
            "/managed.json",
        ])
        XCTAssertEqual(paths.map(\.trusted), [true, false, false, true])
    }

    func testReadClaudeMergesTheFilesOnDisk() throws {
        let home = root.appendingPathComponent("home")
        let cwd = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try writeSettings(#"{"sandbox": {"enabled": true, "credentials": {"env": {"T": {}}}}}"#,
                          in: home, name: "settings.json")
        try writeSettings(#"{"sandbox": {"network": {"strictAllowlist": true, "allowedDomains": ["x.com"]}}}"#,
                          in: cwd, name: "settings.json")
        try writeSettings(#"{"sandbox": {"excludedCommands": ["docker"]}}"#,
                          in: cwd, name: "settings.local.json")

        let status = try XCTUnwrap(SandboxReader.readClaude(cwd: cwd.path, home: home.path,
                                                            managedPath: "/nonexistent.json"))
        XCTAssertEqual(summary(status),
                       "enabled=true strict=true allow=1 deny=0 creds=1 excluded=1 unsandboxed=false netBlocked=false escape=true")
    }

    func testReadClaudeReturnsNilWhenNothingMentionsSandboxing() throws {
        let home = root.appendingPathComponent("home")
        let cwd = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try writeSettings(#"{"model": "opus"}"#, in: home, name: "settings.json")
        // Not "off" — unknown. The notch must be able to tell the two apart.
        XCTAssertNil(SandboxReader.readClaude(cwd: cwd.path, home: home.path,
                                              managedPath: "/nonexistent.json"))
    }

    func testManagedSettingsOverrideTheProject() throws {
        let home = root.appendingPathComponent("home")
        let cwd = root.appendingPathComponent("proj")
        let managed = root.appendingPathComponent("managed.json")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try writeSettings(#"{"sandbox": {"enabled": false}}"#, in: cwd, name: "settings.json")
        try #"{"sandbox": {"enabled": true}}"#.write(to: managed, atomically: true, encoding: .utf8)

        let status = try XCTUnwrap(SandboxReader.readClaude(cwd: cwd.path, home: home.path,
                                                            managedPath: managed.path))
        XCTAssertTrue(status.enabled)
    }

    // MARK: - Codex

    func testCodexReadOnlyBlocksTheNetwork() throws {
        let status = try XCTUnwrap(SandboxReader.parseCodexConfig("""
        model = "gpt-5"
        sandbox_mode = "read-only"
        """))
        XCTAssertEqual(summary(status),
                       "enabled=true mode=read-only strict=false allow=0 deny=0 creds=0 excluded=0 unsandboxed=false netBlocked=true escape=false")
    }

    func testCodexWorkspaceWriteHonoursNetworkAccess() throws {
        let off = try XCTUnwrap(SandboxReader.parseCodexConfig(#"sandbox_mode = "workspace-write""#))
        XCTAssertTrue(off.networkBlocked)

        let on = try XCTUnwrap(SandboxReader.parseCodexConfig("""
        sandbox_mode = "workspace-write"   # comments are ignored

        [sandbox_workspace_write]
        network_access = true
        """))
        XCTAssertTrue(on.enabled)
        XCTAssertFalse(on.networkBlocked)
    }

    func testCodexNetworkAccessOutsideItsTableIsIgnored() throws {
        // The same key under another table says nothing about the sandbox.
        let status = try XCTUnwrap(SandboxReader.parseCodexConfig("""
        sandbox_mode = "workspace-write"

        [some_other_table]
        network_access = true
        """))
        XCTAssertTrue(status.networkBlocked)
    }

    func testCodexDangerFullAccessIsNotASandbox() throws {
        let status = try XCTUnwrap(SandboxReader.parseCodexConfig(#"sandbox_mode = "danger-full-access""#))
        XCTAssertFalse(status.enabled)
    }

    func testCodexUnsetOrUnknownModeReportsNothing() {
        // Codex's default has moved between releases; claiming one would put a
        // confident wrong badge on screen.
        XCTAssertNil(SandboxReader.parseCodexConfig("model = \"gpt-5\""))
        XCTAssertNil(SandboxReader.parseCodexConfig(#"sandbox_mode = "something-new""#))
    }

    // MARK: - Badge mapping

    func testBadgeIsSilentWhenUnknownOrOff() {
        XCTAssertEqual(SandboxReader.badge(nil), .none)
        XCTAssertEqual(SandboxReader.badge(SandboxReader.Status(enabled: false)), .none)
        // Off with tight-sounding network rules is still off: the rules only
        // bite inside a sandbox, and a green badge here would be a lie.
        XCTAssertEqual(SandboxReader.badge(SandboxReader.Status(enabled: false,
                                                                strictAllowlist: true)),
                       .none)
    }

    func testBadgeSeparatesACleanSandboxFromOneWithAWayOut() {
        XCTAssertEqual(SandboxReader.badge(SandboxReader.Status(enabled: true)), .sandboxed)
        XCTAssertEqual(SandboxReader.badge(SandboxReader.Status(enabled: true, excludedCommands: 1)),
                       .sandboxedWithExceptions)
        XCTAssertEqual(SandboxReader.badge(SandboxReader.Status(enabled: true,
                                                                allowUnsandboxedCommands: true)),
                       .sandboxedWithExceptions)
    }

    // MARK: - Golden table

    /// One rendered line per realistic configuration. These strings are the
    /// contract the notch's badge is derived from.
    func testGoldenStatusTable() throws {
        let cases: [(name: String, json: String, expected: String)] = [
            ("off",
             #"{"sandbox": {"enabled": false}}"#,
             "enabled=false strict=false allow=0 deny=0 creds=0 excluded=0 unsandboxed=false netBlocked=false escape=false"),
            ("plain on",
             #"{"sandbox": {"enabled": true}}"#,
             "enabled=true strict=false allow=0 deny=0 creds=0 excluded=0 unsandboxed=false netBlocked=false escape=false"),
            ("strict allowlist",
             #"{"sandbox": {"enabled": true, "network": {"strictAllowlist": true, "allowedDomains": ["api.anthropic.com"], "deniedDomains": ["a.io", "b.io"]}}}"#,
             "enabled=true strict=true allow=1 deny=2 creds=0 excluded=0 unsandboxed=false netBlocked=false escape=false"),
            ("masked credentials",
             #"{"sandbox": {"enabled": true, "credentials": {"env": {"GITHUB_TOKEN": {"decode": "jwt"}}, "files": ["~/.aws/credentials", "~/.npmrc"]}}}"#,
             "enabled=true strict=false allow=0 deny=0 creds=3 excluded=0 unsandboxed=false netBlocked=false escape=false"),
            ("escape hatch: excluded commands",
             #"{"sandbox": {"enabled": true, "excludedCommands": ["docker"]}}"#,
             "enabled=true strict=false allow=0 deny=0 creds=0 excluded=1 unsandboxed=false netBlocked=false escape=true"),
            ("escape hatch: agent may opt out",
             #"{"sandbox": {"enabled": true, "allowUnsandboxedCommands": true}}"#,
             "enabled=true strict=false allow=0 deny=0 creds=0 excluded=0 unsandboxed=true netBlocked=false escape=true"),
        ]
        for c in cases {
            let l = try XCTUnwrap(layer(c.json, trusted: true), c.name)
            XCTAssertEqual(summary(SandboxReader.merge([l])), c.expected, c.name)
        }
    }
}
