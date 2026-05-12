import XCTest
@testable import Wattmeter

final class SmokeTests: XCTestCase {
    func testFrozenAPISymbolsExist() async {
        let entry = UsageEntry(
            id: "x", timestamp: Date(), model: "claude", project: "p", sessionId: "s",
            inputTokens: 1, outputTokens: 1, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0,
            cost: 0.01, provider: nil
        )
        XCTAssertEqual(entry.providerOrClaude, "claude")

        let b = Budget(label: "test", amountUSD: 5, window: .daily)
        XCTAssertEqual(b.window, .daily)

        let s = ServiceStatus(indicator: .none, description: "")
        XCTAssertTrue(s.isHealthy)
    }
}
