import Foundation

/// Atomic writer for the widget snapshot JSON.
///
/// v0.2.0 ships only the writer; the actual WidgetKit `.appex` arrives in
/// v0.2.1 and will dual-read from an App Group container AND this path for
/// compatibility. Path:
///   ~/Library/Application Support/Wattmeter/widget_snapshot.json
///
/// LEAD INTEGRATION: invoke `WidgetSnapshotWriter.shared.write(from:)` at the
/// tail of `UsageStore.refresh()` (A1's file). This module deliberately does
/// not import UsageStore.
enum WidgetSnapshotWriter {

    struct ModelBreakdown: Codable, Hashable {
        let model: String
        let tokens: Int
        let costUSD: Double
    }

    struct Snapshot: Codable, Hashable {
        let schemaVersion: Int
        let updatedAt: Date
        let todayCostUSD: Double
        let todayTokens: Int
        let modelBreakdown: [ModelBreakdown]
    }

    /// Default file URL. Creates the containing directory on first access.
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Wattmeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("widget_snapshot.json")
    }

    /// Compute a snapshot from the full `UsageEntry` list and write it to disk
    /// atomically. Caller decides timezone scope of "today"; default is the
    /// current calendar's start-of-day in the user's local zone.
    /// - Parameters:
    ///   - entries: full usage entries
    ///   - now: clock injection point (for tests)
    ///   - calendar: calendar used to bound "today"; defaults to current
    /// - Returns: the snapshot that was written (also useful for tests).
    @discardableResult
    static func write(from entries: [UsageEntry],
                      now: Date = Date(),
                      calendar: Calendar = .current,
                      to url: URL? = nil) throws -> Snapshot {
        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            throw NSError(domain: "WidgetSnapshotWriter", code: 1, userInfo: nil)
        }
        var todayCost: Double = 0
        var todayTokens: Int = 0
        var perModelCost: [String: Double] = [:]
        var perModelTokens: [String: Int] = [:]
        for e in entries where e.timestamp >= dayStart && e.timestamp < dayEnd {
            todayCost += e.cost
            todayTokens += e.totalTokens
            perModelCost[e.model, default: 0] += e.cost
            perModelTokens[e.model, default: 0] += e.totalTokens
        }
        let breakdown = perModelCost.keys.sorted().map { model in
            ModelBreakdown(model: model,
                           tokens: perModelTokens[model] ?? 0,
                           costUSD: perModelCost[model] ?? 0)
        }
        let snap = Snapshot(
            schemaVersion: 1,
            updatedAt: now,
            todayCostUSD: todayCost,
            todayTokens: todayTokens,
            modelBreakdown: breakdown
        )
        let target = url ?? defaultURL
        try writeAtomic(snap, to: target)
        return snap
    }

    private static func writeAtomic(_ snap: Snapshot, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(snap)
        try data.write(to: url, options: [.atomic])
    }
}
