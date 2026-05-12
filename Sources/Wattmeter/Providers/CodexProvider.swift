import Foundation

/// Parses Codex CLI session JSONL files in `~/.codex/sessions/`.
///
/// Codex writes one event per line. The relevant events are:
///   - `turn_context` → payload.model carries the model id for the *next* turn(s).
///   - `event_msg` with payload.type == "token_count" → payload.info.last_token_usage
///     contains input/cached/output/total token counts.
///
/// Strategy per file:
///   1. Walk lines in order, tracking the last seen model from `turn_context`.
///   2. On each `token_count` event whose `last_token_usage` is non-null,
///      synthesize a `UsageEntry` priced via `Pricing.cost(usage:model:)`.
///   3. Entry id derives from session uuid + line index to dedupe across reparses.
///
/// Unknown model ids → `Pricing.cost` returns 0 (the existing fallback).
struct CodexProvider: UsageProvider {
    let id: String = ProviderID.codex
    let displayName: String = "Codex"
    var isEnabled: Bool = true

    /// Optional override for the sessions directory; defaults to `~/.codex/sessions`.
    var sessionsDirOverride: URL?

    init(sessionsDirOverride: URL? = nil, isEnabled: Bool = true) {
        self.sessionsDirOverride = sessionsDirOverride
        self.isEnabled = isEnabled
    }

    static var defaultSessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
    }

    func fetch() async -> [UsageEntry] {
        let dir = sessionsDirOverride ?? Self.defaultSessionsDir
        return await Task.detached(priority: .utility) { () -> [UsageEntry] in
            Self.loadAllEntries(sessionsDir: dir)
        }.value
    }

    // MARK: - Parsing

    static func loadAllEntries(sessionsDir: URL) -> [UsageEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsDir.path) else { return [] }
        guard let enumerator = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [UsageEntry] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            // Skip Codex's `index/by-dir/*.jsonl` shortcut files — those are
            // aggregated pointers, not rollouts.
            if url.path.contains("/sessions/index/") { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            let entries = parseRollout(data: data, fileURL: url)
            out.append(contentsOf: entries)
        }
        return out
    }

    /// Parse one rollout file. Visible for testing.
    static func parseRollout(data: Data, fileURL: URL) -> [UsageEntry] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()
        isoFallback.formatOptions = [.withInternetDateTime]
        let decoder = JSONDecoder()

        var currentModel: String = "unknown"
        var sessionId: String = fileURL.deletingPathExtension().lastPathComponent
        let projectFallback = "codex"
        var projectName: String = projectFallback
        var entries: [UsageEntry] = []
        var lineIdx = 0

        for chunk in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            lineIdx += 1
            guard let event = try? decoder.decode(CodexEvent.self, from: Data(chunk)) else { continue }

            // session_meta sets the session id + cwd
            if event.type == "session_meta", let payload = event.payload {
                if let id = payload.id { sessionId = id }
                if let cwd = payload.cwd, !cwd.isEmpty {
                    projectName = URL(fileURLWithPath: cwd).lastPathComponent
                }
                continue
            }

            // turn_context updates the active model
            if event.type == "turn_context", let payload = event.payload {
                if let m = payload.model, !m.isEmpty { currentModel = m }
                if let cwd = payload.cwd, !cwd.isEmpty {
                    projectName = URL(fileURLWithPath: cwd).lastPathComponent
                }
                continue
            }

            // event_msg with payload.type == "token_count"
            if event.type == "event_msg",
               let payload = event.payload,
               payload.type == "token_count",
               let info = payload.info,
               let last = info.last_token_usage {
                let inputTokens = last.input_tokens ?? 0
                let cached = last.cached_input_tokens ?? 0
                let outputTokens = last.output_tokens ?? 0

                // Reconstruct a TranscriptUsage so we can reuse Pricing.cost().
                // Codex's `cached_input_tokens` are read-from-cache style; we map
                // them to cache_read_input_tokens, which Pricing treats as cheap.
                let pricingUsage = TranscriptUsage(
                    input_tokens: inputTokens,
                    output_tokens: outputTokens,
                    cache_creation_input_tokens: nil,
                    cache_read_input_tokens: cached,
                    cache_creation: nil
                )
                let cost = Pricing.cost(usage: pricingUsage, model: currentModel)

                let date = (event.timestamp.flatMap { iso.date(from: $0) ?? isoFallback.date(from: $0) }) ?? Date()
                let entry = UsageEntry(
                    id: "codex|\(sessionId)|\(lineIdx)",
                    timestamp: date,
                    model: currentModel,
                    project: projectName,
                    sessionId: sessionId,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheWrite5m: 0,
                    cacheWrite1h: 0,
                    cacheRead: cached,
                    cost: cost,
                    provider: ProviderID.codex
                )
                entries.append(entry)
            }
        }
        return entries
    }
}

// MARK: - Codex event schema (only the fields we need)

private struct CodexEvent: Decodable {
    let timestamp: String?
    let type: String?
    let payload: CodexPayload?
}

private struct CodexPayload: Decodable {
    // session_meta
    let id: String?
    let cwd: String?
    // turn_context
    let model: String?
    // event_msg
    let type: String?
    let info: CodexInfo?
}

private struct CodexInfo: Decodable {
    let last_token_usage: CodexTokenUsage?
    let total_token_usage: CodexTokenUsage?
}

private struct CodexTokenUsage: Decodable {
    let input_tokens: Int?
    let cached_input_tokens: Int?
    let output_tokens: Int?
    let reasoning_output_tokens: Int?
    let total_tokens: Int?
}
