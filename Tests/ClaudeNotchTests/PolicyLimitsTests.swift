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
        // And this is a PERSONAL Mac. Those three are off because a consumer
        // account does not include them, not because an administrator said so.
        // The first version of this called it managed and told the owner their
        // organisation restricts their machine.
        XCTAssertFalse(s.isManaged, "restrictions alone are not an organisation")
    }

    /// The evidence of a managed machine is somebody having written something.
    func testOnlyANoticeOrALabelMeansManaged() {
        XCTAssertTrue(parse(#"{"monitoring_notice":"Recorded for audit."}"#).isManaged)
        XCTAssertTrue(parse(#"{"compliance_taints":["pci"]}"#).isManaged)
        XCTAssertFalse(parse(#"{"restrictions":{"allow_remote_control":{"allowed":false}}}"#).isManaged)
        XCTAssertFalse(parse("{}").isManaged)
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
    }

    /// With labels but no notice, the card names the labels rather than
    /// reciting restrictions that are not evidence of anything.
    func testLabelsCarryTheCardWhenThereIsNoNotice() {
        let tainted = parse(#"{"compliance_taints":["pci","hipaa"]}"#)
        let detail = PolicyLimits.cardDetail(tainted)
        XCTAssertTrue(detail.contains("pci"), detail)
        XCTAssertTrue(detail.contains("hipaa"), detail)
        XCTAssertFalse(PolicyLimits.cardTitle(tainted).isEmpty)
    }

    // MARK: - Announcing it

    /// The regression, on a real session: this machine's own file must produce
    /// no card at all.
    @MainActor
    func testThisMachinesOwnPolicyFileSaysNothing() {
        let s = AppState()
        s.policy = PolicyLimits.read()   // the real ~/.claude/policy-limits.json
        s.announcePolicyIfNeeded()
        if s.policy.monitoringNotice == nil && s.policy.taints.isEmpty {
            XCTAssertTrue(s.permissionQueue.isEmpty,
                          "an unmanaged Mac must not be told it has an organisation")
        }
    }

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
