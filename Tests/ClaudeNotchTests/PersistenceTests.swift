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

    func testGarbageTopLevelReturnsNil() {
        XCTAssertNil(Persistence.decode(Data("not json".utf8)))
    }
}
