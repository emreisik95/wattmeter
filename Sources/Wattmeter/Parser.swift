import Foundation

private let assistantMarker: [UInt8] = Array("\"type\":\"assistant\"".utf8)
private let usageMarker: [UInt8] = Array("\"usage\"".utf8)

extension Data.SubSequence {
    /// Fast substring containment check on raw bytes — avoids String allocation.
    func containsBytes(_ needle: [UInt8]) -> Bool {
        let nLen = needle.count
        guard nLen > 0 else { return true }
        let hLen = self.count
        if hLen < nLen { return false }
        let hayBase = self.startIndex
        outer: for i in 0...(hLen - nLen) {
            for j in 0..<nLen {
                if self[hayBase + i + j] != needle[j] { continue outer }
            }
            return true
        }
        return false
    }
}

enum Parser {
    static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    private static var fileCache: [String: (mtime: Date, entries: [UsageEntry])] = [:]
    private static let cacheLock = NSLock()

    /// Streaming variant: invokes `onBatch` per file as soon as that file's entries are parsed.
    /// Files are visited newest-mtime-first so live/recent data shows up before older history.
    static func loadAllEntriesStreaming(onBatch: ([UsageEntry]) -> Void) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsDir.path) else { return }
        guard let enumerator = fm.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // Collect urls + mtimes, sort newest first
        var urls: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            urls.append((url, mtime))
        }
        urls.sort { $0.1 > $1.1 }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()
        isoFallback.formatOptions = [.withInternetDateTime]
        let decoder = JSONDecoder()

        var seen = Set<String>()
        var liveKeys = Set<String>()

        for (url, mtime) in urls {
            let path = url.path
            liveKeys.insert(path)

            cacheLock.lock()
            let cached = fileCache[path]
            cacheLock.unlock()

            if let cached, cached.mtime == mtime {
                var batch: [UsageEntry] = []
                batch.reserveCapacity(cached.entries.count)
                for entry in cached.entries where seen.insert(entry.id).inserted {
                    batch.append(entry)
                }
                if !batch.isEmpty { onBatch(batch) }
                continue
            }

            guard let data = try? Data(contentsOf: url) else { continue }
            let projectFolder = url.deletingLastPathComponent().lastPathComponent
            var fileEntries: [UsageEntry] = []
            var batch: [UsageEntry] = []

            for chunk in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                if !chunk.containsBytes(assistantMarker) { continue }
                if !chunk.containsBytes(usageMarker) { continue }
                guard let line = try? decoder.decode(TranscriptLine.self, from: Data(chunk)) else { continue }
                guard line.type == "assistant",
                      let msg = line.message,
                      let usage = msg.usage,
                      let model = msg.model,
                      let id = msg.id else { continue }
                let req = line.requestId ?? ""
                let key = "\(id)|\(req)"

                let date = (line.timestamp.flatMap { iso.date(from: $0) ?? isoFallback.date(from: $0) }) ?? Date()
                let proj = projectName(cwd: line.cwd, fallback: projectFolder)
                let cost = Pricing.cost(usage: usage, model: model)
                let cache5m = usage.cache_creation?.ephemeral_5m_input_tokens
                    ?? usage.cache_creation_input_tokens ?? 0
                let cache1h = usage.cache_creation?.ephemeral_1h_input_tokens ?? 0

                let entry = UsageEntry(
                    id: key,
                    timestamp: date,
                    model: model,
                    project: proj,
                    sessionId: line.sessionId ?? "",
                    inputTokens: usage.input_tokens ?? 0,
                    outputTokens: usage.output_tokens ?? 0,
                    cacheWrite5m: cache5m,
                    cacheWrite1h: cache1h,
                    cacheRead: usage.cache_read_input_tokens ?? 0,
                    cost: cost
                )
                fileEntries.append(entry)
                if seen.insert(key).inserted {
                    batch.append(entry)
                }
            }

            cacheLock.lock()
            fileCache[path] = (mtime, fileEntries)
            cacheLock.unlock()

            if !batch.isEmpty { onBatch(batch) }
        }

        cacheLock.lock()
        for path in fileCache.keys where !liveKeys.contains(path) {
            fileCache.removeValue(forKey: path)
        }
        cacheLock.unlock()
    }

    /// Synchronous full load (kept for tests / callers that want all entries at once).
    static func loadAllEntries() -> [UsageEntry] {
        var out: [UsageEntry] = []
        loadAllEntriesStreaming { batch in
            out.append(contentsOf: batch)
        }
        out.sort { $0.timestamp < $1.timestamp }
        return out
    }

    private static func projectName(cwd: String?, fallback: String) -> String {
        if let cwd, !cwd.isEmpty {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        return fallback
            .split(separator: "-")
            .last
            .map(String.init) ?? fallback
    }
}
