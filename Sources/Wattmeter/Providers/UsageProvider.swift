import Foundation

// The `UsageProvider` protocol itself lives in FrozenAPI.swift.
// This file holds shared utilities for concrete providers.

/// Well-known provider identifiers used in `UsageEntry.provider`.
enum ProviderID {
    static let claude = "claude"
    static let codex = "codex"
    static let cursor = "cursor"
}

/// Merges entries from multiple providers, deduping by `UsageEntry.id`.
/// Sorts ascending by timestamp.
enum ProviderMerge {
    static func merge(_ groups: [[UsageEntry]]) -> [UsageEntry] {
        var seen = Set<String>()
        var out: [UsageEntry] = []
        // Reserve a sensible capacity to limit reallocations.
        out.reserveCapacity(groups.reduce(0) { $0 + $1.count })
        for group in groups {
            for entry in group where seen.insert(entry.id).inserted {
                out.append(entry)
            }
        }
        out.sort { $0.timestamp < $1.timestamp }
        return out
    }
}
