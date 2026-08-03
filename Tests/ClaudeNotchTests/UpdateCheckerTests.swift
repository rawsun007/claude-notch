import XCTest
@testable import ClaudeNotch

/// isNewer is the gate on the whole update path: say no and the user is never
/// told a release exists, say yes wrongly and they are nagged forever. It had no
/// tests, which for the one function that decides whether anyone ever upgrades
/// is the wrong place to be economical.
final class UpdateCheckerTests: XCTestCase {

    func testTheOrdinaryUpgrade() {
        XCTAssertTrue(UpdateChecker.isNewer("0.15.1", than: "0.15.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.16.0", than: "0.15.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.99.99"))
    }

    func testSameVersionIsNotAnUpdate() {
        XCTAssertFalse(UpdateChecker.isNewer("0.15.1", than: "0.15.1"),
                       "an equal version must not nag; the check runs daily")
    }

    func testOlderIsNotAnUpdate() {
        XCTAssertFalse(UpdateChecker.isNewer("0.15.0", than: "0.15.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9.0", than: "0.10.0"),
                       "dotted parts are numbers, not text: 9 is older than 10")
    }

    /// The bug this class of function always has. "0.2.10" sorts before "0.2.9"
    /// as a string and after it as a version.
    func testDoubleDigitPartsCompareAsNumbers() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.10", than: "0.2.9"))
        XCTAssertTrue(UpdateChecker.isNewer("0.15.1", than: "0.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2.9", than: "0.2.10"))
    }

    func testMissingPartsCountAsZero() {
        XCTAssertTrue(UpdateChecker.isNewer("0.16", than: "0.15.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.15", than: "0.15.0"),
                       "0.15 and 0.15.0 are the same release")
        XCTAssertTrue(UpdateChecker.isNewer("0.15.1", than: "0.15"))
    }

    /// Releases are tagged v0.15.1 and versions are stored 0.15.1. Reading the
    /// v as part of the major number turns 1.0.0 into 0.0.0, and the app then
    /// believes it is up to date against every future release.
    func testALeadingVDoesNotEatTheMajorVersion() {
        XCTAssertEqual(UpdateChecker.version(fromTag: "v0.15.1"), "0.15.1")
        XCTAssertEqual(UpdateChecker.version(fromTag: "0.15.1"), "0.15.1")
        XCTAssertEqual(UpdateChecker.version(fromTag: "  v1.2.3\n"), "1.2.3")

        XCTAssertTrue(UpdateChecker.isNewer("v1.0.0", than: "0.15.1"),
                      "a tagged 1.0.0 is newer than 0.15.1, v or no v")
        XCTAssertTrue(UpdateChecker.isNewer("v0.16.0", than: "v0.15.1"))
    }

    func testSuffixedVersionsCompareOnTheirNumbers() {
        XCTAssertTrue(UpdateChecker.isNewer("0.16.0-beta", than: "0.15.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.15.1-beta", than: "0.15.1"),
                       "the suffix is ignored, so these are the same release")
    }

    func testGarbageNeverClaimsToBeAnUpdate() {
        XCTAssertFalse(UpdateChecker.isNewer("", than: "0.15.1"))
        XCTAssertFalse(UpdateChecker.isNewer("latest", than: "0.15.1"),
                       "an unparseable tag must not be offered as an upgrade")
    }
}
