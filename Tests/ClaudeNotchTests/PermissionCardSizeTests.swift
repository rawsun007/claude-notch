import XCTest
@testable import ClaudeNotch

/// The permission card's height is the larger of size(for:) and what its
/// content measured. These pin both halves of the fix for a destructive Edit
/// card drawn with its button row cut in half.
@MainActor
final class PermissionCardSizeTests: XCTestCase {

    private func edit(lines: Int, danger: [String] = []) -> PermissionRequest {
        let hunk = DiffHunk(oldLines: [], newLines: Array(repeating: "x", count: lines),
                            truncatedOld: false, truncatedNew: false)
        return PermissionRequest(kind: .toolUse, title: "Edit file", detail: "/tmp/a.swift",
                                 toolName: "Edit", source: "Claude Code", cwd: "/tmp",
                                 preview: .diff(hunk), dangerReasons: danger, resolver: { _, _ in })
    }

    private func height(_ r: PermissionRequest) -> CGFloat {
        NotchView.size(for: .permission(r)).height
    }

    // MARK: - the measurement belongs to one card

    func testTwoCardsNeverShareAMeasureKey() {
        // Two cards that would look identical must still be told apart,
        // otherwise the second inherits the first one's height.
        let a = edit(lines: 3), b = edit(lines: 3)
        XCTAssertNotEqual(NotchMode.permission(a).measureKey, NotchMode.permission(b).measureKey)
    }

    func testACardKeepsItsKeyAcrossUpdates() {
        let a = edit(lines: 3)
        XCTAssertEqual(NotchMode.permission(a).measureKey, NotchMode.permission(a).measureKey)
    }

    func testCardKindsDoNotCollide() {
        // An auto-approved card built from the same request is a different
        // card with a different layout.
        let a = edit(lines: 3)
        XCTAssertNotEqual(NotchMode.permission(a).measureKey, NotchMode.autoInfo(a).measureKey)
    }

    // MARK: - the formula floor covers what is drawn

    func testEachDiffRowIsBudgetedAtItsDrawnHeight() {
        // A row is an 11pt monospaced line plus 1pt padding each side: 15pt.
        // The budget must not fall below that, or long diffs lose the buttons.
        let perRow = (height(edit(lines: 8)) - height(edit(lines: 2))) / 6
        XCTAssertGreaterThanOrEqual(perRow, 15)
    }

    func testDangerBannerIsNeverShorterThanItsPetBadge() {
        // One reason is shorter than the 30pt pet the banner carries; the
        // budget has to follow the pet, plus 14pt of padding and an 8pt gap.
        let plain = height(edit(lines: 3))
        let danger = height(edit(lines: 3, danger: ["writes inside /opt/, a system directory"]))
        XCTAssertGreaterThanOrEqual(danger - plain, 30 + 14 + 8)
    }
}
