import XCTest
@testable import Wattmeter

final class AnomalyDetectorTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func entry(daysAgo: Int, cost: Double, now: Date) -> UsageEntry {
        let d = cal.date(byAdding: .day, value: -daysAgo, to: now)!
        return UsageEntry(
            id: UUID().uuidString,
            timestamp: d,
            model: "claude-sonnet-4-5",
            project: "p",
            sessionId: "s",
            inputTokens: 0, outputTokens: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0,
            cost: cost,
            provider: nil
        )
    }

    /// Build a baseline with a stable mean (~$5/day for 30 days, low variance) and verify a $20
    /// spike today is detected. threshold should be max(mean + 3σ, 2·mean). With σ ≈ 0,
    /// threshold ≈ 2·mean = $10, today=$20 ⇒ anomaly.
    func testDetectsClearSpike() {
        let now = cal.date(from: DateComponents(year: 2026, month: 5, day: 12, hour: 12))!
        var entries: [UsageEntry] = []
        for d in 1...30 {
            entries.append(entry(daysAgo: d, cost: 5.0, now: now))
        }
        entries.append(entry(daysAgo: 0, cost: 20.0, now: now))
        let decision = AnomalyDetector.analyze(entries: entries, days: 30, now: now, calendar: cal)
        XCTAssertTrue(decision.isAnomaly, "expected anomaly: \(decision.reason)")
        XCTAssertEqual(decision.todayCost, 20.0, accuracy: 0.001)
        XCTAssertEqual(decision.baseline.mean, 5.0, accuracy: 0.001)
        XCTAssertEqual(decision.baseline.stddev, 0.0, accuracy: 0.001)
        XCTAssertEqual(decision.threshold, 10.0, accuracy: 0.001)
    }

    /// Today's cost within normal range — no anomaly emitted.
    func testNoAnomalyWhenNormal() {
        let now = cal.date(from: DateComponents(year: 2026, month: 5, day: 12, hour: 12))!
        var entries: [UsageEntry] = []
        for d in 1...30 {
            entries.append(entry(daysAgo: d, cost: 5.0, now: now))
        }
        entries.append(entry(daysAgo: 0, cost: 7.0, now: now))
        let decision = AnomalyDetector.analyze(entries: entries, days: 30, now: now, calendar: cal)
        XCTAssertFalse(decision.isAnomaly, "did not expect anomaly: \(decision.reason)")
    }

    /// When stddev is large, threshold = mean + 3σ governs (chooses the larger of the two rules).
    func testThresholdUsesMaxOfMeanPlus3StdAnd2xMean() {
        // Build noisy history: alternating $1 and $9 ⇒ mean ≈ $5, σ ≈ $4. threshold = max(5+12, 10) = 17.
        let now = cal.date(from: DateComponents(year: 2026, month: 5, day: 12, hour: 12))!
        var entries: [UsageEntry] = []
        for d in 1...30 {
            entries.append(entry(daysAgo: d, cost: d % 2 == 0 ? 1.0 : 9.0, now: now))
        }
        // Spike at $15 — over 2×mean but UNDER mean+3σ ⇒ NOT anomalous.
        entries.append(entry(daysAgo: 0, cost: 15.0, now: now))
        let decision = AnomalyDetector.analyze(entries: entries, days: 30, now: now, calendar: cal)
        XCTAssertFalse(decision.isAnomaly, "expected $15 not to trip threshold ≈ $17: \(decision.reason)")
        // Spike at $25 — over both ⇒ anomalous.
        var entries2 = entries.dropLast() + [entry(daysAgo: 0, cost: 25.0, now: now)]
        let _ = entries2.count
        let decision2 = AnomalyDetector.analyze(entries: Array(entries2), days: 30, now: now, calendar: cal)
        XCTAssertTrue(decision2.isAnomaly, "expected $25 to trip threshold: \(decision2.reason)")
    }

    /// Insufficient baseline ⇒ no anomaly even if today's cost is large (avoid false-positive on day 1).
    func testNoAnomalyWhenBaselineEmpty() {
        let now = cal.date(from: DateComponents(year: 2026, month: 5, day: 12, hour: 12))!
        let entries = [entry(daysAgo: 0, cost: 100.0, now: now)]
        let decision = AnomalyDetector.analyze(entries: entries, days: 30, now: now, calendar: cal)
        XCTAssertFalse(decision.isAnomaly, "should not emit anomaly with empty baseline: \(decision.reason)")
    }

    /// Verify evaluator integration: detector pushes BudgetEvent(kind: .anomaly) on spike.
    @MainActor
    func testPushesIntoBudgetEvaluator() async {
        let now = cal.date(from: DateComponents(year: 2026, month: 5, day: 12, hour: 12))!
        var entries: [UsageEntry] = []
        for d in 1...30 { entries.append(entry(daysAgo: d, cost: 5.0, now: now)) }
        entries.append(entry(daysAgo: 0, cost: 50.0, now: now))
        let eval = BudgetEvaluator()
        let decision = AnomalyDetector.evaluate(entries: entries, days: 30, into: eval, now: now)
        XCTAssertTrue(decision.isAnomaly)
        XCTAssertEqual(eval.lastEvents.count, 1)
        XCTAssertEqual(eval.lastEvents.first?.kind, .anomaly)
        XCTAssertNotNil(eval.lastEvents.first?.note)
    }

    @MainActor
    func testNoPushWhenNotAnomalous() async {
        let now = cal.date(from: DateComponents(year: 2026, month: 5, day: 12, hour: 12))!
        var entries: [UsageEntry] = []
        for d in 1...30 { entries.append(entry(daysAgo: d, cost: 5.0, now: now)) }
        entries.append(entry(daysAgo: 0, cost: 6.0, now: now))
        let eval = BudgetEvaluator()
        _ = AnomalyDetector.evaluate(entries: entries, days: 30, into: eval, now: now)
        XCTAssertEqual(eval.lastEvents.count, 0)
    }
}
