import XCTest
@testable import ClaudeNotch

/// Codex tracks tasks via update_plan JS embedded in an exec tool, so the plan
/// counter parses unquoted-JS keys out of a string. A miscount would show the
/// wrong N/M in the notch task bar.
final class CodexReaderTests: XCTestCase {

    func testPlanCounts() {
        let js = #"const r = await tools.update_plan({explanation:"go",plan:[{step:"a",status:"completed"},{step:"b",status:"in_progress"},{step:"c",status:"pending"}]})"#
        let c = CodexReader.planCounts(from: js)
        XCTAssertEqual(c?.total, 3)
        XCTAssertEqual(c?.done, 1)
    }

    func testAllCompleted() {
        let js = #"tools.update_plan({plan:[{step:"a",status:"completed"},{step:"b",status:"completed"}]})"#
        let c = CodexReader.planCounts(from: js)
        XCTAssertEqual(c?.total, 2)
        XCTAssertEqual(c?.done, 2)
    }

    func testNoSteps() {
        XCTAssertNil(CodexReader.planCounts(from: "tools.update_plan({plan:[]})"))
    }
}
