import XCTest
@testable import ClaudeNotch

/// Which state a skill is in, what it costs in that state, and which ones the
/// page suggests turning down.
final class SkillRulesTests: XCTestCase {

    private func skill(_ name: String, _ source: SkillInfo.Source = .personal, desc: String = String(repeating: "d", count: 400),
                       project: String? = nil, plugin: String? = nil, hidden: Bool = false) -> SkillInfo {
        SkillInfo(name: name, source: source, project: project, plugin: plugin, description: desc, whenToUse: "",
                  modelInvocationDisabled: hidden, path: "/s/" + name, bytes: 0, modified: nil)
    }

    func testDefaultIsOn() {
        XCTAssertEqual(AppState.visibility(of: skill("a"), user: [:], project: nil, pluginEnabled: [:]), .on)
    }

    func testProjectOverrideWinsOverUser() {
        let s = skill("a", .project, project: "/repo")
        XCTAssertEqual(AppState.visibility(of: s, user: ["a": .off], project: ["a": .nameOnly], pluginEnabled: [:]), .nameOnly)
        XCTAssertEqual(AppState.visibility(of: s, user: ["a": .off], project: [:], pluginEnabled: [:]), .off)
    }

    func testPluginSkillsFollowThePlugin() {
        let s = skill("vercel:nextjs", .plugin, plugin: "vercel@x")
        XCTAssertEqual(AppState.visibility(of: s, user: ["vercel:nextjs": .off], project: nil, pluginEnabled: [:]), .on)
        XCTAssertEqual(AppState.visibility(of: s, user: [:], project: nil, pluginEnabled: ["vercel@x": false]), .off)
    }

    func testFrontmatterHiddenReadsAsUserOnly() {
        XCTAssertEqual(AppState.visibility(of: skill("a", hidden: true), user: [:], project: nil, pluginEnabled: [:]), .userOnly)
    }

    func testListedChars() {
        let s = skill("abc", desc: "0123456789")
        XCTAssertEqual(AppState.listedChars(s, .on), 3 + 4 + 10)
        XCTAssertEqual(AppState.listedChars(s, .nameOnly), 3 + 4)
        XCTAssertEqual(AppState.listedChars(s, .userOnly), 0)
        XCTAssertEqual(AppState.listedChars(s, .off), 0)
    }

    func testBudget() {
        XCTAssertEqual(AppState.listingBudgetTokens(contextWindow: 1_000_000), 10_000)
        XCTAssertEqual(AppState.listingBudgetTokens(contextWindow: 200_000, fraction: 0.02), 4_000)
    }

    func testSuggestionsSkipUsedPluginCheapAndAlreadyOff() {
        let big = skill("big", desc: String(repeating: "x", count: 900))
        let used = skill("used")
        let cheap = skill("cheap", desc: "tiny")
        let plugin = skill("p:x", .plugin, plugin: "p@m")
        let off = skill("off")
        let all = [big, used, cheap, plugin, off]
        var states: [String: SkillSettings.Visibility] = [:]
        for s in all { states[s.id] = .on }
        states[off.id] = .off
        let out = AppState.suggestions(all, states: states, usage: ["used": SkillUse(count: 2, last: Date())])
        XCTAssertEqual(out.map(\.name), ["big"])
    }
}
