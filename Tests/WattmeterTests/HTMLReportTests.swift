import XCTest
@testable import Wattmeter

final class HTMLReportTests: XCTestCase {

    private func sampleEntries() -> [UsageEntry] {
        let base = Date(timeIntervalSince1970: 1_700_000_000) // fixed instant
        func make(_ offset: TimeInterval, _ id: String, _ model: String, _ proj: String,
                  _ inp: Int, _ outp: Int, _ cost: Double, _ provider: String? = nil) -> UsageEntry {
            return UsageEntry(
                id: id, timestamp: base.addingTimeInterval(offset),
                model: model, project: proj, sessionId: "s-\(id)",
                inputTokens: inp, outputTokens: outp,
                cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0,
                cost: cost, provider: provider
            )
        }
        return [
            make(86_400 * 2, "c", "claude-3-5-sonnet", "alpha", 1500, 800, 0.32, "claude"),
            make(0,         "a", "claude-3-5-sonnet", "alpha", 1000, 500, 0.20, "claude"),
            make(86_400,    "b", "claude-3-5-haiku",  "beta",   500, 200, 0.05, nil),
            make(86_400,    "d", "claude-3-5-haiku",  "beta & co < > \"",   200, 100, 0.02, nil),
        ]
    }

    func testRenderIsByteDeterministic() throws {
        let entries = sampleEntries()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(86_400 * 3)
        let a = HTMLReport.render(entries: entries, range: start...end)
        let b = HTMLReport.render(entries: entries, range: start...end)
        XCTAssertEqual(a, b, "HTMLReport.render must be byte-stable across runs")
        // And again after shuffling input order — sort happens internally.
        let shuffled = entries.reversed()
        let c = HTMLReport.render(entries: Array(shuffled), range: start...end)
        XCTAssertEqual(a, c, "Render must be stable regardless of input order")
    }

    func testRenderContainsExpectedSections() throws {
        let entries = sampleEntries()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(86_400 * 3)
        let html = HTMLReport.render(entries: entries, range: start...end)
        XCTAssertTrue(html.contains("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("Wattmeter Usage Report"))
        XCTAssertTrue(html.contains("Summary"))
        XCTAssertTrue(html.contains("Per-day cost"))
        XCTAssertTrue(html.contains("<table id=\"entries\""))
        // HTML escaping check.
        XCTAssertTrue(html.contains("beta &amp; co &lt; &gt; &quot;"))
    }

    func testEmptyEntriesProducesValidHTML() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let html = HTMLReport.render(entries: [], range: now...now)
        XCTAssertTrue(html.contains("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("No data."))
        let html2 = HTMLReport.render(entries: [], range: now...now)
        XCTAssertEqual(html, html2)
    }

    func testWidgetSnapshotWriterRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: now)
        let entries: [UsageEntry] = [
            UsageEntry(id: "1", timestamp: dayStart.addingTimeInterval(60),
                       model: "claude-3-5-sonnet", project: "p", sessionId: "s",
                       inputTokens: 100, outputTokens: 50,
                       cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0,
                       cost: 0.10, provider: "claude"),
            UsageEntry(id: "2", timestamp: dayStart.addingTimeInterval(120),
                       model: "claude-3-5-haiku", project: "p", sessionId: "s",
                       inputTokens: 200, outputTokens: 80,
                       cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0,
                       cost: 0.02, provider: "claude"),
            UsageEntry(id: "3", timestamp: dayStart.addingTimeInterval(-86_400),
                       model: "claude-3-5-haiku", project: "p", sessionId: "s",
                       inputTokens: 9999, outputTokens: 9999,
                       cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0,
                       cost: 999.0, provider: "claude"),
        ]
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget_snapshot_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let snap = try WidgetSnapshotWriter.write(from: entries, now: now, calendar: cal, to: tmp)
        XCTAssertEqual(snap.todayTokens, 100 + 50 + 200 + 80)
        XCTAssertEqual(snap.todayCostUSD, 0.12, accuracy: 0.0001)
        XCTAssertEqual(snap.modelBreakdown.count, 2)
        XCTAssertEqual(snap.modelBreakdown.map(\.model), ["claude-3-5-haiku", "claude-3-5-sonnet"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))
    }

    func testURLSchemeHandlerDispatch() {
        var called = false
        var capturedParams: [String: String] = [:]
        URLSchemeHandler.register(actions: [
            "refresh": { params in
                called = true
                capturedParams = params
            }
        ])
        URLSchemeHandler.dispatch(URL(string: "wattmeter://refresh?source=raycast")!)
        // The dispatch is synchronous on the main thread.
        XCTAssertTrue(called)
        XCTAssertEqual(capturedParams["source"], "raycast")
    }
}
