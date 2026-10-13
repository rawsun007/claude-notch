import XCTest
@testable import ClaudeNotch

/// The trash entries must look like Claude Code's own, so its 30-day sweep
/// cleans up after ClaudeNotch exactly as it does after itself.
final class SkillTrashTests: XCTestCase {

    func testEntryNameMatchesClaudeCodesShape() {
        let name = SkillTrash.entryName(now: Date(timeIntervalSince1970: 1_791_553_759.957), pid: 18952)
        let parts = name.split(separator: "-")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], "1791553759957")
        XCTAssertEqual(parts[1], "18952")
        XCTAssertEqual(parts[2].count, 6)
    }

    func testTrashedAtFromAName() {
        XCTAssertEqual(SkillTrash.trashedAt(entryName: "1791553759957-18952-739nBm")?.timeIntervalSince1970 ?? 0, 1_791_553_759.957, accuracy: 0.001)
        XCTAssertNil(SkillTrash.trashedAt(entryName: "notes"))
        XCTAssertNil(SkillTrash.trashedAt(entryName: "12-3-x"))
    }

    func testDaysLeft() {
        let e = SkillTrash.Entry(path: "/t/x", name: "x", trashedAt: Date().addingTimeInterval(-10 * 86_400 - 60), origin: nil)
        XCTAssertEqual(e.daysLeft, 20)
        XCTAssertEqual(SkillTrash.Entry(path: "/t/y", name: "y", trashedAt: Date().addingTimeInterval(-90 * 86_400), origin: nil).daysLeft, 0)
    }
}
