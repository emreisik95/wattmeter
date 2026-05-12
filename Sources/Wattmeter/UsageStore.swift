import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published var entries: [UsageEntry] = []
    @Published var lastRefresh: Date? = nil
    @Published var isLoading = false

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Wattmeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("snapshot.v2.plist")
    }

    init() {
        loadCachedSnapshot()
    }

    /// Load last persisted snapshot synchronously so UI has data before parse finishes.
    private func loadCachedSnapshot() {
        let url = Self.cacheURL
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = PropertyListDecoder()
        struct Snapshot: Codable {
            let savedAt: Date
            let entries: [UsageEntry]
        }
        guard let snap = try? decoder.decode(Snapshot.self, from: data) else { return }
        self.entries = snap.entries
        self.lastRefresh = snap.savedAt
    }

    private func persistSnapshot() {
        let url = Self.cacheURL
        struct Snapshot: Codable {
            let savedAt: Date
            let entries: [UsageEntry]
        }
        let snap = Snapshot(savedAt: lastRefresh ?? Date(), entries: entries)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(snap) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Streaming refresh. Emit partials per file. UI sees data grow live.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let preExisting = entries
        let preExistingIds = Set(preExisting.map(\.id))
        var newEntries: [UsageEntry] = []
        var seenNew = Set<String>()
        var pendingUIUpdate = false
        var lastUIPush = Date()

        let stream = AsyncStream<[UsageEntry]> { continuation in
            Task.detached(priority: .utility) {
                Parser.loadAllEntriesStreaming { batch in
                    continuation.yield(batch)
                }
                continuation.finish()
            }
        }

        for await batch in stream {
            var added = false
            for e in batch where !preExistingIds.contains(e.id) && seenNew.insert(e.id).inserted {
                newEntries.append(e)
                added = true
            }
            // Throttle UI push to ~120ms cadence to avoid SwiftUI thrash.
            let now = Date()
            if added && now.timeIntervalSince(lastUIPush) > 0.12 {
                lastUIPush = now
                pendingUIUpdate = false
                var merged = preExisting + newEntries
                merged.sort { $0.timestamp < $1.timestamp }
                self.entries = merged
            } else if added {
                pendingUIUpdate = true
            }
        }

        // Final authoritative replace.
        var finalList = preExisting + newEntries
        finalList.sort { $0.timestamp < $1.timestamp }
        if pendingUIUpdate || finalList.count != entries.count {
            entries = finalList
        }

        lastRefresh = Date()
        Task.detached(priority: .background) { [weak self] in
            await self?.persistSnapshot()
        }
    }
}
