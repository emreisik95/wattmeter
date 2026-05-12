import XCTest
@testable import Wattmeter

final class WebhookSenderTests: XCTestCase {

    final class MockClient: WebhookHTTPClient, @unchecked Sendable {
        var capturedURL: URL?
        var capturedBody: Data?
        var statusCode: Int = 200

        func post(url: URL, body: Data) async throws -> (Data, URLResponse) {
            self.capturedURL = url
            self.capturedBody = body
            let resp = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }
    }

    func test_redact_masks_path_after_first_segment() {
        let raw = "https://hooks.slack.com/services/T123/B456/SECRETTOKEN"
        let red = WebhookRedaction.redact(raw)
        XCTAssertFalse(red.contains("B456"))
        XCTAssertFalse(red.contains("SECRETTOKEN"))
        XCTAssertTrue(red.contains("hooks.slack.com"))
        XCTAssertTrue(red.contains("/services"))
    }

    func test_redact_invalid_url_returns_placeholder() {
        XCTAssertEqual(WebhookRedaction.redact(""), "<redacted>")
    }

    func test_send_posts_json_payload() async throws {
        let mock = MockClient()
        let sender = WebhookSender(client: mock)
        let payload = WebhookPayload(text: "hello", attachments: nil)

        _ = try await sender.send(payload, to: "https://example.com/hook/abc")

        XCTAssertEqual(mock.capturedURL?.absoluteString, "https://example.com/hook/abc")
        guard let body = mock.capturedBody else { return XCTFail("no body") }
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(obj?["text"] as? String, "hello")
        XCTAssertEqual(obj?["username"] as? String, "Wattmeter")
    }

    func test_send_throws_on_http_error() async {
        let mock = MockClient()
        mock.statusCode = 500
        let sender = WebhookSender(client: mock)
        do {
            _ = try await sender.send(WebhookPayload(text: "x"), to: "https://example.com/hook")
            XCTFail("expected throw")
        } catch let WebhookError.http(code) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_budgetExceeded_payload_shape() throws {
        let b = Budget(label: "Daily $5", amountUSD: 5, window: .daily)
        let payload = WebhookSender.budgetExceededPayload(budget: b, percent: 1.05)
        XCTAssertTrue(payload.text.contains("Daily $5"))
        XCTAssertEqual(payload.attachments?.first?.color, "#d62728")

        let data = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj?["text"])
        XCTAssertNotNil(obj?["attachments"])
    }
}
