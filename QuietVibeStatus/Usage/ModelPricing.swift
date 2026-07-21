import Foundation

/// Token counts pulled from a session's transcript.
struct TokenUsage: Equatable, Codable {
    var input: Int = 0
    var output: Int = 0
    var cacheWrite: Int = 0
    var cacheRead: Int = 0

    var isEmpty: Bool {
        input == 0 && output == 0 && cacheWrite == 0 && cacheRead == 0
    }

    /// Everything the model read, however it was billed. The headline number on a card.
    var totalTokens: Int {
        input + output + cacheWrite + cacheRead
    }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }
}

/// Published list prices, in dollars per million tokens.
///
/// This is a local estimate, not a bill. Subscription plans don't charge per token at all, prices
/// change, and promotional rates expire — the number on a card answers "how heavy was this
/// session", not "what do I owe".
enum ModelPricing {
    struct Rate {
        /// Dollars per million input tokens.
        let input: Double
        /// Dollars per million output tokens.
        let output: Double

        /// Writing to the cache costs 1.25x base input on the default five-minute TTL.
        var cacheWrite: Double { input * 1.25 }
        /// Reading from the cache costs 0.1x base input — the whole point of caching.
        var cacheRead: Double { input * 0.1 }
    }

    /// Matched by substring against the raw model id, longest needle first so `opus-4-8` cannot be
    /// shadowed by a shorter prefix.
    private static let table: [(needle: String, rate: Rate)] = [
        ("fable-5", Rate(input: 10, output: 50)),
        ("mythos-5", Rate(input: 10, output: 50)),
        ("opus-4-8", Rate(input: 5, output: 25)),
        ("opus-4-7", Rate(input: 5, output: 25)),
        ("opus-4-6", Rate(input: 5, output: 25)),
        ("sonnet-5", Rate(input: 3, output: 15)),
        ("sonnet-4-6", Rate(input: 3, output: 15)),
        ("haiku-4-5", Rate(input: 1, output: 5)),
    ]

    static func rate(for model: String?) -> Rate? {
        guard let model, !model.isEmpty else { return nil }
        // Normalize so the display label ("Opus 4.8") matches the same needle as the raw id
        // ("claude-opus-4-8") — a restored session may only carry the friendly label.
        let normalized = model.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return table.first { normalized.contains($0.needle) }?.rate
    }

    /// Estimated dollars for a session, or nil when we don't have a price for the model.
    static func cost(of usage: TokenUsage, model: String?) -> Double? {
        guard let rate = rate(for: model), !usage.isEmpty else { return nil }
        let millions = 1_000_000.0
        return Double(usage.input) / millions * rate.input
            + Double(usage.output) / millions * rate.output
            + Double(usage.cacheWrite) / millions * rate.cacheWrite
            + Double(usage.cacheRead) / millions * rate.cacheRead
    }

    /// Short display form: sub-cent costs read as "<1¢" rather than "$0.00", which looks like free.
    static func format(_ dollars: Double) -> String {
        if dollars < 0.01 { return "<1¢" }
        if dollars < 1 { return String(format: "%.0f¢", dollars * 100) }
        if dollars < 100 { return String(format: "$%.2f", dollars) }
        return String(format: "$%.0f", dollars)
    }

    /// Compact token count: 1200 -> "1.2k", 1_450_000 -> "1.5M".
    static func formatTokens(_ count: Int) -> String {
        switch count {
        case ..<1000: return "\(count)"
        case ..<1_000_000: return String(format: "%.1fk", Double(count) / 1000)
        default: return String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }
}
