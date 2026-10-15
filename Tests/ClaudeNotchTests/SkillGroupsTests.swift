import XCTest
@testable import ClaudeNotch

/// The Skills page shows one row per source. A plugin with thirty skills is
/// one row, the costliest source comes first, and a group's state reads as
/// mixed when its skills differ.
final class SkillGroupsTests: XCTestCase {

    private func skill(_ name: String, _ source: SkillInfo.Source, project: String? = nil, plugin: String? = nil, chars: Int = 400) -> SkillInfo {
        SkillInfo(name: name, source: source, project: project, plugin: plugin, description: String(repeating: "d", count: chars), whenToUse: "",
                  modelInvocationDisabled: false, path: "/s/" + name, bytes: 0, modified: nil)
    }

    func testOneRowPerSourceCostliestFirst() {
        var skills = [skill("mine", .personal, chars: 40), skill("anthropic-skills:pdf", .synced), skill("deploy", .project, project: "/r/app")]
        for i in 0..<30 { skills.append(skill("vercel:s\(i)", .plugin, plugin: "vercel@m")) }
        let groups = AppState.skillGroups(skills, states: [:], pluginDescriptions: ["vercel@m": "Build and deploy web apps"])
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.first?.title, "Vercel")
        XCTAssertEqual(groups.first?.items.count, 30)
        XCTAssertEqual(groups.first?.subtitle, "Build and deploy web apps")
        XCTAssertEqual(groups.last?.id, "personal")
        XCTAssertEqual(groups.first(where: { $0.id == "project:/r/app" })?.title, "app")
    }

    func testGroupStateAndTokens() {
        let a = skill("a", .personal), b = skill("b", .personal)
        let same = AppState.skillGroups([a, b], states: [a.id: .off, b.id: .off], pluginDescriptions: [:])
        XCTAssertEqual(same.first?.state, .off)
        XCTAssertEqual(same.first?.tokens, 0)
        let mixed = AppState.skillGroups([a, b], states: [a.id: .off, b.id: .on], pluginDescriptions: [:])
        XCTAssertNil(mixed.first?.state)
        XCTAssertEqual(mixed.first?.tokens, (AppState.listedChars(b, .on) + 3) / 4)
    }

    func testPluginDescriptionIsCappedAndOptional() {
        XCTAssertEqual(SkillsReader.pluginDescription(json: Data(#"{"description":"  Hi  "}"#.utf8)), "Hi")
        XCTAssertEqual(SkillsReader.pluginDescription(json: Data("{\"description\":\"\(String(repeating: "x", count: 500))\"}".utf8))?.count, 160)
        XCTAssertNil(SkillsReader.pluginDescription(json: Data(#"{"name":"x"}"#.utf8)))
        XCTAssertNil(SkillsReader.pluginDescription(json: nil))
    }
}
