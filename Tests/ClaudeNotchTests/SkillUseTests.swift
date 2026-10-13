import XCTest
@testable import ClaudeNotch

final class SkillUseTests: XCTestCase {

    func testNameFromToolInput() {
        XCTAssertEqual(SkillUse.name(fromToolInput: ["skill": "pdf"]), "pdf")
        XCTAssertEqual(SkillUse.name(fromToolInput: ["skill": " /deploy prod "]), "deploy")
        XCTAssertNil(SkillUse.name(fromToolInput: ["skill": "  "]))
        XCTAssertNil(SkillUse.name(fromToolInput: [:]))
    }

    func testLongNamesAreCapped() {
        XCTAssertEqual(SkillUse.normalize(String(repeating: "a", count: 500))?.count, 120)
    }

    /// A synced skill can be typed as /pdf or /anthropic-skills:pdf; both count.
    func testLookupCombinesShortAndFullNames() {
        let t1 = Date(timeIntervalSince1970: 10), t2 = Date(timeIntervalSince1970: 20)
        let usage = ["pdf": SkillUse(count: 2, last: t1), "anthropic-skills:pdf": SkillUse(count: 3, last: t2)]
        XCTAssertEqual(SkillUse.lookup(usage, name: "anthropic-skills:pdf"), SkillUse(count: 5, last: t2))
        XCTAssertEqual(SkillUse.lookup(usage, name: "pdf"), SkillUse(count: 2, last: t1))
        XCTAssertNil(SkillUse.lookup(usage, name: "xlsx"))
    }
}
