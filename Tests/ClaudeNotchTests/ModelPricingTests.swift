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
}
