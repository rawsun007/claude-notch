import XCTest
@testable import ClaudeNotch

/// Version arithmetic decides whether a badge appears, so it gets tested
/// rather than eyeballed.
final class CLIVersionTests: XCTestCase {

    func testComponentsParse() {
        XCTAssertEqual(CLIVersion.components("2.1.219"), [2, 1, 219])
        XCTAssertEqual(CLIVersion.components(" 2.1.7 "), [2, 1, 7])
        XCTAssertEqual(CLIVersion.components("2.2.0-beta.1"), [2, 2, 0])
        XCTAssertEqual(CLIVersion.components("nightly"), [])
    }

    /// The bug this exists for: string comparison puts 2.1.76 above 2.1.219,
    /// and every version floor in the app would be wrong by a hundred releases.
    func testNumericNotLexicographic() {
        XCTAssertTrue(CLIVersion.atLeast("2.1.219", "2.1.76"))
        XCTAssertFalse(CLIVersion.atLeast("2.1.76", "2.1.219"))
    }

    func testEqualVersionsSatisfyTheirOwnFloor() {
        XCTAssertTrue(CLIVersion.atLeast("2.1.219", "2.1.219"))
        XCTAssertEqual(CLIVersion.compare("2.1.219", "2.1.219"), .orderedSame)
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertEqual(CLIVersion.compare("2.1", "2.1.0"), .orderedSame)
        XCTAssertTrue(CLIVersion.atLeast("3", "2.9.9"))
        XCTAssertFalse(CLIVersion.atLeast("2.1", "2.1.1"))
    }

    // MARK: - Feature floors

    func testFloorsMatchTheChangelog() {
        XCTAssertEqual(CLIVersion.Feature.sandboxPosture.floor, "2.1.219")
        XCTAssertEqual(CLIVersion.Feature.addedDirectories.floor, "2.1.219")
        XCTAssertEqual(CLIVersion.Feature.forkSource.floor, "2.1.214")
        XCTAssertEqual(CLIVersion.Feature.postCompact.floor, "2.1.76")
        XCTAssertEqual(CLIVersion.Feature.elicitation.floor, "2.1.76")
    }

    func testAnOldSessionDoesNotClaimWhatItCannotKnow() {
        XCTAssertFalse(CLIVersion.supports(.sandboxPosture, version: "2.1.200"))
        XCTAssertTrue(CLIVersion.supports(.sandboxPosture, version: "2.1.223"))
        XCTAssertFalse(CLIVersion.supports(.forkSource, version: "2.1.213"))
        XCTAssertTrue(CLIVersion.supports(.forkSource, version: "2.1.214"))
    }

    /// An unknown version is not an old one. A session the registry has not
    /// described still shows everything the app already holds for it.
    func testUnknownVersionSupportsEverything() {
        for feature in CLIVersion.Feature.allCases {
            XCTAssertTrue(CLIVersion.supports(feature, version: ""))
            XCTAssertTrue(CLIVersion.supports(feature, version: "   "))
        }
    }

    /// Every floor is a version this app can actually read.
    func testEveryFloorParses() {
        for feature in CLIVersion.Feature.allCases {
            XCTAssertFalse(CLIVersion.components(feature.floor).isEmpty, "\(feature)")
        }
    }
}
