import XCTest
@testable import QuietVibeStatus

final class ModelPricingTests: XCTestCase {
    func testRateMatchesKnownModels() {
        XCTAssertEqual(ModelPricing.rate(for: "claude-opus-4-8")?.input, 5)
        XCTAssertEqual(ModelPricing.rate(for: "claude-sonnet-5")?.output, 15)
        XCTAssertEqual(ModelPricing.rate(for: "claude-haiku-4-5-20251001")?.input, 1)
        XCTAssertEqual(ModelPricing.rate(for: "claude-fable-5")?.output, 50)
    }

    func testUnknownOrEmptyModelHasNoRate() {
        XCTAssertNil(ModelPricing.rate(for: nil))
        XCTAssertNil(ModelPricing.rate(for: ""))
        XCTAssertNil(ModelPricing.rate(for: "gpt-4"))
    }

    /// Cache reads are the whole economic case for caching — they must be an order of magnitude
    /// below base input, and writes a small premium above it.
    func testCacheRatesDeriveFromInput() {
        let rate = ModelPricing.rate(for: "claude-opus-4-8")!
        XCTAssertEqual(rate.cacheRead, 0.5, accuracy: 0.0001)   // 0.1x of $5
        XCTAssertEqual(rate.cacheWrite, 6.25, accuracy: 0.0001) // 1.25x of $5
    }

    func testCostSumsEveryTokenClass() {
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheWrite: 1_000_000, cacheRead: 1_000_000)
        // Opus 4.8: 5 + 25 + 6.25 + 0.5
        XCTAssertEqual(ModelPricing.cost(of: usage, model: "claude-opus-4-8")!, 36.75, accuracy: 0.001)
    }

    func testCostIsNilWithoutAPrice() {
        let usage = TokenUsage(input: 1000, output: 1000)
        XCTAssertNil(ModelPricing.cost(of: usage, model: "unknown-model"))
        XCTAssertNil(ModelPricing.cost(of: TokenUsage(), model: "claude-opus-4-8"))
    }

    func testSubCentCostsReadAsLessThanOne() {
        XCTAssertEqual(ModelPricing.format(0.004), "<1¢")
        XCTAssertEqual(ModelPricing.format(0.42), "42¢")
        XCTAssertEqual(ModelPricing.format(3.5), "$3.50")
        XCTAssertEqual(ModelPricing.format(250), "$250")
    }

    func testTokenFormattingIsCompact() {
        XCTAssertEqual(ModelPricing.formatTokens(950), "950")
        XCTAssertEqual(ModelPricing.formatTokens(1500), "1.5k")
        XCTAssertEqual(ModelPricing.formatTokens(2_400_000), "2.4M")
    }

    func testUsageAddsComponentwise() {
        let a = TokenUsage(input: 10, output: 20, cacheWrite: 30, cacheRead: 40)
        let b = TokenUsage(input: 1, output: 2, cacheWrite: 3, cacheRead: 4)
        let sum = a + b
        XCTAssertEqual(sum.input, 11)
        XCTAssertEqual(sum.output, 22)
        XCTAssertEqual(sum.cacheWrite, 33)
        XCTAssertEqual(sum.cacheRead, 44)
        XCTAssertEqual(sum.totalTokens, 110)
    }
}
