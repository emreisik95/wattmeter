import Foundation

/// Resolves a human-readable title for a session: the first real user prompt
/// from its transcript. Transcript files are named `<sessionId>.jsonl` under
/// `<claudeDir>/projects/<project>/`. Results (including misses) are cached
/// for the app's lifetime — titles don't change once a session has begun.
enum SessionTitles {
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    private static let userMarker: [UInt8] = Array("\"type\":\"user\"".utf8)

    /// Blocking — call off the main thread. Returns nil when no usable
    /// user prompt is found.
    static func resolve(sessionId: String, claudeDir: URL) -> String? {
        guard !sessionId.isEmpty else { return nil }
        lock.lock()
        if let hit = cache[sessionId] {
            lock.unlock()
            return hit.isEmpty ? nil : hit
        }
        lock.unlock()

        let title = scan(sessionId: sessionId, claudeDir: claudeDir) ?? ""
        lock.lock()
        cache[sessionId] = title
        lock.unlock()
        return title.isEmpty ? nil : title
    }

    private static func scan(sessionId: String, claudeDir: URL) -> String? {
        let projects = claudeDir.appendingPathComponent("projects")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projects,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let fileName = "\(sessionId).jsonl"
        for case let url as URL in enumerator where url.lastPathComponent == fileName {
            return firstUserText(in: url)
        }
        return nil
    }

    private static func firstUserText(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // First user prompt sits near the top — 256 KB is plenty.
        let data = handle.readData(ofLength: 256 * 1024)
        let decoder = JSONDecoder()
        for chunk in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard chunk.containsBytes(userMarker) else { continue }
            guard let line = try? decoder.decode(UserLine.self, from: Data(chunk)),
                  line.type == "user",
                  let text = line.message?.plainText else { continue }
            let cleaned = clean(text)
            guard isUsable(cleaned) else { continue }
            return cleaned
        }
        return nil
    }

    /// Skips harness noise: injected tags, command meta, continuation banners.
    private static func isUsable(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        if s.hasPrefix("<") { return false }
        if s.hasPrefix("Caveat:") { return false }
        return true
    }

    private static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 80 {
            t = String(t.prefix(80)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return t
    }

    private struct UserLine: Decodable {
        let type: String?
        let message: Message?

        struct Message: Decodable {
            let role: String?
            let content: Content?

            var plainText: String? {
                switch content {
                case .text(let s): return s
                case .blocks(let blocks):
                    return blocks.first { $0.type == "text" && !($0.text ?? "").isEmpty }?.text
                case nil: return nil
                }
            }
        }

        /// Transcript user content is either a plain string or a block array.
        enum Content: Decodable {
            case text(String)
            case blocks([Block])

            struct Block: Decodable {
                let type: String?
                let text: String?
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) {
                    self = .text(s)
                } else {
                    self = .blocks((try? c.decode([Block].self)) ?? [])
                }
            }
        }
    }
}
