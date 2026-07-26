import Foundation

// Token and cost counters, and their per-day rollup.

struct UsageStats: Codable {
    var allowed: Int = 0
    var denied: Int = 0
    var autoApproved: Int = 0
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
        dangerousFlagged = try c.decodeIfPresent(Int.self, forKey: .dangerousFlagged) ?? dangerousFlagged
        tools = try c.decodeIfPresent(Int.self, forKey: .tools) ?? tools
    }
}

/// One auto-approval rule. The `commandRegex` is optional: nil means
/// "match any input for this tool" (the old tool-wide always-allow),
/// non-nil means "this tool AND the command matches this regex".
/// Persisted across launches.
