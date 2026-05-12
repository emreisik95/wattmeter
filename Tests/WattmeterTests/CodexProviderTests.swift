import XCTest
@testable import Wattmeter

final class CodexProviderTests: XCTestCase {

    /// Minimal Codex rollout JSONL with one turn_context (sets model) and two
    /// token_count events (one with null info, one with usable counts).
    private let fixtureJSONL = """
    {"timestamp":"2026-03-27T14:59:30.435Z","type":"session_meta","payload":{"id":"019d2fce-81a8-76e1-b472-c7df4a731339","cwd":"/Volumes/External/Projects/demo"}}
    {"timestamp":"2026-03-27T14:59:30.437Z","type":"turn_context","payload":{"model":"claude-sonnet-4-5","cwd":"/Volumes/External/Projects/demo"}}
    {"timestamp":"2026-03-27T14:59:30.724Z","type":"event_msg","payload":{"type":"token_count","info":null}}
    {"timestamp":"2026-03-27T14:59:38.288Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20547,"cached_input_tokens":3456,"output_tokens":339,"total_tokens":20886},"last_token_usage":{"input_tokens":20547,"cached_input_tokens":3456,"output_tokens":339,"total_tokens":20886}}}}
    {"timestamp":"2026-03-27T14:59:42.178Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20946,"cached_input_tokens":20480,"output_tokens":54,"total_tokens":21000}}}}
    """

    func testParseRolloutEmitsUsageEntriesForNonNullTokenCounts() throws {
        let data = Data(fixtureJSONL.utf8)
        let fakeURL = URL(fileURLWithPath: "/tmp/rollout-019d2fce.jsonl")
        let entries = CodexProvider.parseRollout(data: data, fileURL: fakeURL)

        // 2 token_count events have usable last_token_usage; 1 was null.
        XCTAssertEqual(entries.count, 2, "Only token_count events with non-null info should emit entries")

        guard let first = entries.first else { return XCTFail("no entries") }
        XCTAssertEqual(first.provider, "codex")
        XCTAssertEqual(first.model, "claude-sonnet-4-5")
        XCTAssertEqual(first.sessionId, "019d2fce-81a8-76e1-b472-c7df4a731339")
        XCTAssertEqual(first.project, "demo")
        XCTAssertEqual(first.inputTokens, 20547)
        XCTAssertEqual(first.outputTokens, 339)
        XCTAssertEqual(first.cacheRead, 3456)
        XCTAssertEqual(first.cacheWrite5m, 0)
        XCTAssertEqual(first.cacheWrite1h, 0)
        // sonnet pricing: 3/M input + 15/M output + 0.3/M cache_read
        // = 20547*3e-6 + 339*15e-6 + 3456*0.3e-6 ≈ 0.0681...
        XCTAssertGreaterThan(first.cost, 0)
        XCTAssertEqual(first.providerOrClaude, "codex")
    }

    func testUnknownModelYieldsZeroCost() throws {
        let fixture = """
        {"timestamp":"2026-03-27T14:59:30.435Z","type":"session_meta","payload":{"id":"abc","cwd":"/tmp/x"}}
        {"timestamp":"2026-03-27T14:59:30.437Z","type":"turn_context","payload":{"model":"gpt-5.3-codex","cwd":"/tmp/x"}}
        {"timestamp":"2026-03-27T14:59:38.288Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":50,"total_tokens":150}}}}
        """
        let data = Data(fixture.utf8)
        let entries = CodexProvider.parseRollout(data: data, fileURL: URL(fileURLWithPath: "/tmp/r.jsonl"))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].cost, 0, "Unknown model → cost 0")
        XCTAssertEqual(entries[0].model, "gpt-5.3-codex")
    }

    func testEntryIdsAreStableAndUnique() throws {
        let data = Data(fixtureJSONL.utf8)
        let url = URL(fileURLWithPath: "/tmp/rollout-019d2fce.jsonl")
        let first = CodexProvider.parseRollout(data: data, fileURL: url)
        let second = CodexProvider.parseRollout(data: data, fileURL: url)
        XCTAssertEqual(first.map(\.id), second.map(\.id), "Re-parsing same data must produce identical ids")
        XCTAssertEqual(Set(first.map(\.id)).count, first.count, "Ids within a file must be unique")
    }

    func testCursorProviderIsDisabledStub() async {
        let cursor = CursorProvider()
        XCTAssertFalse(cursor.isEnabled)
        let result = await cursor.fetch()
        XCTAssertTrue(result.isEmpty)
    }
}
