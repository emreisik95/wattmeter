import Foundation

/// UsageProvider implementation backed by the existing JSONL Parser.
/// Reads from `ProfileManager.shared.activeClaudeDir` so profiles work transparently.
struct ClaudeProvider: UsageProvider {
    let id: String = ProviderID.claude
    let displayName: String = "Claude Code"
    var isEnabled: Bool = true

    /// Optional override; if nil, reads from `ProfileManager.shared.activeClaudeDir` at fetch time.
    var claudeDirOverride: URL?

    init(claudeDirOverride: URL? = nil, isEnabled: Bool = true) {
        self.claudeDirOverride = claudeDirOverride
        self.isEnabled = isEnabled
    }

    func fetch() async -> [UsageEntry] {
        let dir: URL
        if let override = claudeDirOverride {
            dir = override
        } else {
            dir = await MainActor.run { ProfileManager.shared.activeClaudeDir }
        }
        return await Task.detached(priority: .utility) { () -> [UsageEntry] in
            Parser.loadAllEntries(claudeDir: dir)
        }.value
    }

    /// Streaming fetch: invokes `onBatch` per file as soon as that file is parsed.
    /// Used by UsageStore to preserve the live UI update cadence.
    func fetchStreaming(onBatch: ([UsageEntry]) -> Void) {
        let dir: URL
        if let override = claudeDirOverride {
            dir = override
        } else {
            // Synchronous read of the singleton; ProfileManager is @MainActor so we hop.
            // UsageStore drives streaming from a detached task; this path uses the override
            // resolved by the caller. As a safety net we fall back to the default.
            dir = Parser.defaultClaudeDir
        }
        Parser.loadAllEntriesStreaming(claudeDir: dir, onBatch: onBatch)
    }
}
