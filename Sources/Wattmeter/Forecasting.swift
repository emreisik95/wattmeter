import Foundation

enum Plan: String, CaseIterable, Identifiable {
    case pro
    case max5x
    case max20x
    case custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pro:    return "Pro"
        case .max5x:  return "Max 5×"
        case .max20x: return "Max 20×"
        case .custom: return "Custom"
        }
    }
    /// Rough USD ceiling per 5h window (informational only).
    var fiveHourCeiling: Double {
        switch self {
        case .pro:    return 8
        case .max5x:  return 35
        case .max20x: return 140
        case .custom: return 0
        }
    }
    var weeklyCeiling: Double {
        switch self {
        case .pro:    return 80
        case .max5x:  return 350
        case .max20x: return 1400
        case .custom: return 0
        }
    }
}

struct BurnRateForecast {
    let costPerHour: Double
    let projectedFraction: Double   // at end of window
    let hitFullAt: Date?            // when percentage would reach 100, if rate continues

    var willExceed: Bool { projectedFraction >= 1.0 }
}

enum Forecasting {
    /// Cost burn rate over the trailing N seconds.
    static func burnRate(entries: [UsageEntry], lookbackSeconds: TimeInterval = 1800) -> Double {
        let now = Date()
        let start = now.addingTimeInterval(-lookbackSeconds)
        var sum = 0.0
        for e in entries where e.timestamp >= start {
            sum += e.cost
        }
        return sum / max(60, lookbackSeconds / 3600.0 * 3600.0) // cost per second
    }

    /// Forecast for a limit window given current percent + window length.
    /// Uses observed cost-burn-rate over last 30 min and current percentage.
    static func forecast(currentPct: Double, resetsAt: Date?, burnPerSec: Double, ceiling: Double) -> BurnRateForecast {
        let now = Date()
        guard let resetsAt, resetsAt > now else {
            return BurnRateForecast(costPerHour: burnPerSec * 3600, projectedFraction: currentPct / 100, hitFullAt: nil)
        }
        let secsRemaining = resetsAt.timeIntervalSince(now)
        let costPerHour = burnPerSec * 3600
        // Project additional fraction using ceiling if known, else linear by time
        var projected = currentPct / 100
        if ceiling > 0 {
            let addCost = burnPerSec * secsRemaining
            projected += addCost / ceiling
        } else {
            // No ceiling info — estimate using percent-per-hour from very recent change is hard;
            // fall back to assume linear growth proportional to remaining time
            let remainingFraction = 1.0 - projected
            projected += remainingFraction * 0.25 // conservative bump
        }
        let projectedClamped = min(2.0, max(0, projected))

        var hitFull: Date? = nil
        if ceiling > 0, burnPerSec > 0 {
            let costToFull = ceiling * (1.0 - currentPct / 100)
            if costToFull > 0 {
                let secsToFull = costToFull / burnPerSec
                if secsToFull < secsRemaining * 3 {
                    hitFull = now.addingTimeInterval(secsToFull)
                }
            }
        }

        return BurnRateForecast(
            costPerHour: costPerHour,
            projectedFraction: projectedClamped,
            hitFullAt: hitFull
        )
    }

    static func costToday(_ entries: [UsageEntry], calendar: Calendar = .current) -> Double {
        let start = calendar.startOfDay(for: Date())
        return entries.reduce(0.0) { $0 + ($1.timestamp >= start ? $1.cost : 0) }
    }

    static func costThisWeek(_ entries: [UsageEntry], calendar: Calendar = .current) -> Double {
        var cal = calendar
        cal.firstWeekday = 2
        let now = Date()
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let start = cal.date(from: comps) ?? now
        return entries.reduce(0.0) { $0 + ($1.timestamp >= start ? $1.cost : 0) }
    }

    static func costInLastHours(_ entries: [UsageEntry], hours: Int) -> Double {
        let start = Date().addingTimeInterval(-Double(hours) * 3600)
        return entries.reduce(0.0) { $0 + ($1.timestamp >= start ? $1.cost : 0) }
    }
}
