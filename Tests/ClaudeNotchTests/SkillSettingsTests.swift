import XCTest
@testable import ClaudeNotch

/// settings.json belongs to the user. Writes must change one entry and
/// leave every other key exactly as it was, and never replace a file that
/// does not parse.
final class SkillSettingsTests: XCTestCase {

    func testReadsOverrides() {
        let json = #"{"skillOverrides":{"deploy":"off","legacy":"name-only","weird":"maybe","n":3}}"#
        let o = SkillSettings.overrides(in: Data(json.utf8))
        XCTAssertEqual(o["deploy"], .off)
        XCTAssertEqual(o["legacy"], .nameOnly)
        XCTAssertNil(o["weird"]); XCTAssertNil(o["n"])
        XCTAssertTrue(SkillSettings.overrides(in: nil).isEmpty)
    }

    func testWriteKeepsEveryOtherKey() throws {
        let before = #"{"hooks":{"Stop":[{"hooks":[]}]},"model":"opus","skillOverrides":{"a":"off"}}"#
        let after = try SkillSettings.setting(Data(before.utf8), map: "skillOverrides", key: "b", value: "name-only")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: after) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertNotNil(root["hooks"])
        XCTAssertEqual(root["skillOverrides"] as? [String: String], ["a": "off", "b": "name-only"])
    }

    /// "on" is the default, so it is written as no entry at all, and an
    /// emptied map goes too: the file ends as it was before ClaudeNotch.
    func testRemovingTheLastEntryRemovesTheMap() throws {
        let after = try SkillSettings.setting(Data(#"{"model":"opus","skillOverrides":{"a":"off"}}"#.utf8), map: "skillOverrides", key: "a", value: nil)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: after) as? [String: Any])
        XCTAssertNil(root["skillOverrides"])
        XCTAssertEqual(root["model"] as? String, "opus")
    }

    func testMissingFileStartsEmpty() throws {
        let after = try SkillSettings.setting(nil, map: "enabledPlugins", key: "vercel@x", value: false)
        XCTAssertEqual(SkillSettings.enabledPlugins(in: after), ["vercel@x": false])
    }

    func testUnparseableFileIsNeverReplaced() {
        XCTAssertThrowsError(try SkillSettings.setting(Data("{ not json".utf8), map: "skillOverrides", key: "a", value: "off"))
        XCTAssertThrowsError(try SkillSettings.setting(Data("[1,2]".utf8), map: "skillOverrides", key: "a", value: "off"))
    }

    func testRealFileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("settings.json").path
        try SkillSettings.setVisibility(.off, for: "deploy", at: path)
        XCTAssertEqual(SkillSettings.overrides(at: path), ["deploy": .off])
        try SkillSettings.setVisibility(.on, for: "deploy", at: path)
        XCTAssertTrue(SkillSettings.overrides(at: path).isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }
}
