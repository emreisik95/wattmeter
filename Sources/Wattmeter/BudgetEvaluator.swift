import Foundation

/// Sidecar state for `BudgetEvaluator` threshold tracking.
///
/// FrozenAPI declares `BudgetEvaluator` as a `final class`, so we can't add
/// stored properties via extension. The dedup state (per-budget last-fired
/// threshold, per-window epoch) is parked here and looked up by budget id.
@MainActor
final class BudgetEvaluatorState {
    static let shared = BudgetEvaluatorState()

    /// Maps budget id → (windowKey, highestKindFired).
    /// `windowKey` is the start of the active window (daily=startOfDay,
    /// weekly=startOfWeek, session= "session"+a launch-scoped UUID). When the
    /// window key changes, the threshold tracker resets to allow fresh fires.
    private var fired: [UUID: (windowKey: String, highest: Int)] = [:]

    private let launchKey: String = UUID().uuidString

    private init() {}

    /// Returns the kinds that should be fired now given a new percentage and
    /// the budget's window. Idempotent: a threshold already crossed inside the
    /// same window will not re-fire.
    func kindsToFire(budget: Budget, percent: Double, now: Date = Date(), calendar: Calendar = .current) -> [BudgetEvent.Kind] {
        let windowKey = windowKey(for: budget.window, now: now, calendar: calendar)
        let pct = percent * 100.0

        // Reset tracker if window rolled.
        if let prev = fired[budget.id], prev.windowKey != windowKey {
            fired[budget.id] = (windowKey, 0)
        }
        let prevHighest = fired[budget.id]?.highest ?? 0

        // Order: 50, 75, 90, exceeded(100).
        let ladder: [(threshold: Double, level: Int, kind: BudgetEvent.Kind)] = [
            (50,  50,  .crossed50),
            (75,  75,  .crossed75),
            (90,  90,  .crossed90),
            (100, 100, .exceeded)
        ]

        var out: [BudgetEvent.Kind] = []
        var highest = prevHighest
        for step in ladder where pct >= step.threshold && prevHighest < step.level {
            out.append(step.kind)
            highest = step.level
        }
        if highest != prevHighest {
            fired[budget.id] = (windowKey, highest)
        }
        return out
    }

    func reset(budgetId: UUID) {
        fired.removeValue(forKey: budgetId)
    }

    func resetAll() { fired.removeAll() }

    func windowKey(for window: BudgetWindow, now: Date, calendar: Calendar) -> String {
        switch window {
        case .daily:
            let d = calendar.startOfDay(for: now)
            return "d:\(Int(d.timeIntervalSince1970))"
        case .weekly:
            var cal = calendar
            cal.firstWeekday = 2 // Monday
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            if let start = cal.date(from: comps) {
                return "w:\(Int(start.timeIntervalSince1970))"
            }
            return "w:\(Int(now.timeIntervalSince1970))"
        case .session:
            return "s:\(launchKey)"
        }
    }
}

extension BudgetEvaluator {
    /// Path for the hard-cap breach sentinel consumed by the (out-of-scope-B)
    /// SessionStart hook. Atomic-written when a hard-cap budget hits .exceeded.
    static var hardCapSentinelURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/wattmeter_budget.json")
    }

    /// Computes the spend that should count against a budget's window.
    static func spend(entries: [UsageEntry], window: BudgetWindow, now: Date = Date(), calendar: Calendar = .current) -> Double {
        let range: DateInterval
        switch window {
        case .daily:
            let start = calendar.startOfDay(for: now)
            range = DateInterval(start: start, duration: 86_400)
        case .weekly:
            var cal = calendar
            cal.firstWeekday = 2
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            let start = cal.date(from: comps) ?? now
            range = DateInterval(start: start, duration: 7 * 86_400)
        case .session:
            // Session window: spend over the trailing 5 hours (matches Claude's
            // 5h rate-limit window). The lead session may refine this.
            range = DateInterval(start: now.addingTimeInterval(-5 * 3600), end: now)
        }
        return entries
            .filter { range.contains($0.timestamp) }
            .reduce(0) { $0 + $1.cost }
    }

    /// Pure evaluation step: given entries + budgets, returns the events that
    /// should fire now. Used by tests and by `evaluateAndDispatch`.
    func computeEvents(entries: [UsageEntry], budgets: [Budget], now: Date = Date(), calendar: Calendar = .current) -> [BudgetEvent] {
        var out: [BudgetEvent] = []
        for b in budgets {
            let spent = Self.spend(entries: entries, window: b.window, now: now, calendar: calendar)
            let pct = b.amountUSD > 0 ? spent / b.amountUSD : 0
            let kinds = BudgetEvaluatorState.shared.kindsToFire(budget: b, percent: pct, now: now, calendar: calendar)
            for k in kinds {
                out.append(BudgetEvent(budgetId: b.id, percent: pct, kind: k, timestamp: now,
                                       note: "\(b.label) (\(b.window.rawValue))"))
            }
        }
        return out
    }

    /// Full pipeline: evaluate, push events, write the hard-cap sentinel on
    /// .exceeded, and fire the configured webhook (when present).
    func evaluateAndDispatch(entries: [UsageEntry],
                             budgets: [Budget],
                             webhookSender: WebhookSender = WebhookSender(),
                             now: Date = Date(),
                             calendar: Calendar = .current) async {
        let events = computeEvents(entries: entries, budgets: budgets, now: now, calendar: calendar)
        let byId: [UUID: Budget] = Dictionary(uniqueKeysWithValues: budgets.map { ($0.id, $0) })

        for ev in events {
            push(ev)
            guard ev.kind == .exceeded, let bid = ev.budgetId, let b = byId[bid] else { continue }

            if b.hardCap {
                Self.writeHardCapSentinel(budget: b)
            }

            if let ref = b.webhookKeychainRef {
                let payload = WebhookSender.budgetExceededPayload(budget: b, percent: ev.percent)
                do {
                    _ = try await webhookSender.send(payload, keychainRef: ref)
                } catch {
                    // Errors are logged inside WebhookSender (with URL redaction).
                }
            }
        }
    }

    /// Atomic-write `{breached:true, budget:"<id>"}` to the sentinel path.
    /// SessionStart hook install is out of scope for Teammate B.
    /// TODO(lead): wire a SessionStart hook that reads this file and exits
    /// non-zero when `breached == true`.
    static func writeHardCapSentinel(budget: Budget) {
        struct Sentinel: Codable {
            let breached: Bool
            let budget: String
            let label: String
            let amountUSD: Double
            let window: String
            let breachedAt: Date
        }
        let s = Sentinel(
            breached: true,
            budget: budget.id.uuidString,
            label: budget.label,
            amountUSD: budget.amountUSD,
            window: budget.window.rawValue,
            breachedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(s) else { return }

        let url = hardCapSentinelURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Atomic temp+rename
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// Clears the hard-cap sentinel (e.g. when user dismisses a breach).
    static func clearHardCapSentinel() {
        try? FileManager.default.removeItem(at: hardCapSentinelURL)
    }
}
