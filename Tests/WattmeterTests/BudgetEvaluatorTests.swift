import XCTest
@testable import Wattmeter

@MainActor
final class BudgetEvaluatorTests: XCTestCase {

    override func setUp() async throws {
        BudgetEvaluatorState.shared.resetAll()
    }

    private func entry(cost: Double, at date: Date = Date()) -> UsageEntry {
        UsageEntry(
            id: UUID().uuidString,
            timestamp: date,
            model: "claude-opus-4-7",
            project: "p",
            sessionId: "s",
            inputTokens: 0, outputTokens: 0,
            cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0,
            cost: cost,
            provider: nil
        )
    }

    func test_crossing_50_emits_crossed50_once() {
        let b = Budget(label: "daily", amountUSD: 10, window: .daily)
        let now = Date()
        let entries = [entry(cost: 5.0, at: now)] // 50%

        let evaluator = BudgetEvaluator()
        let events1 = evaluator.computeEvents(entries: entries, budgets: [b], now: now)
        XCTAssertEqual(events1.map(\.kind), [.crossed50])

        // Re-evaluate same window → no re-fire
        let events2 = evaluator.computeEvents(entries: entries, budgets: [b], now: now)
        XCTAssertTrue(events2.isEmpty)
    }

    func test_crossing_directly_to_exceeded_fires_all_lower_thresholds() {
        let b = Budget(label: "daily", amountUSD: 10, window: .daily)
        let now = Date()
        let entries = [entry(cost: 11.0, at: now)] // 110%

        let evaluator = BudgetEvaluator()
        let events = evaluator.computeEvents(entries: entries, budgets: [b], now: now)
        let kinds = events.map(\.kind)
        XCTAssertEqual(kinds, [.crossed50, .crossed75, .crossed90, .exceeded])
    }

    func test_threshold_resets_when_window_rolls() {
        let b = Budget(label: "daily", amountUSD: 10, window: .daily)
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(86_400 * 2)
        let entries1 = [entry(cost: 6.0, at: day1)]
        let entries2 = [entry(cost: 6.0, at: day2)]

        let evaluator = BudgetEvaluator()
        let e1 = evaluator.computeEvents(entries: entries1, budgets: [b], now: day1)
        XCTAssertEqual(e1.map(\.kind), [.crossed50])

        // Same window, no entries to count anyway → empty
        let e1again = evaluator.computeEvents(entries: entries1, budgets: [b], now: day1)
        XCTAssertTrue(e1again.isEmpty)

        // New window, new spend → fires again
        let e2 = evaluator.computeEvents(entries: entries2, budgets: [b], now: day2)
        XCTAssertEqual(e2.map(\.kind), [.crossed50])
    }

    func test_spend_filters_by_window() {
        let now = Date(timeIntervalSince1970: 1_700_000_000) // some day
        let yesterday = now.addingTimeInterval(-86_400)
        let entries = [
            entry(cost: 1.0, at: now),
            entry(cost: 5.0, at: yesterday)
        ]
        let spent = BudgetEvaluator.spend(entries: entries, window: .daily, now: now)
        XCTAssertEqual(spent, 1.0, accuracy: 0.0001)
    }

    func test_hardcap_sentinel_writes_atomically() throws {
        let b = Budget(id: UUID(), label: "test", amountUSD: 5, window: .daily, hardCap: true)
        BudgetEvaluator.clearHardCapSentinel()
        BudgetEvaluator.writeHardCapSentinel(budget: b)
        defer { BudgetEvaluator.clearHardCapSentinel() }

        let data = try Data(contentsOf: BudgetEvaluator.hardCapSentinelURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["breached"] as? Bool, true)
        XCTAssertEqual(obj?["budget"] as? String, b.id.uuidString)
        XCTAssertEqual(obj?["window"] as? String, "daily")
    }

    func test_session_window_uses_trailing_5_hours() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fourHoursAgo = now.addingTimeInterval(-4 * 3600)
        let sixHoursAgo  = now.addingTimeInterval(-6 * 3600)
        let entries = [
            entry(cost: 2.0, at: fourHoursAgo),
            entry(cost: 99.0, at: sixHoursAgo)
        ]
        let spent = BudgetEvaluator.spend(entries: entries, window: .session, now: now)
        XCTAssertEqual(spent, 2.0, accuracy: 0.0001)
    }
}
