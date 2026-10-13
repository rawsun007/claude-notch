import XCTest
@testable import ClaudeNotch

/// SKILL.md frontmatter is written by hand, by tools, and by other agents, so
/// the parser has to take what real files look like.
final class SkillsReaderTests: XCTestCase {

    func testPlainFrontmatter() {
        let fm = SkillsReader.frontmatter("---\nname: deploy\ndescription: Ship it. Use when asked to deploy.\n---\n# Body\n")
        XCTAssertEqual(fm.name, "deploy")
        XCTAssertEqual(fm.description, "Ship it. Use when asked to deploy.")
    }

    /// A real skill on the developer's Mac starts with a byte-order mark.
    func testByteOrderMarkAndCRLF() {
        let fm = SkillsReader.frontmatter("\u{FEFF}---\r\nname: anim\r\ndescription: Animations.\r\n---\r\nbody")
        XCTAssertEqual(fm.name, "anim")
        XCTAssertEqual(fm.description, "Animations.")
    }

    func testQuotesBlockScalarsAndLists() {
        let fm = SkillsReader.frontmatter("""
        ---
        name: "quoted"
        description: >
          Folded over
          two lines.
        when_to_use: 'When asked.'
        triggers:
          - "a"
          - "b"
        disable-model-invocation: true
        ---
        """)
        XCTAssertEqual(fm.name, "quoted")
        XCTAssertEqual(fm.description, "Folded over two lines.")
        XCTAssertEqual(fm.whenToUse, "When asked.")
        XCTAssertTrue(fm.disableModelInvocation)
        XCTAssertNil(fm.fields["- \"a\""])
    }

    func testNoFrontmatter() {
        XCTAssertEqual(SkillsReader.frontmatter("# Just a body"), SkillsReader.Frontmatter())
        XCTAssertNil(SkillsReader.frontmatter("---\nname:\n---").name)
    }

    func testListingCostIsCapped() {
        let long = skill(desc: String(repeating: "x", count: 5000))
        XCTAssertEqual(long.listingChars, long.name.count + 4 + SkillsReader.maxEntryChars)
        XCTAssertEqual(skill(desc: "abc").listingChars, "s".count + 4 + 3)
        XCTAssertEqual(skill(desc: "abc", hidden: true).listingChars, 0)
    }

    func testReservedFolders() {
        for f in ["synced", "Synced", ".trash", "anthropic-skills", "anthropic-skills:pdf"] { XCTAssertTrue(SkillsReader.isReserved(f), f) }
        XCTAssertFalse(SkillsReader.isReserved("deploy"))
    }

    /// A claude.ai skill synced to two accounts on one Mac loads once.
    func testDedupeKeepsTheNewestCopy() {
        let old = skill(name: "anthropic-skills:pdf", path: "/a/pdf", modified: Date(timeIntervalSince1970: 1))
        let new = skill(name: "anthropic-skills:pdf", path: "/b/pdf", modified: Date(timeIntervalSince1970: 2))
        let other = skill(name: "anthropic-skills:xlsx", path: "/a/xlsx")
        XCTAssertEqual(SkillsReader.dedupeNewest([old, new, other]).map(\.path), ["/b/pdf", "/a/xlsx"])
    }

    /// The crash this guards: a recent project at the home folder has the same
    /// .claude/skills as the personal folder, so its skills came back twice.
    func testUniqueByPathAndStandardPaths() {
        let a = skill(name: "a", path: "/x/a"), dup = skill(name: "a", path: "/x/a"), b = skill(name: "b", path: "/x/b")
        XCTAssertEqual(SkillsReader.uniqueByPath([a, dup, b]).map(\.path), ["/x/a", "/x/b"])
        XCTAssertEqual(SkillsReader.standard("/tmp/../tmp/./skills/"), SkillsReader.standard("/tmp/skills"))
    }

    func testInstalledPlugins() {
        let json = #"{"version":2,"plugins":{"caveman@caveman":[{"installPath":"/p/old"},{"installPath":"/p/new"}],"bad@x":[{}]}}"#
        let list = SkillsReader.installedPlugins(json: Data(json.utf8))
        XCTAssertEqual(list.map(\.id), ["caveman@caveman"])
        XCTAssertEqual(list.first?.path, "/p/new")
        XCTAssertTrue(SkillsReader.installedPlugins(json: Data("nope".utf8)).isEmpty)
    }

    private func skill(name: String = "s", desc: String = "", hidden: Bool = false, path: String = "/x", modified: Date? = nil) -> SkillInfo {
        SkillInfo(name: name, source: .personal, project: nil, plugin: nil, description: desc, whenToUse: "",
                  modelInvocationDisabled: hidden, path: path, bytes: 0, modified: modified)
    }
}
