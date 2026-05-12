import Foundation

/// F12 — Anomaly detector. Compares today's cost against a rolling baseline (default 30d)
/// and emits a `BudgetEvent(kind: .anomaly)` into a `BudgetEvaluator` event stream when
/// today exceeds `mean + 3σ` OR `2× mean` (whichever is larger).
///
/// Detector emits via `BudgetEvaluator.push(_:)`; F1 + F12 share a single notification
/// pipeline so users never get duplicate alerts.
enum AnomalyDetector {

    struct Baseline: Equatable {
        let mean: Double
        let stddev: Double
        let sampleDays: Int
    }

    struct Decision: Equatable {
        let isAnomaly: Bool
        let todayCost: Double
        let baseline: Baseline
        let threshold: Double
        let reason: String
    }

    /// Compute the threshold used by `analyze`. Exposed for tests.
    /// threshold = max(mean + 3·σ, 2·mean)
    static func threshold(_ b: Baseline) -> Double {
        max(b.mean + 3 * b.stddev, 2 * b.mean)
    }

    /// Compute rolling baseline (mean, stddev) over the trailing `days` days BEFORE today.
    /// Today is excluded from the baseline so a spike doesn't contaminate its own threshold.
    static func baseline(entries: [UsageEntry], days: Int = 30, now: Date = Date(), calendar: Calendar = .current) -> Baseline {
        let startOfToday = calendar.startOfDay(for: now)
        guard let baselineStart = calendar.date(byAdding: .day, value: -days, to: startOfToday) else {
            return Baseline(mean: 0, stddev: 0, sampleDays: 0)
        }
        // Bucket by day.
        var byDay: [Date: Double] = [:]
        // Pre-populate every day with 0 so quiet days are part of the mean.
        for i in 0..<days {
            if let d = calendar.date(byAdding: .day, value: i, to: baselineStart) {
                byDay[d] = 0
            }
        }
        for e in entries {
            guard e.timestamp >= baselineStart && e.timestamp < startOfToday else { continue }
            let day = calendar.startOfDay(for: e.timestamp)
            byDay[day, default: 0] += e.cost
        }
        let costs = Array(byDay.values)
        guard !costs.isEmpty else { return Baseline(mean: 0, stddev: 0, sampleDays: 0) }
        let n = Double(costs.count)
        let mean = costs.reduce(0, +) / n
        let variance = costs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let stddev = variance.squareRoot()
        return Baseline(mean: mean, stddev: stddev, sampleDays: costs.count)
    }

    /// Sum of `entries` cost falling on `now`'s calendar day.
    static func todayCost(entries: [UsageEntry], now: Date = Date(), calendar: Calendar = .current) -> Double {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        var sum = 0.0
        for e in entries where e.timestamp >= start && e.timestamp < end {
            sum += e.cost
        }
        return sum
    }

    /// Pure analysis: returns the decision without emitting any event.
    static func analyze(entries: [UsageEntry], days: Int = 30, now: Date = Date(), calendar: Calendar = .current) -> Decision {
        let b = baseline(entries: entries, days: days, now: now, calendar: calendar)
        let today = todayCost(entries: entries, now: now, calendar: calendar)
        let t = threshold(b)
        // Require non-trivial baseline; if mean is essentially zero we can't detect anomalies.
        let baselineMeaningful = b.mean >= 0.01 && b.sampleDays >= 3
        let isAnomaly = baselineMeaningful && today > t
        let reason: String
        if !baselineMeaningful {
            reason = "baseline too small (mean=\(formatUSD(b.mean)), days=\(b.sampleDays))"
        } else if isAnomaly {
            let ratio = b.mean > 0 ? today / b.mean : 0
            reason = String(format: "today %@ exceeds threshold %@ (%.1f× the %d-day average %@)",
                            formatUSD(today), formatUSD(t), ratio, b.sampleDays, formatUSD(b.mean))
        } else {
            reason = "today \(formatUSD(today)) within normal range (avg \(formatUSD(b.mean)))"
        }
        return Decision(isAnomaly: isAnomaly, todayCost: today, baseline: b, threshold: t, reason: reason)
    }

    /// Analyze and, if anomalous, push a `BudgetEvent(kind: .anomaly)` into the evaluator.
    /// Returns the decision so callers can also log/display it.
    @MainActor
    @discardableResult
    static func evaluate(entries: [UsageEntry], days: Int = 30, into evaluator: BudgetEvaluator, now: Date = Date()) -> Decision {
        let decision = analyze(entries: entries, days: days, now: now)
        if decision.isAnomaly {
            let pct = decision.baseline.mean > 0
                ? (decision.todayCost / decision.baseline.mean) * 100
                : 0
            evaluator.push(BudgetEvent(
                budgetId: nil,
                percent: pct,
                kind: .anomaly,
                timestamp: now,
                note: decision.reason
            ))
        }
        return decision
    }

    private static func formatUSD(_ v: Double) -> String {
        String(format: "$%.2f", v)
    }
}
