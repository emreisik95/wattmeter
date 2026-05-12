import Foundation

// The `ToolUsageStore` class is declared in FrozenAPI.swift to satisfy the frozen interface
// referenced by other teammates. We extend it here with the parsing + aggregation behavior
// owned by Teammate A2 (F2).
@MainActor
extension ToolUsageStore {
    /// Refresh from `~/.claude/wattmeter_tools.jsonl`. Reads on a utility task; aggregates
    /// per-tool and per-file usage stats; updates the published dictionaries on the main actor.
    func refreshFromLog() async {
        let records = await Task.detached(priority: .utility) {
            ToolUsageParser.loadAll()
        }.value
        let (perToolMap, perFileMap) = Self.aggregate(records: records)
        self._setForTesting(perTool: perToolMap, perFile: perFileMap)
        self.lastRefresh = Date()
    }

    /// Aggregate records into per-tool and per-file ToolStat dictionaries.
    /// Counts each `pre` event as one invocation. A `post` is only counted when no matching
    /// `pre` exists for that tool (fail-open for partial logs). Token counts remain 0 — hook
    /// payloads do not carry token usage; per-tool token attribution requires correlation with
    /// the assistant transcript and is out-of-scope for v0.2.0.
    nonisolated static func aggregate(records: [ToolUsageRecord]) -> (perTool: [String: ToolStat], perFile: [String: ToolStat]) {
        var toolCounts: [String: Int] = [:]
        var fileCounts: [String: Int] = [:]
        for r in records {
            if r.phase == "pre" {
                toolCounts[r.tool, default: 0] += 1
                if let fp = r.filePath, !fp.isEmpty {
                    fileCounts[fp, default: 0] += 1
                }
            } else if r.phase == "post" {
                if toolCounts[r.tool] == nil {
                    toolCounts[r.tool, default: 0] += 1
                    if let fp = r.filePath, !fp.isEmpty {
                        fileCounts[fp, default: 0] += 1
                    }
                }
            }
        }
        let perTool = toolCounts.mapValues { ToolStat(count: $0, tokens: 0) }
        let perFile = fileCounts.mapValues { ToolStat(count: $0, tokens: 0) }
        return (perTool, perFile)
    }
}
