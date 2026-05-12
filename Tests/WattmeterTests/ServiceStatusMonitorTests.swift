import XCTest
@testable import Wattmeter

final class ServiceStatusMonitorTests: XCTestCase {

    private func decode(_ raw: String) throws -> ServiceStatus {
        let data = raw.data(using: .utf8)!
        let resp = try JSONDecoder().decode(AnthropicStatusResponse.self, from: data)
        return ServiceStatusEngine.decode(resp)
    }

    func test_decode_indicator_none() throws {
        let s = try decode(#"""
        { "status": { "indicator": "none", "description": "All Systems Operational" } }
        """#)
        XCTAssertEqual(s.indicator, .none)
        XCTAssertTrue(s.isHealthy)
        XCTAssertEqual(s.description, "All Systems Operational")
    }

    func test_decode_indicator_minor() throws {
        let s = try decode(#"""
        { "status": { "indicator": "minor", "description": "Minor incident" } }
        """#)
        XCTAssertEqual(s.indicator, .minor)
        XCTAssertFalse(s.isHealthy)
    }

    func test_decode_indicator_major() throws {
        let s = try decode(#"""
        { "status": { "indicator": "major", "description": "Major service disruption" } }
        """#)
        XCTAssertEqual(s.indicator, .major)
    }

    func test_decode_indicator_critical() throws {
        let s = try decode(#"""
        { "status": { "indicator": "critical", "description": "Critical outage" } }
        """#)
        XCTAssertEqual(s.indicator, .critical)
    }

    func test_decode_indicator_maintenance() throws {
        let s = try decode(#"""
        { "status": { "indicator": "maintenance", "description": "Scheduled maintenance" } }
        """#)
        XCTAssertEqual(s.indicator, .maintenance)
    }

    func test_decode_unknown_indicator_falls_back_to_none() throws {
        let s = try decode(#"""
        { "status": { "indicator": "extragalactic", "description": "future status" } }
        """#)
        XCTAssertEqual(s.indicator, .none)
    }

    @MainActor
    func test_engine_refresh_with_mock_fetcher_updates_state() async {
        struct StubFetcher: ServiceStatusFetcher {
            func fetch() async throws -> AnthropicStatusResponse {
                AnthropicStatusResponse(status: .init(indicator: "critical", description: "down"))
            }
        }
        let engine = ServiceStatusEngine(fetcher: StubFetcher())
        let s = await engine.refresh()
        XCTAssertEqual(s.indicator, .critical)
        XCTAssertEqual(engine.current.indicator, .critical)
        XCTAssertNotNil(engine.lastCheck)
        XCTAssertNil(engine.lastError)
    }

    @MainActor
    func test_engine_refresh_failure_records_error() async {
        struct FailingFetcher: ServiceStatusFetcher {
            func fetch() async throws -> AnthropicStatusResponse {
                throw URLError(.notConnectedToInternet)
            }
        }
        let engine = ServiceStatusEngine(fetcher: FailingFetcher())
        _ = await engine.refresh()
        XCTAssertNotNil(engine.lastError)
    }
}
