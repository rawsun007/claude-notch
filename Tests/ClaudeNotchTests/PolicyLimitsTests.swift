import XCTest
@testable import ClaudeNotch

/// Managed settings decide what this Mac's agents may do, one level above any
/// project. Reading them wrong in either direction is bad: claiming a machine is
/// restricted when it is not is as misleading as missing a real restriction.
final class PolicyLimitsTests: XCTestCase {

    private func parse(_ json: String) -> PolicyLimits.Status {
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return PolicyLimits.parse(obj)
    }

    /// The real shape, taken off this machine.
    func testTheRealFileIsRead() {
        let s = parse(#"""
        {"restrictions":{"allow_remote_control":{"allowed":false},
                         "allow_quick_web_setup":{"allowed":false},
                         "enforce_web_search_mcp_isolation":{"allowed":false}},
         "compliance_taints":[],"monitoring_notice":null,
         "defaults":{"remote_control_at_startup":false}}
        """#)
        XCTAssertEqual(s.denied, ["allow_quick_web_setup", "allow_remote_control",
                                  "enforce_web_search_mcp_isolation"])
        XCTAssertNil(s.monitoringNotice)
        XCTAssertTrue(s.taints.isEmpty)
        XCTAssertTrue(s.isManaged)
    }

    /// Only denials are kept. A list of what is permitted is not news.
    func testAllowedRestrictionsAreNotListed() {
        let s = parse(#"{"restrictions":{"allow_remote_control":{"allowed":true}}}"#)
        XCTAssertTrue(s.denied.isEmpty)
        XCTAssertFalse(s.isManaged)
    }

    /// A restriction the app cannot read is not a denial.
    func testAnUnreadableRestrictionIsNotADenial() {
        XCTAssertTrue(parse(#"{"restrictions":{"allow_x":{}}}"#).denied.isEmpty)
        XCTAssertTrue(parse(#"{"restrictions":{"allow_x":"maybe"}}"#).denied.isEmpty)
        XCTAssertTrue(parse(#"{"restrictions":{"allow_x":null}}"#).denied.isEmpty)
    }

    /// The bare boolean spelling works too, since the file's shape is not a
    /// documented contract.
    func testABareBooleanIsUnderstood() {
        XCTAssertEqual(parse(#"{"restrictions":{"allow_x":false}}"#).denied, ["allow_x"])
    }

    func testAMonitoringNoticeIsKeptVerbatim() {
        let s = parse(#"{"monitoring_notice":"Sessions on this device are recorded for audit."}"#)
        XCTAssertEqual(s.monitoringNotice, "Sessions on this device are recorded for audit.")
        XCTAssertTrue(s.isManaged)
    }

    /// Empty and whitespace notices are absent, not notices.
    func testAnEmptyNoticeIsNoNotice() {
        XCTAssertNil(parse(#"{"monitoring_notice":""}"#).monitoringNotice)
        XCTAssertNil(parse(#"{"monitoring_notice":"   \n"}"#).monitoringNotice)
        XCTAssertNil(parse("{}").monitoringNotice)
    }

    func testTaintsAreRead() {
        XCTAssertEqual(parse(#"{"compliance_taints":["pci","hipaa",""]}"#).taints, ["pci", "hipaa"])
    }

    /// A personal Mac is not managed, and must produce nothing at all.
    func testAnUnmanagedMachineIsSilent() {
        XCTAssertFalse(parse("{}").isManaged)
        XCTAssertFalse(PolicyLimits.read(path: "/nonexistent/policy-limits.json").isManaged)
    }

    func testBrokenJSONIsSilentRatherThanWrong() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-policy-\(UUID().uuidString).json").path
        try? "{ not json".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertFalse(PolicyLimits.read(path: path).isManaged)
    }

    // MARK: - What it says

    func testKnownRestrictionsReadAsSentences() {
        XCTAssertTrue(PolicyLimits.label(for: "allow_remote_control").lowercased().contains("remote control"))
        XCTAssertFalse(PolicyLimits.label(for: "allow_remote_control").contains("_"))
    }

    /// A key this app has never seen still reads as words rather than as a key.
    func testAnUnknownRestrictionStillReads() {
        let label = PolicyLimits.label(for: "allow_some_new_thing")
        XCTAssertFalse(label.contains("_"), label)
        XCTAssertEqual(label, "Some new thing")
    }

    /// The card leads with the administrator's own words when there are any.
    func testTheNoticeWinsTheCard() {
        let withNotice = parse(#"{"monitoring_notice":"We record everything.","restrictions":{"allow_remote_control":{"allowed":false}}}"#)
        XCTAssertEqual(PolicyLimits.cardDetail(withNotice), "We record everything.")
        XCTAssertTrue(PolicyLimits.cardTitle(withNotice).lowercased().contains("notice"))

        let restrictionsOnly = parse(#"{"restrictions":{"allow_remote_control":{"allowed":false}}}"#)
        XCTAssertTrue(PolicyLimits.cardDetail(restrictionsOnly).lowercased().contains("remote control"))
        XCTAssertFalse(PolicyLimits.cardTitle(restrictionsOnly).isEmpty)
    }

    // MARK: - Announcing it

    @MainActor
    func testAManagedMachineIsAnnouncedOnce() {
        let s = AppState()
        s.policy = PolicyLimits.Status(monitoringNotice: "Recorded.", denied: [], taints: [])
        s.announcePolicyIfNeeded()
        s.announcePolicyIfNeeded()
        s.announcePolicyIfNeeded()
        XCTAssertEqual(s.permissionQueue.filter { $0.toolName == "Policy" }.count, 1)
    }

    /// A changed notice is news again.
    @MainActor
    func testAChangedNoticeIsAnnouncedAgain() {
        let s = AppState()
        s.policy = PolicyLimits.Status(monitoringNotice: "First.", denied: [], taints: [])
        s.announcePolicyIfNeeded()
        s.policy = PolicyLimits.Status(monitoringNotice: "Second.", denied: [], taints: [])
        s.announcePolicyIfNeeded()
        XCTAssertEqual(s.permissionQueue.filter { $0.toolName == "Policy" }.count, 2)
    }

    @MainActor
    func testAnUnmanagedMachineSaysNothing() {
        let s = AppState()
        s.announcePolicyIfNeeded()
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }
}
