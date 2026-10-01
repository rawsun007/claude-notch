import XCTest
@testable import ClaudeNotch

/// The status line's `rate_limits.spend_limit` (Claude apps gateway). Dollar
/// amounts arrive only from CLI 2.1.284, so the text must cope without them.
final class GatewaySpendTests: XCTestCase {
    func testAmountsWithPeriod() {
        let s = GatewaySpend(percent: 0.628, resetsAt: nil, usedUSD: 271.4, limitUSD: 500, period: "month")
        let text = s.amountText ?? ""
        XCTAssertTrue(text.contains("271.40"), text)
        XCTAssertTrue(text.contains("500.00"), text)
        XCTAssertTrue(text.hasSuffix(" this month"), text)
    }

    func testPercentOnlyHasNoAmountText() {
        XCTAssertNil(GatewaySpend(percent: 0.5, resetsAt: nil, usedUSD: nil, limitUSD: nil).amountText)
        XCTAssertNil(GatewaySpend(percent: 0.5, resetsAt: nil, usedUSD: 10, limitUSD: nil).amountText)
    }
}
