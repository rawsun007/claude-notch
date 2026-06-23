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
        XCTAssertEqual(subs.first?["timeout"] as? Int, 30)
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
