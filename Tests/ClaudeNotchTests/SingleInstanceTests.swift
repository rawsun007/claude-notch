import XCTest
@testable import ClaudeNotch

final class SingleInstanceTests: XCTestCase {
    private let id = "com.example.claudenotch"

    func testEndsOtherCopiesOfThisAppOnly() {
        let running: [SingleInstance.Candidate] = [
            .init(pid: 10, bundleID: id),          // this process
            .init(pid: 11, bundleID: id),          // the installed copy
            .init(pid: 12, bundleID: "com.apple.finder"),
            .init(pid: 13, bundleID: nil),
            .init(pid: 14, bundleID: id),          // an old download
        ]
        XCTAssertEqual(SingleInstance.others(of: id, selfPID: 10, among: running), [11, 14])
    }

    func testAloneMeansNothingToEnd() {
        XCTAssertEqual(SingleInstance.others(of: id, selfPID: 10, among: [.init(pid: 10, bundleID: id)]), [])
    }

    /// Run from a bare binary with no bundle id, it must not match every
    /// process that has none.
    func testNoBundleIdEndsNothing() {
        let running: [SingleInstance.Candidate] = [.init(pid: 11, bundleID: nil), .init(pid: 12, bundleID: "")]
        XCTAssertEqual(SingleInstance.others(of: nil, selfPID: 10, among: running), [])
        XCTAssertEqual(SingleInstance.others(of: "", selfPID: 10, among: running), [])
    }
}
