import XCTest
@testable import ClaudeNotch

/// PlanReader reads a cache that belongs to Claude Code, not to this app. It can
/// change shape or drop a key at any release, and none of that may crash or, worse,
/// quietly show the wrong number next to somebody's spend. So the tests are mostly
/// about what happens when a field is missing, null, or a type other than the one
/// documented here.
final class PlanReaderTests: XCTestCase {

    /// The shape as Claude Code 2.1 writes it, trimmed to the keys read here.
    private let real = """
    {
      "oauthAccount": {
        "billingType": "stripe_subscription",
        "organizationType": "claude_pro",
        "organizationRole": "admin",
        "seatTier": null,
        "subscriptionCreatedAt": "2026-02-17T15:06:11.441578Z",
        "accountCreatedAt": "2024-03-20T17:02:09.019241Z",
        "claudeCodeTrialEndsAt": null
      },
      "cachedUsageUtilization": {
        "fetchedAtMs": 1785493852381,
        "utilization": {
          "five_hour": { "utilization": 20, "resets_at": "2026-07-31T15:00:00.336425+00:00" },
          "seven_day": { "utilization": 13, "resets_at": "2026-08-07T03:00:00.336452+00:00" },
          "extra_usage": {
            "is_enabled": false, "monthly_limit": null, "used_credits": null,
            "utilization": null, "currency": null, "disabled_reason": null,
            "user_disabled": true, "spend_limit_reached": false, "credits_ever_enabled": true
          },
          "limits": [
            { "kind": "session", "group": "session", "percent": 20, "severity": "normal",
              "resets_at": "2026-07-31T15:00:00.336425+00:00", "is_active": true },
            { "kind": "weekly_all", "group": "weekly", "percent": 13, "severity": "normal",
              "resets_at": "2026-08-07T03:00:00.336452+00:00", "is_active": false }
          ],
          "spend": {
            "used": { "amount_minor": 0, "currency": "USD", "exponent": 2 },
            "limit": null, "percent": 0, "enabled": false, "balance": null,
            "auto_reload": null, "can_purchase_credits": false
          }
        }
      }
    }
    """.data(using: .utf8)!

    func testReadsTheRealShape() {
        let s = PlanReader.parse(real)
        XCTAssertEqual(s?.account?.tier, "Pro")
        XCTAssertEqual(s?.account?.billing, "Subscription")
        XCTAssertEqual(s?.account?.role, "admin")
        XCTAssertNil(s?.account?.seat)          // null, not the string "null"
        XCTAssertNil(s?.account?.trialEndsAt)
        XCTAssertEqual(s?.limits.count, 2)
        XCTAssertEqual(s?.limits.first?.label, "5-hour session")
        XCTAssertEqual(s?.limits.first?.percent, 20)
        XCTAssertEqual(s?.limits.last?.isActive, false)
        XCTAssertEqual(s?.credits?.isEnabled, false)
        XCTAssertEqual(s?.credits?.everEnabled, true)
        XCTAssertEqual(s?.credits?.userDisabled, true)
        XCTAssertEqual(s?.credits?.spent, 0)
        XCTAssertEqual(s?.credits?.currency, "USD")
    }

    /// subscriptionCreatedAt has fractional seconds; a plain ISO 8601 parser
    /// returns nil for it, which would blank the row rather than fail loudly.
    func testParsesFractionalSecondDates() {
        let since = PlanReader.parse(real)?.account?.memberSince
        XCTAssertEqual(since.map { Int($0.timeIntervalSince1970) }, 1771340771)
    }

    func testFetchedAtComesFromMilliseconds() {
        let s = PlanReader.parse(real)
        XCTAssertEqual(s?.fetchedAt.map { Int($0.timeIntervalSince1970) }, 1785493852)
    }

    /// The limits array is what Claude Code renders itself, so it is preferred.
    /// A cache written before that key existed still has to draw two bars.
    func testFallsBackToTheNamedWindowsWhenLimitsIsAbsent() {
        let json = """
        {"cachedUsageUtilization":{"utilization":{
          "five_hour":{"utilization":42,"resets_at":"2026-07-31T15:00:00Z"},
          "seven_day":{"utilization":7,"resets_at":"2026-08-07T03:00:00Z"}}}}
        """.data(using: .utf8)!
        let s = PlanReader.parse(json)
        XCTAssertEqual(s?.limits.map(\.kind), ["five_hour", "seven_day"])
        XCTAssertEqual(s?.limits.first?.percent, 42)
        XCTAssertEqual(s?.limits.first?.label, "5-hour session")
    }

    func testCreditsOnReportsTheNumbers() {
        let json = """
        {"cachedUsageUtilization":{"utilization":{"extra_usage":{
          "is_enabled":true,"monthly_limit":50,"used_credits":12.5,"utilization":25,
          "currency":"USD","user_disabled":false,"spend_limit_reached":false,
          "credits_ever_enabled":true},
          "spend":{"used":{"amount_minor":1250,"currency":"USD","exponent":2},
                   "limit":{"amount_minor":5000,"currency":"USD","exponent":2},
                   "balance":{"amount_minor":3750,"currency":"USD","exponent":2},
                   "auto_reload":true,"can_purchase_credits":true,"enabled":true}}}}
        """.data(using: .utf8)!
        let c = PlanReader.parse(json)?.credits
        XCTAssertEqual(c?.isEnabled, true)
        XCTAssertEqual(c?.usedCredits, 12.5)
        XCTAssertEqual(c?.monthlyLimit, 50)
        XCTAssertEqual(c?.utilization, 25)
        XCTAssertEqual(c?.spent, 12.50)         // minor units, exponent 2
        XCTAssertEqual(c?.spendLimit, 50)
        XCTAssertEqual(c?.balance, 37.50)
        XCTAssertEqual(c?.autoReload, true)
        XCTAssertEqual(c?.canPurchase, true)
    }

    /// A zero-decimal currency reports exponent 0. Assuming cents would show
    /// ¥1,250 as ¥12.50, a hundredfold understatement of somebody's spend.
    func testZeroDecimalCurrency() {
        let json = """
        {"cachedUsageUtilization":{"utilization":{"spend":{
          "used":{"amount_minor":1250,"currency":"JPY","exponent":0}}}}}
        """.data(using: .utf8)!
        let c = PlanReader.parse(json)?.credits
        XCTAssertEqual(c?.spent, 1250)
        XCTAssertEqual(c?.currency, "JPY")
    }

    func testGarbageAndEmptyInputAreNil() {
        XCTAssertNil(PlanReader.parse(Data()))
        XCTAssertNil(PlanReader.parse("not json".data(using: .utf8)!))
        XCTAssertNil(PlanReader.parse("[1,2,3]".data(using: .utf8)!))
        XCTAssertNil(PlanReader.parse("{}".data(using: .utf8)!))          // nothing to show
        XCTAssertNil(PlanReader.parse("{\"oauthAccount\":{}}".data(using: .utf8)!))
    }

    /// Wrong types where numbers are expected. Claude Code has written these as
    /// strings before, and a crash here would take the settings window with it.
    func testWrongTypesAreToleratedRatherThanTrusted() {
        let json = """
        {"cachedUsageUtilization":{"fetchedAtMs":"nope","utilization":{
          "limits":[{"kind":"session","percent":"55","resets_at":9999999999},
                    {"kind":"weekly_all"},
                    {"percent":10}],
          "extra_usage":{"is_enabled":"yes","used_credits":"3.5"}}}}
        """.data(using: .utf8)!
        let s = PlanReader.parse(json)
        XCTAssertEqual(s?.limits.count, 1)              // the two unusable rows are dropped
        XCTAssertEqual(s?.limits.first?.percent, 55)    // a numeric string still counts
        XCTAssertEqual(s?.limits.first?.resetsAt.map { Int($0.timeIntervalSince1970) }, 9999999999)
        XCTAssertNil(s?.fetchedAt)
        XCTAssertEqual(s?.credits?.isEnabled, false)    // "yes" is not a bool, so: off
        XCTAssertEqual(s?.credits?.usedCredits, 3.5)
    }

    /// A percentage outside 0...100 would draw a bar past the end of its track.
    func testPercentagesAreClamped() {
        let json = """
        {"cachedUsageUtilization":{"utilization":{"limits":[
          {"kind":"session","percent":140},{"kind":"weekly_all","percent":-5}]}}}
        """.data(using: .utf8)!
        let s = PlanReader.parse(json)
        XCTAssertEqual(s?.limits.first?.percent, 100)
        XCTAssertEqual(s?.limits.last?.percent, 0)
    }

    /// Plan names are matched loosely so a tier that does not exist yet reads as
    /// itself instead of disappearing.
    func testTierNames() {
        XCTAssertEqual(PlanReader.tierName("claude_pro"), "Pro")
        XCTAssertEqual(PlanReader.tierName("claude_max_20x"), "Max 20x")
        XCTAssertEqual(PlanReader.tierName("claude_max"), "Max")
        XCTAssertEqual(PlanReader.tierName("claude_team"), "Team")
        XCTAssertEqual(PlanReader.tierName("claude_enterprise"), "Enterprise")
        XCTAssertEqual(PlanReader.tierName("claude_free"), "Free")
        XCTAssertEqual(PlanReader.tierName("claude_something_new"), "Something New")
    }

    func testLimitAndReasonNames() {
        XCTAssertEqual(PlanReader.limitName("session"), "5-hour session")
        XCTAssertEqual(PlanReader.limitName("weekly_all"), "Weekly, all models")
        XCTAssertEqual(PlanReader.limitName("weekly_opus"), "Weekly, Opus")
        XCTAssertEqual(PlanReader.limitName("mystery_window"), "Mystery Window")
        XCTAssertEqual(PlanReader.disabledReasonText("org_level_disabled"), "Turned off for this organization")
        XCTAssertEqual(PlanReader.disabledReasonText("brand_new_reason"), "Brand New Reason")
    }

    func testLoadingAMissingFileIsNil() {
        XCTAssertNil(PlanReader.load(path: "/nonexistent/\(UUID().uuidString).json"))
    }
}
