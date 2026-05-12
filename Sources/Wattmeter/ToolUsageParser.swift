import Foundation

/// Parses ~/.claude/wattmeter_tools.jsonl produced by Resources/log_tool.sh
/// emitted via PreToolUse / PostToolUse hooks. Mtime-cached; malformed lines skipped.
struct ToolUsageRecord: Hashable {
    let timestamp: Date
    let phase: String          // "pre" | "post"
    let tool: String
    let filePath: String?      // best-effort extraction from raw payload
    let tokens: Int            // best-effort; usually 0 — payload schema varies
}

enum ToolUsageParser {
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/wattmeter_tools.jsonl")
    }

    private static let cacheLock = NSLock()
    private static var cachedMtime: Date?
    private static var cachedRecords: [ToolUsageRecord] = []
    private static var cachedSize: Int = -1

    /// Parse the default log file. Returns cached results when the file is unchanged.
    static func loadAll() -> [ToolUsageRecord] {
        loadAll(url: logURL)
    }

    /// Parse a given file path. Useful for tests with a tmp fixture.
    static func loadAll(url: URL) -> [ToolUsageRecord] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [] }
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1

        // Cache only valid for the default location; tests using a custom url bypass the cache.
        let isDefault = (url.path == Self.logURL.path)
        if isDefault {
            cacheLock.lock()
            if let cm = cachedMtime, cm == mtime, cachedSize == size {
                let snap = cachedRecords
                cacheLock.unlock()
                return snap
            }
            cacheLock.unlock()
        }

        guard let data = try? Data(contentsOf: url) else { return [] }
        var out: [ToolUsageRecord] = []
        out.reserveCapacity(max(64, data.count / 200))
        let decoder = JSONDecoder()
        for chunk in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let rec = decode(chunk: Data(chunk), decoder: decoder) else { continue }
            out.append(rec)
        }

        if isDefault {
            cacheLock.lock()
            cachedMtime = mtime
            cachedSize = size
            cachedRecords = out
            cacheLock.unlock()
        }
        return out
    }

    // MARK: - line decoding

    private struct Line: Decodable {
        let ts: String?
        let phase: String?
        let tool: String?
        let raw: String?
    }

    private struct RawPayload: Decodable {
        let tool_name: String?
        let tool: String?
        let tool_input: ToolInput?

        struct ToolInput: Decodable {
            let file_path: String?
            let path: String?
            let filename: String?
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func decode(chunk: Data, decoder: JSONDecoder) -> ToolUsageRecord? {
        guard let line = try? decoder.decode(Line.self, from: chunk) else { return nil }
        guard let phase = line.phase, !phase.isEmpty else { return nil }
        let toolName = (line.tool?.isEmpty == false ? line.tool : nil)
            ?? extractToolFromRaw(line.raw)
            ?? ""
        // Need at least a tool name to be useful.
        guard !toolName.isEmpty else { return nil }
        let timestamp: Date = {
            if let s = line.ts {
                if let d = isoFrac.date(from: s) { return d }
                if let d = iso.date(from: s) { return d }
            }
            return Date()
        }()
        let filePath = extractFilePath(line.raw)
        return ToolUsageRecord(
            timestamp: timestamp,
            phase: phase,
            tool: toolName,
            filePath: filePath,
            tokens: 0
        )
    }

    private static func extractToolFromRaw(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let data = unescapedData(raw) else { return nil }
        let p = try? JSONDecoder().decode(RawPayload.self, from: data)
        return p?.tool_name ?? p?.tool
    }

    private static func extractFilePath(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let data = unescapedData(raw) else { return nil }
        guard let p = try? JSONDecoder().decode(RawPayload.self, from: data) else { return nil }
        return p.tool_input?.file_path ?? p.tool_input?.path ?? p.tool_input?.filename
    }

    /// `raw` is the original payload re-encoded inside a JSON string (escaped). Decode as if it
    /// were a standalone JSON document. The shell wrapper escapes `\` and `"`; everything else is
    /// passed through. JSONDecoder of the outer line already unescaped it, so `raw` is now real JSON.
    private static func unescapedData(_ raw: String) -> Data? {
        raw.data(using: .utf8)
    }
}
