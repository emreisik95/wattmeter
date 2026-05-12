import Foundation

struct TranscriptLine: Decodable {
    let type: String?
    let timestamp: String?
    let cwd: String?
    let sessionId: String?
    let requestId: String?
    let message: TranscriptMessage?
}

struct TranscriptMessage: Decodable {
    let id: String?
    let model: String?
    let role: String?
    let usage: TranscriptUsage?
}

struct TranscriptUsage: Decodable {
    let input_tokens: Int?
    let output_tokens: Int?
    let cache_creation_input_tokens: Int?
    let cache_read_input_tokens: Int?
    let cache_creation: CacheCreation?

    struct CacheCreation: Decodable {
        let ephemeral_5m_input_tokens: Int?
        let ephemeral_1h_input_tokens: Int?
    }
}

struct UsageEntry: Identifiable, Hashable, Codable {
    let id: String
    let timestamp: Date
    let model: String
    let project: String
    let sessionId: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheWrite5m: Int
    let cacheWrite1h: Int
    let cacheRead: Int
    let cost: Double

    var totalTokens: Int {
        inputTokens + outputTokens + cacheWrite5m + cacheWrite1h + cacheRead
    }
}
