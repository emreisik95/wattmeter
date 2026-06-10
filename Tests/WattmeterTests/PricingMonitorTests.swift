import XCTest
@testable import Wattmeter

@MainActor
final class PricingMonitorTests: XCTestCase {

    func test_diff_identifies_changed_models() {
        let old = PricingDocument(version: 1, updated: nil, models: [
            "claude-opus-4-7":   .init(inputPerMTok: 15.0, outputPerMTok: 75.0),
            "claude-sonnet-4-6": .init(inputPerMTok: 3.0,  outputPerMTok: 15.0)
        ])
        let new = PricingDocument(version: 1, updated: nil, models: [
            "claude-opus-4-7":   .init(inputPerMTok: 18.0, outputPerMTok: 90.0), // changed
            "claude-sonnet-4-6": .init(inputPerMTok: 3.0,  outputPerMTok: 15.0)  // unchanged
        ])
        let diffs = old.diff(against: new)
        XCTAssertEqual(diffs.count, 1)
        let d = diffs[0]
        XCTAssertEqual(d.model, "claude-opus-4-7")
        XCTAssertEqual(d.oldInputUSD, 15.0)
        XCTAssertEqual(d.newInputUSD, 18.0)
        XCTAssertEqual(d.oldOutputUSD, 75.0)
        XCTAssertEqual(d.newOutputUSD, 90.0)
    }

    func test_diff_ignores_added_models() {
        let old = PricingDocument(version: 1, updated: nil, models: [
            "claude-opus-4-7": .init(inputPerMTok: 15.0, outputPerMTok: 75.0)
        ])
        let new = PricingDocument(version: 1, updated: nil, models: [
            "claude-opus-4-7":  .init(inputPerMTok: 15.0, outputPerMTok: 75.0),
            "claude-haiku-4-5": .init(inputPerMTok: 0.8,  outputPerMTok: 4.0)
        ])
        let diffs = old.diff(against: new)
        XCTAssertTrue(diffs.isEmpty)
    }

    func test_diff_ignores_removed_models() {
        let old = PricingDocument(version: 1, updated: nil, models: [
            "claude-opus-4-7":   .init(inputPerMTok: 15.0, outputPerMTok: 75.0),
            "claude-sonnet-4-6": .init(inputPerMTok: 3.0,  outputPerMTok: 15.0)
        ])
        let new = PricingDocument(version: 1, updated: nil, models: [
            "claude-opus-4-7": .init(inputPerMTok: 15.0, outputPerMTok: 75.0)
        ])
        XCTAssertTrue(old.diff(against: new).isEmpty)
    }

    func test_diff_no_change_returns_empty() {
        let doc = PricingDocument(version: 1, updated: nil, models: [
            "claude-opus-4-7": .init(inputPerMTok: 15.0, outputPerMTok: 75.0)
        ])
        XCTAssertTrue(doc.diff(against: doc).isEmpty)
    }

    func test_pricingTable_lookup_after_seed() {
        let seed = PricingDocument(version: 1, updated: nil, models: [
            "claude-opus-4-7": .init(inputPerMTok: 12.0, outputPerMTok: 60.0)
        ])
        PricingTable.shared.setTable(seed.rows)
        let p = PricingTable.shared.lookup("claude-opus-4-7")
        XCTAssertEqual(p?.inputPerMTok, 12.0)
        XCTAssertEqual(p?.outputPerMTok, 60.0)
    }

    func test_pricing_cost_uses_singleton_table() {
        // Override table with custom prices, then verify Pricing.cost reflects them.
        let custom = PricingDocument(version: 1, updated: nil, models: [
            "claude-opus-4-7": .init(inputPerMTok: 100.0, outputPerMTok: 200.0)
        ])
        PricingTable.shared.setTable(custom.rows)
        defer {
            // Reset to defaults so other tests aren't affected.
            PricingTable.shared.setTable(PricingLoader.defaultDocument.rows)
        }

        let usage = TranscriptUsage(
            input_tokens: 1_000_000,
            output_tokens: 1_000_000,
            cache_creation_input_tokens: nil,
            cache_read_input_tokens: nil,
            cache_creation: nil
        )
        let c = Pricing.cost(usage: usage, model: "claude-opus-4-7")
        // 1M @ $100 + 1M @ $200 = $300
        XCTAssertEqual(c, 300.0, accuracy: 0.0001)
    }

    func test_fable_pricing_exact_and_bracket_variant() {
        PricingTable.shared.setTable(PricingLoader.defaultDocument.rows)
        defer { PricingTable.shared.setTable(PricingLoader.defaultDocument.rows) }

        let exact = PricingTable.shared.lookup("claude-fable-5")
        XCTAssertEqual(exact?.inputPerMTok, 10.0)
        XCTAssertEqual(exact?.outputPerMTok, 50.0)

        // Runtime model ids can carry a context-window suffix; family
        // fallback must still resolve them.
        let variant = PricingTable.shared.lookup("claude-fable-5[1m]")
        XCTAssertEqual(variant?.inputPerMTok, 10.0)
        XCTAssertEqual(variant?.outputPerMTok, 50.0)

        // Cache rates derive from input price.
        XCTAssertEqual(exact?.cacheReadPerMTok ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(exact?.cacheWrite5mPerMTok ?? 0, 12.5, accuracy: 0.0001)
        XCTAssertEqual(exact?.cacheWrite1hPerMTok ?? 0, 20.0, accuracy: 0.0001)
    }

    func test_repriced_updates_claude_entry_costs() {
        PricingTable.shared.setTable(PricingLoader.defaultDocument.rows)
        defer { PricingTable.shared.setTable(PricingLoader.defaultDocument.rows) }

        // Entry persisted under old pricing (fable unknown → $0 cost).
        let stale = UsageEntry(
            id: "t1", timestamp: Date(), model: "claude-fable-5",
            project: "p", sessionId: "s",
            inputTokens: 1_000_000, outputTokens: 0,
            cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 1_000_000,
            cost: 0, provider: nil
        )
        // Non-Claude entries keep their original cost untouched.
        let other = UsageEntry(
            id: "t2", timestamp: Date(), model: "gpt-x",
            project: "p", sessionId: "s",
            inputTokens: 1_000_000, outputTokens: 0,
            cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0,
            cost: 1.23, provider: "codex"
        )

        let out = Pricing.repriced([stale, other])
        // 1M input @ $10 + 1M cache read @ $1 = $11
        XCTAssertEqual(out[0].cost, 11.0, accuracy: 0.0001)
        XCTAssertEqual(out[1].cost, 1.23, accuracy: 0.0001)
    }

    func test_fable_static_fallback_when_table_empty() {
        PricingTable.shared.setTable([])
        defer { PricingTable.shared.setTable(PricingLoader.defaultDocument.rows) }

        let p = Pricing.price(for: "claude-fable-5")
        XCTAssertEqual(p.inputPerMTok, 10.0)
        XCTAssertEqual(p.outputPerMTok, 50.0)
    }

    func test_engine_refresh_with_mock_fetcher_emits_changes() async {
        let seed = PricingDocument(version: 1, updated: nil, models: [
            "claude-opus-4-7": .init(inputPerMTok: 15.0, outputPerMTok: 75.0)
        ])
        struct StubFetcher: PricingFetcher {
            let doc: PricingDocument
            func fetchRemote() async throws -> PricingDocument { doc }
        }
        let remote = PricingDocument(version: 1, updated: nil, models: [
            "claude-opus-4-7": .init(inputPerMTok: 20.0, outputPerMTok: 90.0)
        ])
        let engine = PricingMonitorEngine(fetcher: StubFetcher(doc: remote), seed: seed)
        let diffs = await engine.refresh()
        XCTAssertEqual(diffs.count, 1)
        XCTAssertEqual(engine.changes.count, 1)
        // After refresh, the active table should hold the new prices.
        XCTAssertEqual(PricingTable.shared.lookup("claude-opus-4-7")?.inputPerMTok, 20.0)
    }
}
