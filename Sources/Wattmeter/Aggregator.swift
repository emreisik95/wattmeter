import Foundation

enum Aggregator {
    struct Summary {
        var cost: Double = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheWriteTokens: Int = 0
        var cacheReadTokens: Int = 0
        var entryCount: Int = 0
        var totalTokens: Int {
            inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens
        }
    }

    struct DayBucket: Identifiable {
        let date: Date
        let cost: Double
        let tokens: Int
        var id: Date { date }
    }

    struct ModelSlice: Identifiable {
        let model: String
        let cost: Double
        var id: String { model }
    }

    struct ProjectSlice: Identifiable {
        let project: String
        let cost: Double
        var id: String { project }
    }

    static func summary(_ entries: [UsageEntry]) -> Summary {
        var s = Summary()
        for e in entries {
            s.cost += e.cost
            s.inputTokens += e.inputTokens
            s.outputTokens += e.outputTokens
            s.cacheWriteTokens += e.cacheWrite5m + e.cacheWrite1h
            s.cacheReadTokens += e.cacheRead
            s.entryCount += 1
        }
        return s
    }

    static func filter(_ entries: [UsageEntry], range: DateInterval) -> [UsageEntry] {
        entries.filter { range.contains($0.timestamp) }
    }

    static func byDay(_ entries: [UsageEntry], calendar: Calendar = .current) -> [DayBucket] {
        var dict: [Date: (Double, Int)] = [:]
        for e in entries {
            let day = calendar.startOfDay(for: e.timestamp)
            var cur = dict[day] ?? (0, 0)
            cur.0 += e.cost
            cur.1 += e.inputTokens + e.outputTokens + e.cacheWrite5m + e.cacheWrite1h + e.cacheRead
            dict[day] = cur
        }
        return dict.map { DayBucket(date: $0.key, cost: $0.value.0, tokens: $0.value.1) }
            .sorted { $0.date < $1.date }
    }

    static func byModel(_ entries: [UsageEntry]) -> [ModelSlice] {
        var dict: [String: Double] = [:]
        for e in entries {
            dict[shortModel(e.model), default: 0] += e.cost
        }
        return dict.map { ModelSlice(model: $0.key, cost: $0.value) }
            .sorted { $0.cost > $1.cost }
    }

    static func byProject(_ entries: [UsageEntry], top: Int = 10) -> [ProjectSlice] {
        var dict: [String: Double] = [:]
        for e in entries {
            dict[e.project, default: 0] += e.cost
        }
        let sorted = dict.map { ProjectSlice(project: $0.key, cost: $0.value) }
            .sorted { $0.cost > $1.cost }
        return Array(sorted.prefix(top))
    }

    struct SessionSlice: Identifiable {
        let sessionId: String
        let project: String
        let cost: Double
        let tokens: Int
        let entryCount: Int
        let firstSeen: Date
        let lastSeen: Date
        var id: String { sessionId }
        var duration: TimeInterval { lastSeen.timeIntervalSince(firstSeen) }
    }

    static func bySession(_ entries: [UsageEntry], top: Int = Int.max) -> [SessionSlice] {
        var map: [String: (project: String, cost: Double, tokens: Int, n: Int, first: Date, last: Date)] = [:]
        for e in entries {
            let key = e.sessionId.isEmpty ? "unknown" : e.sessionId
            var cur = map[key] ?? (e.project, 0, 0, 0, e.timestamp, e.timestamp)
            cur.cost += e.cost
            cur.tokens += e.totalTokens
            cur.n += 1
            if e.timestamp < cur.first { cur.first = e.timestamp }
            if e.timestamp > cur.last  { cur.last = e.timestamp }
            map[key] = cur
        }
        let arr = map.map { (k, v) in
            SessionSlice(sessionId: k, project: v.project, cost: v.cost, tokens: v.tokens,
                         entryCount: v.n, firstSeen: v.first, lastSeen: v.last)
        }.sorted { $0.cost > $1.cost }
        return Array(arr.prefix(top))
    }

    static func topRequests(_ entries: [UsageEntry], top: Int = 10) -> [UsageEntry] {
        entries.sorted { $0.cost > $1.cost }.prefix(top).map { $0 }
    }

    /// Returns a 7d-by-24h grid of cost buckets. Index [day][hour].
    static func heatmap(_ entries: [UsageEntry], days: Int = 7, calendar: Calendar = .current) -> (grid: [[Double]], rowStart: Date) {
        let now = Date()
        let endOfDay = calendar.startOfDay(for: now).addingTimeInterval(86400)
        let startDay = calendar.date(byAdding: .day, value: -days + 1, to: calendar.startOfDay(for: now)) ?? now
        var grid = Array(repeating: Array(repeating: 0.0, count: 24), count: days)
        for e in entries where e.timestamp >= startDay && e.timestamp < endOfDay {
            let dayOffset = calendar.dateComponents([.day], from: startDay, to: calendar.startOfDay(for: e.timestamp)).day ?? 0
            let hour = calendar.component(.hour, from: e.timestamp)
            if dayOffset >= 0 && dayOffset < days && hour >= 0 && hour < 24 {
                grid[dayOffset][hour] += e.cost
            }
        }
        return (grid, startDay)
    }

    /// Cost per day for the last N days (oldest first).
    static func costSeries(_ entries: [UsageEntry], days: Int = 14, calendar: Calendar = .current) -> [(date: Date, cost: Double)] {
        let now = Date()
        let start = calendar.date(byAdding: .day, value: -days + 1, to: calendar.startOfDay(for: now)) ?? now
        var out: [(Date, Double)] = []
        for i in 0..<days {
            let d = calendar.date(byAdding: .day, value: i, to: start) ?? now
            out.append((d, 0))
        }
        for e in entries where e.timestamp >= start {
            let day = calendar.startOfDay(for: e.timestamp)
            let idx = calendar.dateComponents([.day], from: start, to: day).day ?? -1
            if idx >= 0 && idx < days {
                out[idx].1 += e.cost
            }
        }
        return out
    }

    static func shortModel(_ m: String) -> String {
        let l = m.lowercased()
        let family: String
        if l.contains("opus") { family = "opus" }
        else if l.contains("haiku") { family = "haiku" }
        else if l.contains("sonnet") { family = "sonnet" }
        else { return m }
        let stripped = l.replacingOccurrences(of: "claude-", with: "")
        let parts = stripped.split(separator: "-")
        if parts.count >= 3, Int(parts[1]) != nil, Int(parts[2]) != nil {
            return "\(family)-\(parts[1]).\(parts[2])"
        }
        return family
    }
}
