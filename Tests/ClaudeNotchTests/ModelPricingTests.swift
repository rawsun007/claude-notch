import XCTest
@testable import ClaudeNotch

/// Prices follow the model version, and cache writes are priced at the
/// lifetime they were written with.
final class ModelPricingTests: XCTestCase {

    func testCurrentModels() {
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-5-5"), ModelPrice(input: 4, output: 20, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.2))
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-5"), ModelPrice(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5))
        XCTAssertEqual(ModelPricing.price(for: "claude-sonnet-5").input, 2)
        XCTAssertEqual(ModelPricing.price(for: "claude-sonnet-5-5").output, 10)
        XCTAssertEqual(ModelPricing.price(for: "claude-haiku-4-5-20251001").input, 1)
    }

    func testOlderModels() {
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4-8").input, 5)
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4-1-20250805").input, 15)
        XCTAssertEqual(ModelPricing.price(for: "claude-sonnet-4-6").input, 3)
        XCTAssertEqual(ModelPricing.price(for: "claude-3-5-haiku-20241022").input, 0.8)
    }

    func testFableAndMythos() {
        let fable51 = ModelPricing.price(for: "claude-fable-5-1")
        XCTAssertEqual(fable51.input, 10)
        XCTAssertEqual(fable51.output, 50)
        XCTAssertEqual(fable51.cacheRead, 0.25)
        XCTAssertEqual(ModelPricing.price(for: "claude-fable-5").cacheRead, 1)
        XCTAssertEqual(ModelPricing.price(for: "claude-mythos-5-1"), fable51)
    }

    func testUnknownAndNewerVersions() {
        XCTAssertEqual(ModelPricing.price(for: "something-new").input, 2)
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-6").input, 4)     // newest listed Opus price
    }

    func testOneHourCacheWritesCostMore() {
        let fiveMinute = ModelPricing.cost(input: 0, output: 0, cacheRead: 0, cacheWrite5m: 1_000_000, cacheWrite1h: 0, model: "claude-opus-5-5")
        let oneHour = ModelPricing.cost(input: 0, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 1_000_000, model: "claude-opus-5-5")
        XCTAssertEqual(fiveMinute, 5, accuracy: 1e-9)
        XCTAssertEqual(oneHour, 8, accuracy: 1e-9)
    }

    func testCost() {
        let c = ModelPricing.cost(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite5m: 0, cacheWrite1h: 0, model: "claude-sonnet-5")
        XCTAssertEqual(c, 2 + 10 + 0.2, accuracy: 1e-9)
    }

    func testCacheWriteSplit() {
        let split = ModelPricing.cacheWrites(["cache_creation_input_tokens": 1911,
                                              "cache_creation": ["ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 1911]])
        XCTAssertEqual(split.fiveMinute, 0)
        XCTAssertEqual(split.oneHour, 1911)
        let legacy = ModelPricing.cacheWrites(["cache_creation_input_tokens": 500])
        XCTAssertEqual(legacy.fiveMinute, 500)
        XCTAssertEqual(legacy.oneHour, 0)
        let short = ModelPricing.cacheWrites(["cache_creation_input_tokens": 300,
                                              "cache_creation": ["ephemeral_1h_input_tokens": 100]])
        XCTAssertEqual(short.fiveMinute, 200)
        XCTAssertEqual(short.oneHour, 100)
    }

    func testSavings() {
        XCTAssertEqual(ModelPricing.cacheSavings(cacheRead: 1_000_000, model: "claude-fable-5-1"), 9.75, accuracy: 1e-9)
    }

    // MARK: - Haiku 5.5 (CLI 2.1.293) and Sonnet 5.5 cache reads (CLI 2.1.296)

    func testHaiku55IsATenthOfHaiku45() {
        XCTAssertEqual(ModelPricing.price(for: "claude-haiku-5-5"),
                       ModelPrice(input: 0.1, output: 0.5, cacheWrite5m: 0.125, cacheWrite1h: 0.2, cacheRead: 0.01))
        XCTAssertEqual(ModelPricing.price(for: "claude-haiku-4-5-20251001").input, 1)
    }

    /// The long-context price is per request and counts the whole prompt,
    /// cache reads and writes included, the way Anthropic bills it.
    func testHaiku55LongPromptPricing() {
        XCTAssertEqual(ModelPricing.price(for: "claude-haiku-5-5", promptTokens: 100_000).input, 0.1)
        XCTAssertEqual(ModelPricing.price(for: "claude-haiku-5-5", promptTokens: 100_001),
                       ModelPrice(input: 0.5, output: 2.5, cacheWrite5m: 0.625, cacheWrite1h: 1, cacheRead: 0.05))
        // 2K fresh input over a 120K cached prompt: the cache read tips it over
        let long = ModelPricing.cost(input: 2_000, output: 1_000_000, cacheRead: 120_000, cacheWrite5m: 0, cacheWrite1h: 0, model: "claude-haiku-5-5")
        XCTAssertEqual(long, (2_000 * 0.5 + 1_000_000 * 2.5 + 120_000 * 0.05) / 1_000_000, accuracy: 1e-9)
        let short = ModelPricing.cost(input: 2_000, output: 1_000_000, cacheRead: 50_000, cacheWrite5m: 0, cacheWrite1h: 0, model: "claude-haiku-5-5")
        XCTAssertEqual(short, (2_000 * 0.1 + 1_000_000 * 0.5 + 50_000 * 0.01) / 1_000_000, accuracy: 1e-9)
    }

    /// Only Haiku 5.5 has a long-context price; a big prompt on any other
    /// model costs the same per token.
    func testOtherModelsIgnorePromptLength() {
        for m in ["claude-opus-5-5", "claude-sonnet-5", "claude-fable-5-1", "claude-haiku-4-5"] {
            XCTAssertEqual(ModelPricing.price(for: m, promptTokens: 900_000), ModelPricing.price(for: m), m)
        }
    }

    func testSonnet55CacheReads() {
        XCTAssertEqual(ModelPricing.price(for: "claude-sonnet-5-5").cacheRead, 0.1)
        XCTAssertEqual(ModelPricing.price(for: "claude-sonnet-5").cacheRead, 0.2)
        XCTAssertEqual(ModelPricing.price(for: "claude-sonnet-5-5").input, 2)
    }
}
