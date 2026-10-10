import Foundation

/// Anthropic's public per-million-token prices, used to estimate what a
/// session cost. Source: the Claude pricing page (October 2026).
///
/// Prices are per model version, not per family. They used to be per family,
/// which was right while every Opus cost the same; then Opus 5.5 came in
/// cheaper than Opus 5, Sonnet 5 dropped to $2/$10, and Fable arrived at
/// five times Sonnet, and a family-wide price was wrong for all three.
///
/// Cache writes have two prices. Claude Code writes its prompt cache with the
/// one-hour lifetime, which costs 2x the base input price, not the 1.25x of
/// the five-minute one; the transcript says which was used per message
/// (`usage.cache_creation`), so both are priced as written.
struct ModelPrice: Equatable {
    var input: Double
    var output: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double
    var cacheRead: Double
}

enum ModelPricing {
    /// The price of a model id, by family and version. A version newer than
    /// any listed here takes the newest listed price for its family; an id we
    /// cannot place at all is priced as the current Sonnet.
    nonisolated static func price(for model: String) -> ModelPrice {
        let m = model.lowercased()
        let v = ClaudeUsageReader.modelVersion(m) ?? 0
        if m.contains("fable") || m.contains("mythos") {
            // Cache hits on the 5.1 generation are 2.5% of input, not 10%.
            return ModelPrice(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: v >= 5.1 ? 0.25 : 1)
        }
        if m.contains("opus") {
            if v >= 5.5 { return ModelPrice(input: 4, output: 20, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.2) }
            if v >= 4.5 { return ModelPrice(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5) }
            return ModelPrice(input: 15, output: 75, cacheWrite5m: 18.75, cacheWrite1h: 30, cacheRead: 1.5)
        }
        if m.contains("haiku") {
            // Haiku 5.5: a tenth of Haiku 4.5's price for a prompt up to 100K tokens
            if v >= 5.5 { return ModelPrice(input: 0.1, output: 0.5, cacheWrite5m: 0.125, cacheWrite1h: 0.2, cacheRead: 0.01) }
            if v > 0 && v < 4.5 { return ModelPrice(input: 0.8, output: 4, cacheWrite5m: 1, cacheWrite1h: 1.6, cacheRead: 0.08) }
            return ModelPrice(input: 1, output: 5, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.1)
        }
        if m.contains("sonnet"), v > 0, v < 5 {
            return ModelPrice(input: 3, output: 15, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.3)
        }
        return ModelPrice(input: 2, output: 10, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.2)   // Sonnet 5 and later
    }

    /// Estimated cost in dollars of one message's usage.
    nonisolated static func cost(input: Int, output: Int, cacheRead: Int, cacheWrite5m: Int, cacheWrite1h: Int, model: String) -> Double {
        let p = price(for: model)
        return (Double(input) * p.input + Double(output) * p.output + Double(cacheRead) * p.cacheRead
              + Double(cacheWrite5m) * p.cacheWrite5m + Double(cacheWrite1h) * p.cacheWrite1h) / 1_000_000
    }

    /// What reading `cacheRead` tokens from the cache saved over sending them fresh.
    nonisolated static func cacheSavings(cacheRead: Int, model: String) -> Double {
        let p = price(for: model)
        return Double(cacheRead) * (p.input - p.cacheRead) / 1_000_000
    }

    /// Split a message's cache writes into five-minute and one-hour tokens.
    ///
    /// Reads `usage.cache_creation` when the transcript has it. Older
    /// transcripts carry only the total, which was always the five-minute
    /// kind then. If the breakdown is there but does not add up to the total,
    /// the remainder is counted at the five-minute price.
    nonisolated static func cacheWrites(_ usage: [String: Any]) -> (fiveMinute: Int, oneHour: Int) {
        let total = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        guard let split = usage["cache_creation"] as? [String: Any] else { return (total, 0) }
        let hour = (split["ephemeral_1h_input_tokens"] as? Int) ?? 0
        let five = (split["ephemeral_5m_input_tokens"] as? Int) ?? 0
        return (max(five, total - hour), hour)
    }
}
