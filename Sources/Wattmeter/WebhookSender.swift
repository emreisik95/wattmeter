import Foundation
import os

/// Slack-compatible webhook delivery. Payload shape mirrors a minimal
/// Slack Incoming Webhook: `{ "text": "...", "username": "Wattmeter", "attachments": [...] }`
/// which also passes through Discord/Mattermost-compatible endpoints.
///
/// URLs are NEVER logged in cleartext — see `WebhookRedaction.redact(_:)`.
struct WebhookPayload: Codable, Equatable {
    let text: String
    let username: String?
    let attachments: [Attachment]?

    struct Attachment: Codable, Equatable {
        let title: String
        let text: String
        let color: String?
    }

    init(text: String, username: String? = "Wattmeter", attachments: [Attachment]? = nil) {
        self.text = text
        self.username = username
        self.attachments = attachments
    }
}

/// Protocol surface kept narrow so we can inject a mock URLSession in tests.
protocol WebhookHTTPClient {
    func post(url: URL, body: Data) async throws -> (Data, URLResponse)
}

struct URLSessionWebhookClient: WebhookHTTPClient {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func post(url: URL, body: Data) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await session.data(for: req)
    }
}

enum WebhookError: Error, CustomStringConvertible {
    case encoding
    case http(Int)
    case transport(String)

    var description: String {
        switch self {
        case .encoding:           return "Webhook payload encoding failed"
        case .http(let c):        return "Webhook HTTP \(c)"
        case .transport(let s):   return "Webhook transport: \(s)"
        }
    }
}

final class WebhookSender {
    private let client: WebhookHTTPClient
    private let log = Logger(subsystem: "dev.emreisik.Wattmeter", category: "webhook")

    init(client: WebhookHTTPClient = URLSessionWebhookClient()) {
        self.client = client
    }

    /// Sends a payload to a raw URL string. URL is NOT retained or logged.
    @discardableResult
    func send(_ payload: WebhookPayload, to urlString: String) async throws -> Int {
        guard let url = URL(string: urlString) else {
            throw WebhookError.transport("invalid URL")
        }
        let redacted = WebhookRedaction.redact(urlString)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(payload) else {
            throw WebhookError.encoding
        }
        do {
            let (_, resp) = try await client.post(url: url, body: body)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            log.info("webhook delivered to \(redacted, privacy: .public) status=\(code, privacy: .public)")
            if !(200...299).contains(code) {
                throw WebhookError.http(code)
            }
            return code
        } catch let e as WebhookError {
            throw e
        } catch {
            log.error("webhook transport error to \(redacted, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw WebhookError.transport(error.localizedDescription)
        }
    }

    /// Convenience: looks up the URL by keychain ref and sends.
    @discardableResult
    func send(_ payload: WebhookPayload, keychainRef: String) async throws -> Int {
        guard let url = KeychainWebhookStore.load(ref: keychainRef) else {
            throw WebhookError.transport("no webhook for ref")
        }
        return try await send(payload, to: url)
    }

    /// Builds a payload for a budget exceeded event.
    static func budgetExceededPayload(budget: Budget, percent: Double) -> WebhookPayload {
        let pct = String(format: "%.0f%%", percent * 100)
        return WebhookPayload(
            text: "Wattmeter: budget exceeded — \(budget.label) (\(pct))",
            username: "Wattmeter",
            attachments: [
                .init(
                    title: budget.label,
                    text: "Window: \(budget.window.rawValue) · Cap: $\(String(format: "%.2f", budget.amountUSD))",
                    color: "#d62728"
                )
            ]
        )
    }
}
