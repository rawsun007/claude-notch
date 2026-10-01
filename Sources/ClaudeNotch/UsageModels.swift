import Foundation

// Token and cost counters, and their per-day rollup.

struct UsageStats: Codable {
    var allowed: Int = 0
    var denied: Int = 0
    var autoApproved: Int = 0
    /// Denied without asking you: auto mode's classifier said no. Counted
    /// apart from `denied`, which is denials you made yourself.
    var autoDenied: Int = 0
    var dangerousFlagged: Int = 0
    var questionsAnswered: Int = 0
    var toolCounts: [String: Int] = [:]
    var activeDays: [String] = []   // yyyy-MM-dd, deduped, oldest→newest
    var firstUsed: Date? = nil
    /// Per-day counts (keyed yyyy-MM-dd) for the heatmap + daily digest.
    var dailyCounts: [String: DayCounts] = [:]
}

struct DayCounts: Codable {
    var allowed: Int = 0
    var denied: Int = 0
    var autoApproved: Int = 0
    var autoDenied: Int = 0
    var dangerousFlagged: Int = 0
    var tools: Int = 0   // total tool requests that day
    var total: Int { allowed + denied }
}

// Resilient decoders: Swift's synthesized Decodable ignores a property's
// default and throws keyNotFound when a key is absent, so adding any new
// field in a release would make an older state.json fail to decode and wipe
// all stats on update. Decoding every key with decodeIfPresent ?? default
// keeps old snapshots loadable as the schema grows. (Defined in extensions so
// the synthesized memberwise + no-arg inits are preserved.)
extension UsageStats {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowed = try c.decodeIfPresent(Int.self, forKey: .allowed) ?? allowed
        denied = try c.decodeIfPresent(Int.self, forKey: .denied) ?? denied
        autoApproved = try c.decodeIfPresent(Int.self, forKey: .autoApproved) ?? autoApproved
        autoDenied = try c.decodeIfPresent(Int.self, forKey: .autoDenied) ?? autoDenied
        dangerousFlagged = try c.decodeIfPresent(Int.self, forKey: .dangerousFlagged) ?? dangerousFlagged
        questionsAnswered = try c.decodeIfPresent(Int.self, forKey: .questionsAnswered) ?? questionsAnswered
        toolCounts = try c.decodeIfPresent([String: Int].self, forKey: .toolCounts) ?? toolCounts
        activeDays = try c.decodeIfPresent([String].self, forKey: .activeDays) ?? activeDays
        firstUsed = try c.decodeIfPresent(Date.self, forKey: .firstUsed) ?? firstUsed
        dailyCounts = try c.decodeIfPresent([String: DayCounts].self, forKey: .dailyCounts) ?? dailyCounts
    }
}

extension DayCounts {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowed = try c.decodeIfPresent(Int.self, forKey: .allowed) ?? allowed
        denied = try c.decodeIfPresent(Int.self, forKey: .denied) ?? denied
        autoApproved = try c.decodeIfPresent(Int.self, forKey: .autoApproved) ?? autoApproved
        autoDenied = try c.decodeIfPresent(Int.self, forKey: .autoDenied) ?? autoDenied
        dangerousFlagged = try c.decodeIfPresent(Int.self, forKey: .dangerousFlagged) ?? dangerousFlagged
        tools = try c.decodeIfPresent(Int.self, forKey: .tools) ?? tools
    }
}

/// One auto-approval rule. The `commandRegex` is optional: nil means
/// "match any input for this tool" (the old tool-wide always-allow),
/// non-nil means "this tool AND the command matches this regex".
/// Persisted across launches.

/// A Claude apps gateway spend limit, from the status line's
/// `rate_limits.spend_limit` (CLI 2.1.271+). The dollar amounts and the period
/// arrive only from CLI 2.1.284 against a gateway that runs it too, so each is
/// optional: a percentage alone is still worth showing.
struct GatewaySpend: Equatable {
    var percent: Double            // 0...1
    var resetsAt: Date?
    var usedUSD: Double?
    var limitUSD: Double?
    var period: String = ""        // e.g. "month", as the gateway names it

    /// "$271.40 of $500.00 this month", or nil without both amounts.
    var amountText: String? {
        guard let usedUSD, let limitUSD else { return nil }
        let p = period.isEmpty ? "" : String(format: L(" this %@", comment: "Spend-limit period suffix; %@ is a period such as month"), period)
        return String(format: L("%1$@ of %2$@", comment: "Spend limit: amount used of the limit"),
                      ClaudeUsageReader.fmtMoney(usedUSD), ClaudeUsageReader.fmtMoney(limitUSD)) + p
    }
}
