import XCTest
@testable import ClaudeNotch

/// The About page's release notes are hand-edited at every release, so the
/// cheap structural mistakes (an empty group left behind, two groups of the
/// same kind, a stray blank line) are the ones worth catching.
@MainActor
final class WhatsNewTests: XCTestCase {

    func testEveryGroupHasItems() {
        for group in SettingsView.whatsNew {
            XCTAssertFalse(group.items.isEmpty, "\(group.kind.label) group is empty")
            for item in group.items {
                XCTAssertFalse(item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    func testKindsAreNotRepeated() {
        let labels = SettingsView.whatsNew.map(\.kind.label)
        XCTAssertEqual(labels.count, Set(labels).count, "one group per kind: \(labels)")
    }

    func testEveryKindHasALabelAndSymbol() {
        for kind in [ChangeGroup.Kind.added, .changed, .fixed, .removed] {
            XCTAssertFalse(kind.label.isEmpty)
            XCTAssertFalse(kind.symbol.isEmpty)
        }
    }
}
