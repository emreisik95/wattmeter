import Foundation
import os

struct ModelPricing: Codable, Hashable {
    let inputPerMTok: Double
    let outputPerMTok: Double

    var cacheWrite5mPerMTok: Double { inputPerMTok * 1.25 }
    var cacheWrite1hPerMTok: Double { inputPerMTok * 2.0 }
    var cacheReadPerMTok: Double { inputPerMTok * 0.1 }
}

/// Row used by the pricing table singleton + diff engine. Keyed by canonical model id.
struct PriceRow: Codable, Hashable {
    let model: String
    let inputPerMTok: Double
    let outputPerMTok: Double

    var modelPricing: ModelPricing {
        ModelPricing(inputPerMTok: inputPerMTok, outputPerMTok: outputPerMTok)
    }
}

/// Thread-safe singleton holding the live pricing table.
///
/// Parser.swift runs on a detached `.utility` Task and calls `Pricing.cost(usage:model:)`
/// per JSONL line; reads must be lock-protected. Writes (from PricingMonitor) are
/// atomic-replace via `setTable(_:)`.
final class PricingTable: @unchecked Sendable {
    static let shared = PricingTable()

    private let lock = OSAllocatedUnfairLock<[String: PriceRow]>(initialState: [:])

    private init() {}

    /// Atomic replacement of the entire table.
    func setTable(_ rows: [PriceRow]) {
        var dict: [String: PriceRow] = [:]
        for r in rows { dict[canonical(r.model)] = r }
        let final = dict
        lock.withLock { state in state = final }
    }

    /// Snapshot of the current table.
    func snapshot() -> [String: PriceRow] {
        lock.withLock { $0 }
    }

    /// Family-aware lookup. Falls back to family heuristics if exact id miss.
    func lookup(_ model: String) -> ModelPricing? {
        let key = canonical(model)
        let table = lock.withLock { $0 }
        if let exact = table[key] { return exact.modelPricing }
        let m = key.lowercased()
        // Family fallback against any row in the table.
        if let row = table.values.first(where: { canonical($0.model).lowercased().contains(family(of: m) ?? "__none__") }) {
            return row.modelPricing
        }
        return nil
    }

    private func canonical(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func family(of model: String) -> String? {
        if model.contains("fable") { return "fable" }
        if model.contains("opus") { return "opus" }
        if model.contains("haiku") { return "haiku" }
        if model.contains("sonnet") { return "sonnet" }
        return nil
    }
}

enum Pricing {
    // Static fallbacks retained for backward-compat and as boot defaults when
    // bundled Resources/pricing.json fails to load.
    static let fable   = ModelPricing(inputPerMTok: 10.0, outputPerMTok: 50.0)
    static let opus    = ModelPricing(inputPerMTok: 15.0, outputPerMTok: 75.0)
    static let sonnet  = ModelPricing(inputPerMTok: 3.0,  outputPerMTok: 15.0)
    static let haiku   = ModelPricing(inputPerMTok: 0.80, outputPerMTok: 4.0)
    static let unknown = ModelPricing(inputPerMTok: 0,    outputPerMTok: 0)

    /// Family-aware pricing lookup. Consults the singleton first; falls back to
    /// hard-coded family constants so callers always get a usable price.
    static func price(for model: String) -> ModelPricing {
        if let live = PricingTable.shared.lookup(model) { return live }
        let m = model.lowercased()
        if m.contains("fable")  { return fable }
        if m.contains("opus")   { return opus }
        if m.contains("haiku")  { return haiku }
        if m.contains("sonnet") { return sonnet }
        return unknown
    }

    /// Recompute cost from an entry's stored token counts using the live table.
    /// Entries persist their parse-time cost; this derives the current one.
    static func cost(entry e: UsageEntry) -> Double {
        let p = price(for: e.model)
        let s = 1.0 / 1_000_000.0
        return Double(e.inputTokens) * p.inputPerMTok * s
             + Double(e.outputTokens) * p.outputPerMTok * s
             + Double(e.cacheWrite5m) * p.cacheWrite5mPerMTok * s
             + Double(e.cacheWrite1h) * p.cacheWrite1hPerMTok * s
             + Double(e.cacheRead) * p.cacheReadPerMTok * s
    }

    /// Reprice Claude entries against the current pricing table. Costs are
    /// baked in at parse time and survive in the snapshot cache, so entries
    /// parsed under an older pricing table (e.g. before a model existed in
    /// it) would otherwise keep their stale cost forever. Entries from other
    /// providers keep their provider-computed cost.
    static func repriced(_ entries: [UsageEntry]) -> [UsageEntry] {
        entries.map { e in
            guard e.providerOrClaude == ProviderID.claude else { return e }
            var copy = e
            copy.cost = cost(entry: e)
            return copy
        }
    }

    /// PRESERVED signature — Parser.swift:98 calls this unchanged.
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
