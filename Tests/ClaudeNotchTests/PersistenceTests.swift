import XCTest
@testable import ClaudeNotch

/// state.json is the app's memory across relaunches. Two properties matter:
/// a snapshot must survive an encode/decode round-trip unchanged, and a snapshot
/// with one unreadable field must still yield every OTHER field (the graceful
/// per-field decode in Snapshot.init(from:) — a regression here once blanked all
/// usage stats on every release that added a key).
final class PersistenceTests: XCTestCase {

    private func sampleSnapshot() -> Persistence.Snapshot {
        var s = Persistence.Snapshot(
            history: [HistoryEntry(timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                   kind: .permission, toolName: "Bash",
                                   title: "run", detail: "ls", project: "proj",
                                   outcome: .allowed)],
            allowRules: [],
            recentProjects: ["/a", "/b"])
        s.autoApprove = true
        s.sessionCostCap = 12.5
        s.learnedContextWindows = ["claude-opus": 200_000]
        s.weeklyResetAt = Date(timeIntervalSince1970: 1_700_100_000)
        s.pinnedProjects = ["/a"]
        return s
    }

    func testRoundTrip() throws {
        let original = sampleSnapshot()
        let data = try XCTUnwrap(Persistence.encode(original))
        let back = try XCTUnwrap(Persistence.decode(data))

        XCTAssertEqual(back.history, original.history)
        XCTAssertEqual(back.recentProjects, ["/a", "/b"])
        XCTAssertEqual(back.autoApprove, true)
        XCTAssertEqual(back.sessionCostCap, 12.5)
        XCTAssertEqual(back.learnedContextWindows?["claude-opus"], 200_000)
        XCTAssertEqual(back.weeklyResetAt, Date(timeIntervalSince1970: 1_700_100_000))
        XCTAssertEqual(back.pinnedProjects, ["/a"])
    }

    func testOptionalFieldsDefaultWhenAbsent() throws {
        // A minimal snapshot from an older build: only the non-optional keys.
        let json = Data(#"{"history":[],"allowRules":[],"recentProjects":[]}"#.utf8)
        let s = try XCTUnwrap(Persistence.decode(json))
        XCTAssertTrue(s.history.isEmpty)
        XCTAssertTrue(s.recentProjects.isEmpty)
        XCTAssertNil(s.autoApprove)
        XCTAssertNil(s.sessionCostCap)
    }

    func testOneBadFieldDoesNotSinkTheRest() throws {
        // stats is the wrong shape (a string, not an object). The per-field
        // decode must swallow it and still surface the sibling fields.
        let json = Data(#"""
        {"history":[],"allowRules":[],"recentProjects":["/keep"],
         "stats":"corrupt","autoApprove":true,"dailyCostCap":9.0}
        """#.utf8)
        let s = try XCTUnwrap(Persistence.decode(json))
        XCTAssertNil(s.stats)                       // the bad field degraded
        XCTAssertEqual(s.recentProjects, ["/keep"]) // siblings survived
        XCTAssertEqual(s.autoApprove, true)
        XCTAssertEqual(s.dailyCostCap, 9.0)
    }

    /// The bug that reads as "the update wiped my settings".
    ///
    /// JSON cannot represent a NaN or an infinity, so the encoder throws on
    /// one and the whole snapshot goes with it — every toggle, every cap,
    /// every rule — silently, and on every save from then on. One divide by
    /// zero in a cost or a percentage was enough.
    func testANonFiniteNumberDoesNotSinkTheWholeSnapshot() throws {
        var s = sampleSnapshot()
        s.dailyCostCap = .nan
        s.weeklyLimitPercent = .infinity
        let data = try XCTUnwrap(Persistence.encode(s),
                                 "a NaN must not stop the snapshot from encoding")
        let back = try XCTUnwrap(Persistence.decode(data))
        // Everything else survives intact, which is the point.
        XCTAssertEqual(back.autoApprove, true)
        XCTAssertEqual(back.sessionCostCap, 12.5)
        XCTAssertEqual(back.recentProjects, ["/a", "/b"])
        // And the unusable numbers come back as themselves rather than as junk.
        XCTAssertTrue(back.dailyCostCap?.isNaN ?? false)
        XCTAssertEqual(back.weeklyLimitPercent, .infinity)
    }

    /// The new token caps have to survive a relaunch like every other setting.
    func testCodexTokenCapsRoundTrip() throws {
        var s = sampleSnapshot()
        s.codexSessionTokenCap = 250_000
        s.codexDailyTokenCap = 1_000_000
        let back = try XCTUnwrap(Persistence.decode(XCTUnwrap(Persistence.encode(s))))
        XCTAssertEqual(back.codexSessionTokenCap, 250_000)
        XCTAssertEqual(back.codexDailyTokenCap, 1_000_000)
    }

    /// A file written by an older build has neither key, and must not reset
    /// anything else on the way in.
    func testMissingTokenCapsDecodeAsAbsentNotZeroed() throws {
        let json = Data(#"{"history":[],"allowRules":[],"recentProjects":[],"autoApprove":true}"#.utf8)
        let s = try XCTUnwrap(Persistence.decode(json))
        XCTAssertNil(s.codexSessionTokenCap)
        XCTAssertEqual(s.autoApprove, true)
    }

    func testGarbageTopLevelReturnsNil() {
        XCTAssertNil(Persistence.decode(Data("not json".utf8)))
    }
}
