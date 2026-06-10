import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published var entries: [UsageEntry] = []
    @Published var lastRefresh: Date? = nil
    @Published var isLoading = false

    /// Concrete providers used for fan-out. The Claude provider is special-cased to
    /// preserve the existing streaming-per-file UI throttle. Other providers are
    /// fetched concurrently and merged once their `fetch()` returns.
    private let claudeProvider = ClaudeProvider()
    private let secondaryProviders: [UsageProvider] = [
        CodexProvider(),
        CursorProvider()
    ]

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
        self.entries = Pricing.repriced(snap.entries)
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

    /// Streaming refresh with multi-provider fan-out.
    ///
    /// - Claude (primary): streams batches per file with a ~120ms UI throttle.
    /// - Other enabled providers (Codex, …): fetched concurrently in a TaskGroup;
    ///   their results merge into `entries` once available.
    /// Final state is sorted by timestamp ascending; ids are deduped across providers.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let preExisting = entries
        // Drop any pre-existing entries that come from a streaming/non-Claude
        // provider — they will be reprovided fresh by this refresh — but keep
        // Claude entries as a baseline so the streaming merge stays incremental.
        let preExistingClaude = preExisting.filter { $0.providerOrClaude == ProviderID.claude }
        let preExistingClaudeIds = Set(preExistingClaude.map(\.id))
        var newClaudeEntries: [UsageEntry] = []
        var seenNew = Set<String>()
        var pendingUIUpdate = false
        var lastUIPush = Date()

        // Resolve the active Claude directory on the main actor.
        let claudeDir = ProfileManager.shared.activeClaudeDir

        // Kick off secondary providers concurrently.
        let secondaryTask: Task<[UsageEntry], Never> = Task.detached(priority: .utility) { [secondaryProviders] in
            await withTaskGroup(of: [UsageEntry].self) { group in
                for provider in secondaryProviders where provider.isEnabled {
                    group.addTask { await provider.fetch() }
                }
                var collected: [UsageEntry] = []
                for await batch in group {
                    collected.append(contentsOf: batch)
                }
                return collected
            }
        }

        // Stream the Claude provider's per-file batches.
        let stream = AsyncStream<[UsageEntry]> { continuation in
            Task.detached(priority: .utility) {
                Parser.loadAllEntriesStreaming(claudeDir: claudeDir) { batch in
                    continuation.yield(batch)
                }
                continuation.finish()
            }
        }

        for await batch in stream {
            var added = false
            for e in batch where !preExistingClaudeIds.contains(e.id) && seenNew.insert(e.id).inserted {
                newClaudeEntries.append(e)
                added = true
            }
            let now = Date()
            if added && now.timeIntervalSince(lastUIPush) > 0.12 {
                lastUIPush = now
                pendingUIUpdate = false
                var merged = preExistingClaude + newClaudeEntries
                merged.sort { $0.timestamp < $1.timestamp }
                self.entries = merged
            } else if added {
                pendingUIUpdate = true
            }
        }

        // Wait for secondary providers and produce the final merged list.
        let secondaryEntries = await secondaryTask.value
        let claudeAll = preExistingClaude + newClaudeEntries
        // Reprice on every refresh: pre-existing entries carry parse-time
        // costs that go stale when the pricing table gains or changes models.
        let finalList = Pricing.repriced(ProviderMerge.merge([claudeAll, secondaryEntries]))

        entries = finalList

        lastRefresh = Date()
        let entriesForWidget = entries
        Task.detached(priority: .background) { [weak self] in
            await self?.persistSnapshot()
            _ = try? WidgetSnapshotWriter.write(from: entriesForWidget)
        }
    }
}
