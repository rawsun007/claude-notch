import XCTest
@testable import ClaudeNotch

/// The `ConfigChange` hook fires when a settings file changes mid-session.
/// What the app does with it splits on the `source` field: some sources change
/// what an agent is ALLOWED to do and get announced, the rest are only
/// recorded. Getting that split wrong either hides a permissions change or
/// trains the user to dismiss the card that matters.
final class ConfigChangeTests: XCTestCase {

    // MARK: - Which sources are worth a card

    func testPermissionBearingSourcesAreAnnounced() {
        for source in ["user_settings", "project_settings", "local_settings", "policy_settings"] {
            XCTAssertTrue(AppState.configChangeIsSecurity(source: source), source)
        }
    }

    func testSkillsAndUnknownSourcesAreRecordedButNotAnnounced() {
        // Skills change what Claude knows, not what it may do.
        XCTAssertFalse(AppState.configChangeIsSecurity(source: "skills"))
        // An unknown source is not assumed to be security-relevant: a future
        // CLI adding a chatty source must not start popping cards on upgrade.
        XCTAssertFalse(AppState.configChangeIsSecurity(source: "something_new"))
        XCTAssertFalse(AppState.configChangeIsSecurity(source: ""))
    }

    // MARK: - Labels

    func testEverySourceGetsItsOwnLabel() {
        let labels = ["user_settings", "project_settings", "local_settings",
                      "policy_settings", "skills"].map { AppState.configChangeLabel(source: $0) }
        // Four tiers plus skills; two tiers reading the same would make the
        // card useless, since which file changed is the whole content.
        XCTAssertEqual(Set(labels).count, labels.count, "\(labels)")
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
    }

    /// A source this build has never heard of still reads as something.
    func testAnUnknownSourceIsNamedRatherThanSwallowed() {
        let label = AppState.configChangeLabel(source: "future_tier")
        XCTAssertTrue(label.contains("future_tier"), label)
    }

    func testAMissingSourceStillHasATitle() {
        XCTAssertFalse(AppState.configChangeLabel(source: "").isEmpty)
    }

    // MARK: - Detail line

    func testHomeIsAbbreviated() {
        let path = NSHomeDirectory() + "/.claude/settings.json"
        XCTAssertEqual(AppState.configChangeDetail(source: "user_settings", filePath: path),
                       "~/.claude/settings.json")
    }

    func testALongPathKeepsItsTail() {
        let path = "/a/" + String(repeating: "deep/", count: 40) + "settings.json"
        let detail = AppState.configChangeDetail(source: "project_settings", filePath: path)
        XCTAssertEqual(detail.count, 60)
        XCTAssertTrue(detail.hasPrefix("…"), detail)
        // The file name is the informative end, so it must survive.
        XCTAssertTrue(detail.hasSuffix("settings.json"), detail)
    }

    func testNoPathFallsBackToTheSource() {
        let detail = AppState.configChangeDetail(source: "policy_settings", filePath: "")
        XCTAssertTrue(detail.contains("policy_settings"), detail)
        XCTAssertFalse(AppState.configChangeDetail(source: "", filePath: "").isEmpty)
    }

    // MARK: - Self-write suppression

    /// Installing hooks and merging allow rules both rewrite settings.json, and
    /// every live session fires ConfigChange back at us for it. Announcing the
    /// app's own edit — once per session — is the failure this guards.
    func testTheAppsOwnWriteIsMarkedAndExpires() {
        HookInstaller.noteSelfWrite()
        let sinceWrite = Date().timeIntervalSince(HookInstaller.lastSelfWriteAt)
        XCTAssertLessThan(sinceWrite, AppState.selfSettingsWriteGrace,
                          "a write that just happened must fall inside the grace window")
        // The window is short enough that a real edit a minute later is still
        // news, and long enough to cover a multi-session burst.
        XCTAssertGreaterThanOrEqual(AppState.selfSettingsWriteGrace, 5)
        XCTAssertLessThanOrEqual(AppState.selfSettingsWriteGrace, 30)
    }

    // MARK: - Golden table

    func testGoldenSourceRouting() {
        // source -> (announced?, label contains)
        let cases: [(source: String, announced: Bool, contains: String)] = [
            ("user_settings", true, "settings"),
            ("project_settings", true, "Project"),
            ("local_settings", true, "Local"),
            ("policy_settings", true, "policy"),
            ("skills", false, "Skills"),
            ("future_tier", false, "future_tier"),
        ]
        for c in cases {
            XCTAssertEqual(AppState.configChangeIsSecurity(source: c.source), c.announced, c.source)
            XCTAssertTrue(AppState.configChangeLabel(source: c.source)
                .localizedCaseInsensitiveContains(c.contains), c.source)
        }
    }
}
