import Foundation

struct ModelPricing {
    let inputPerMTok: Double
    let outputPerMTok: Double

    var cacheWrite5mPerMTok: Double { inputPerMTok * 1.25 }
    var cacheWrite1hPerMTok: Double { inputPerMTok * 2.0 }
    var cacheReadPerMTok: Double { inputPerMTok * 0.1 }
}

enum Pricing {
    static let opus   = ModelPricing(inputPerMTok: 15.0, outputPerMTok: 75.0)
    static let sonnet = ModelPricing(inputPerMTok: 3.0, outputPerMTok: 15.0)
    static let haiku  = ModelPricing(inputPerMTok: 0.80, outputPerMTok: 4.0)
    static let unknown = ModelPricing(inputPerMTok: 0, outputPerMTok: 0)

    static func price(for model: String) -> ModelPricing {
        let m = model.lowercased()
        if m.contains("opus") { return opus }
        if m.contains("haiku") { return haiku }
        if m.contains("sonnet") { return sonnet }
        return unknown
    }

    static func cost(usage: TranscriptUsage, model: String) -> Double {
        let p = price(for: model)
        let s = 1.0 / 1_000_000.0
        let cache5m = usage.cache_creation?.ephemeral_5m_input_tokens
            ?? usage.cache_creation_input_tokens ?? 0
        let cache1h = usage.cache_creation?.ephemeral_1h_input_tokens ?? 0
        let cacheR  = usage.cache_read_input_tokens ?? 0
        let inp     = usage.input_tokens ?? 0
        let out     = usage.output_tokens ?? 0
        return Double(inp) * p.inputPerMTok * s
             + Double(out) * p.outputPerMTok * s
             + Double(cache5m) * p.cacheWrite5mPerMTok * s
             + Double(cache1h) * p.cacheWrite1hPerMTok * s
             + Double(cacheR) * p.cacheReadPerMTok * s
    }
}
