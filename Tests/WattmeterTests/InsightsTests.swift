import XCTest
@testable import Wattmeter

final class InsightsTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func entry(
        id: String = UUID().uuidString,
        at date: Date,
        cost: Double,
        model: String = "claude-3-5-sonnet-20240620",
        project: String = "proj"
    ) -> UsageEntry {
        UsageEntry(
            id: id,
            timestamp: date,
            model: model,
            project: project,
            sessionId: "s1",
            inputTokens: 100,
            outputTokens: 50,
            cacheWrite5m: 0,
            cacheWrite1h: 0,
            cacheRead: 0,
            cost: cost
        )
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: iso)!
    }

    // MARK: - peakHour math

    func testPeakHourBasic() {
        let now = date("2025-06-10T20:00:00Z")
        // Two entries at hour 14, one at hour 9
        let entries: [UsageEntry] = [
            entry(at: date("2025-06-10T14:05:00Z"), cost: 1.00),
            entry(at: date("2025-06-09T14:30:00Z"), cost: 2.00),
            entry(at: date("2025-06-10T09:00:00Z"), cost: 0.50),
        ]
        let s = Insights.standup(entries, now: now, calendar: calendar)
        XCTAssertEqual(s.peakHour, 14)
        XCTAssertEqual(s.peakHourCost, 3.00, accuracy: 1e-9)
    }

    func testPeakHourTiebreakLowest() {
        // Hours 5 and 17 each get $1; expect lower-hour winner (5).
        let now = date("2025-06-10T23:00:00Z")
        let entries: [UsageEntry] = [
            entry(at: date("2025-06-10T05:00:00Z"), cost: 1.00),
            entry(at: date("2025-06-10T17:00:00Z"), cost: 1.00),
        ]
        let s = Insights.standup(entries, now: now, calendar: calendar)
        XCTAssertEqual(s.peakHour, 5)
    }

    func testPeakHourEmpty() {
        let now = date("2025-06-10T20:00:00Z")
        let s = Insights.standup([], now: now, calendar: calendar)
        XCTAssertNil(s.peakHour)
        XCTAssertEqual(s.peakHourCost, 0)
    }

    func testPeakHourExcludesBeyondWindow() {
        // Entry older than 7 days should NOT influence peak.
        let now = date("2025-06-10T20:00:00Z")
        let entries: [UsageEntry] = [
            entry(at: date("2025-05-01T10:00:00Z"), cost: 100), // far past
            entry(at: date("2025-06-10T18:00:00Z"), cost: 0.50),
        ]
        let s = Insights.standup(entries, now: now, calendar: calendar)
        XCTAssertEqual(s.peakHour, 18)
        XCTAssertEqual(s.peakHourCost, 0.50, accuracy: 1e-9)
    }

    // MARK: - top model

    func testTopModelDeterminism() {
        let now = date("2025-06-10T20:00:00Z")
        // Two models tied at $1 today. Tiebreak alphabetical (haiku < sonnet).
        let entries: [UsageEntry] = [
            entry(at: date("2025-06-10T10:00:00Z"), cost: 1.0, model: "claude-3-haiku"),
            entry(at: date("2025-06-10T11:00:00Z"), cost: 1.0, model: "claude-3-sonnet"),
        ]
        let s = Insights.standup(entries, now: now, calendar: calendar)
        XCTAssertEqual(s.topModel, "haiku")
        XCTAssertEqual(s.topModelCost, 1.0, accuracy: 1e-9)
    }

    func testTopModelClearWinner() {
        let now = date("2025-06-10T20:00:00Z")
        let entries: [UsageEntry] = [
            entry(at: date("2025-06-10T10:00:00Z"), cost: 0.10, model: "claude-3-haiku"),
            entry(at: date("2025-06-10T11:00:00Z"), cost: 5.00, model: "claude-3-opus-20240229"),
            entry(at: date("2025-06-10T12:00:00Z"), cost: 0.50, model: "claude-3-sonnet"),
        ]
        let s = Insights.standup(entries, now: now, calendar: calendar)
        XCTAssertEqual(s.topModel, "opus")
        XCTAssertEqual(s.topModelCost, 5.00, accuracy: 1e-9)
    }

    // MARK: - today vs yesterday

    func testTodayVsYesterdayAndDelta() {
        let now = date("2025-06-10T20:00:00Z")
        let entries: [UsageEntry] = [
            entry(at: date("2025-06-09T10:00:00Z"), cost: 4.00),  // yesterday
            entry(at: date("2025-06-09T15:00:00Z"), cost: 1.00),  // yesterday
            entry(at: date("2025-06-10T10:00:00Z"), cost: 7.50),  // today
        ]
        let s = Insights.standup(entries, now: now, calendar: calendar)
        XCTAssertEqual(s.todayCost, 7.50, accuracy: 1e-9)
        XCTAssertEqual(s.yesterdayCost, 5.00, accuracy: 1e-9)
        // delta = (7.5 - 5.0) / 5.0 * 100 = 50%
        XCTAssertEqual(s.deltaPercent ?? 0, 50.0, accuracy: 1e-9)
        XCTAssertEqual(s.requestCountToday, 1)
    }

    func testDeltaPercentNilWhenYesterdayZero() {
        let now = date("2025-06-10T20:00:00Z")
        let entries: [UsageEntry] = [
            entry(at: date("2025-06-10T10:00:00Z"), cost: 3.00),
        ]
        let s = Insights.standup(entries, now: now, calendar: calendar)
        XCTAssertNil(s.deltaPercent)
    }

    // MARK: - top project

    func testTopProjectAndDeterminism() {
        let now = date("2025-06-10T20:00:00Z")
        // alpha and beta tied at $2 today, expect "alpha" via alphabetical tiebreak.
        let entries: [UsageEntry] = [
            entry(at: date("2025-06-10T10:00:00Z"), cost: 2.0, project: "alpha"),
            entry(at: date("2025-06-10T11:00:00Z"), cost: 2.0, project: "beta"),
        ]
        let s = Insights.standup(entries, now: now, calendar: calendar)
        XCTAssertEqual(s.topProject, "alpha")
    }

    func testFormatHour() {
        XCTAssertEqual(Insights.formatHour(0), "00:00")
        XCTAssertEqual(Insights.formatHour(9), "09:00")
        XCTAssertEqual(Insights.formatHour(23), "23:00")
    }
}
