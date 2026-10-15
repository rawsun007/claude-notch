import XCTest
@testable import ClaudeNotch

/// The idle compaction switch writes one key into the user's own
/// settings.json, so it must keep everything else and never replace a file
/// it cannot read.
final class ClaudeCodeSettingsTests: XCTestCase {

    func testReadsABool() {
        XCTAssertEqual(ClaudeCodeSettings.bool("idleCompaction", in: Data(#"{"idleCompaction":false}"#.utf8)), false)
        XCTAssertNil(ClaudeCodeSettings.bool("idleCompaction", in: Data(#"{"model":"opus"}"#.utf8)))
        XCTAssertNil(ClaudeCodeSettings.bool("idleCompaction", in: nil))
    }

    func testTurningOffThenOnLeavesTheFileAsItWas() throws {
        let before = Data(#"{"hooks":{"Stop":[]},"model":"opus"}"#.utf8)
        let off = try ClaudeCodeSettings.setting(before, key: "idleCompaction", value: false)
        XCTAssertEqual(ClaudeCodeSettings.bool("idleCompaction", in: off), false)
        let on = try ClaudeCodeSettings.setting(off, key: "idleCompaction", value: nil)
        let a = try XCTUnwrap(try JSONSerialization.jsonObject(with: before) as? NSDictionary)
        let b = try XCTUnwrap(try JSONSerialization.jsonObject(with: on) as? NSDictionary)
        XCTAssertEqual(a, b)
    }

    func testUnreadableFileIsNeverReplaced() {
        XCTAssertThrowsError(try ClaudeCodeSettings.setting(Data("{ broken".utf8), key: "idleCompaction", value: false))
    }
}
