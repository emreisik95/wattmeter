import XCTest
@testable import Wattmeter

final class ToolUsageParserTests: XCTestCase {

    private func tmpFileURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wattmeter-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("wattmeter_tools.jsonl")
    }

    func testEmptyFileReturnsEmpty() {
        let url = tmpFileURL()
        try? Data().write(to: url)
        let recs = ToolUsageParser.loadAll(url: url)
        XCTAssertEqual(recs.count, 0)
    }

    func testMissingFileReturnsEmpty() {
        let url = tmpFileURL().appendingPathExtension("doesnotexist")
        let recs = ToolUsageParser.loadAll(url: url)
        XCTAssertEqual(recs.count, 0)
    }

    func testSkipsMalformedLines() throws {
        let url = tmpFileURL()
        // Mix valid + garbage + truncated.
        let lines = [
            #"{"ts":"2026-05-12T10:00:00Z","phase":"pre","tool":"Read","raw":"{}"}"#,
            "not valid json at all",
            #"{"ts":"2026-05-12T10:00:01Z","phase":"post","tool":"Read","raw":"{}"}"#,
            "",
            #"{"foo":"bar"}"#,                  // missing required fields
            #"{"ts":"2026-05-12T10:00:02Z","phase":"pre","tool":"Edit","raw":"{}"}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)
        let recs = ToolUsageParser.loadAll(url: url)
        XCTAssertEqual(recs.count, 3)
        XCTAssertEqual(recs.map(\.tool), ["Read", "Read", "Edit"])
        XCTAssertEqual(recs.map(\.phase), ["pre", "post", "pre"])
    }

    func testToolNameFallbackFromRawPayload() throws {
        // When the `tool` field on the outer line is empty, parser falls back to .tool_name in raw.
        let url = tmpFileURL()
        let line = #"{"ts":"2026-05-12T10:00:00Z","phase":"pre","tool":"","raw":"{\"tool_name\":\"Bash\"}"}"#
        try line.data(using: .utf8)!.write(to: url)
        let recs = ToolUsageParser.loadAll(url: url)
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs.first?.tool, "Bash")
    }

    func testExtractsFilePathFromRaw() throws {
        let url = tmpFileURL()
        let line = #"{"ts":"2026-05-12T10:00:00Z","phase":"pre","tool":"Edit","raw":"{\"tool_input\":{\"file_path\":\"/tmp/example.swift\"}}"}"#
        try line.data(using: .utf8)!.write(to: url)
        let recs = ToolUsageParser.loadAll(url: url)
        XCTAssertEqual(recs.first?.filePath, "/tmp/example.swift")
    }

    func testIso8601TimestampParsing() throws {
        let url = tmpFileURL()
        let lines = [
            #"{"ts":"2026-05-12T10:00:00.123Z","phase":"pre","tool":"Read","raw":"{}"}"#,
            #"{"ts":"2026-05-12T10:00:01Z","phase":"pre","tool":"Read","raw":"{}"}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)
        let recs = ToolUsageParser.loadAll(url: url)
        XCTAssertEqual(recs.count, 2)
        XCTAssertLessThan(recs[0].timestamp, recs[1].timestamp)
    }

    func testAggregatorCountsPerToolAndFile() {
        let now = Date()
        let recs: [ToolUsageRecord] = [
            .init(timestamp: now, phase: "pre", tool: "Read",  filePath: "/a.swift", tokens: 0),
            .init(timestamp: now, phase: "post", tool: "Read", filePath: "/a.swift", tokens: 0),
            .init(timestamp: now, phase: "pre", tool: "Edit",  filePath: "/a.swift", tokens: 0),
            .init(timestamp: now, phase: "pre", tool: "Read",  filePath: "/b.swift", tokens: 0)
        ]
        let (perTool, perFile) = ToolUsageStore.aggregate(records: recs)
        XCTAssertEqual(perTool["Read"]?.count, 2)
        XCTAssertEqual(perTool["Edit"]?.count, 1)
        XCTAssertEqual(perFile["/a.swift"]?.count, 2)
        XCTAssertEqual(perFile["/b.swift"]?.count, 1)
        // post-only entries are tolerated (orphan post is counted once).
        let orphan: [ToolUsageRecord] = [
            .init(timestamp: now, phase: "post", tool: "Glob", filePath: nil, tokens: 0)
        ]
        let (t, _) = ToolUsageStore.aggregate(records: orphan)
        XCTAssertEqual(t["Glob"]?.count, 1)
    }
}
