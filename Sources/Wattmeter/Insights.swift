import Foundation

/// "Today's Standup": pure functions over [UsageEntry].
/// Deterministic — no I/O, no clock side effects beyond an injectable `now`.
enum Insights {

    struct Standup: Equatable {
        var todayCost: Double
        var yesterdayCost: Double
        /// Hour-of-day (0..23) with peak cost across the lookback window.
        var peakHour: Int?
        var peakHourCost: Double
        var topModel: String?
        var topModelCost: Double
        var topProject: String?
        var topProjectCost: Double
        var requestCountToday: Int

        /// Percent delta vs yesterday. `nil` when yesterday was zero (avoid /0).
        var deltaPercent: Double? {
            guard yesterdayCost > 0 else { return nil }
            return ((todayCost - yesterdayCost) / yesterdayCost) * 100.0
        }
    }

    /// Compute the standup snapshot.
    /// - Parameters:
    ///   - entries: usage entries (any order)
    ///   - now: reference instant (defaults to `Date()`)
    ///   - calendar: calendar for day boundaries
    static func standup(
        _ entries: [UsageEntry],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Standup {
        let todayStart = calendar.startOfDay(for: now)
        let yStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let yEnd = todayStart

        var todayCost = 0.0
        var yesterdayCost = 0.0
        var todayCount = 0

        // Peak hour: aggregate over the last 7 days (so a single light morning doesn't dominate).
        let peakWindowStart = calendar.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart
        var hourBuckets = Array(repeating: 0.0, count: 24)

        var byModel: [String: Double] = [:]
        var byProject: [String: Double] = [:]

        for e in entries {
            // Today
            if e.timestamp >= todayStart && e.timestamp <= now {
                todayCost += e.cost
                todayCount += 1
                byModel[Aggregator.shortModel(e.model), default: 0] += e.cost
                if !e.project.isEmpty {
                    byProject[e.project, default: 0] += e.cost
                }
            }
            // Yesterday (full day)
            if e.timestamp >= yStart && e.timestamp < yEnd {
                yesterdayCost += e.cost
            }
            // Peak hour window
            if e.timestamp >= peakWindowStart && e.timestamp <= now {
                let h = calendar.component(.hour, from: e.timestamp)
                if h >= 0 && h < 24 {
                    hourBuckets[h] += e.cost
                }
            }
        }

        // Deterministic peak: argmax with lowest-hour tiebreak.
        var peakHour: Int? = nil
        var peakCost = 0.0
        for h in 0..<24 {
            if hourBuckets[h] > peakCost {
                peakCost = hourBuckets[h]
                peakHour = h
            }
        }

        // Top model: highest cost today; deterministic alphabetical tiebreak.
        let topModelPair: (String, Double)? = byModel
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .first
            .map { ($0.key, $0.value) }

        let topProjectPair: (String, Double)? = byProject
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .first
            .map { ($0.key, $0.value) }

        return Standup(
            todayCost: todayCost,
            yesterdayCost: yesterdayCost,
            peakHour: peakHour,
            peakHourCost: peakCost,
            topModel: topModelPair?.0,
            topModelCost: topModelPair?.1 ?? 0,
            topProject: topProjectPair?.0,
            topProjectCost: topProjectPair?.1 ?? 0,
            requestCountToday: todayCount
        )
    }

    /// Human-readable hour label, e.g. 14 → "14:00".
    static func formatHour(_ h: Int) -> String {
        String(format: "%02d:00", h)
    }
}
