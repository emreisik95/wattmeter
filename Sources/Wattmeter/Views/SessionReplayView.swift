import SwiftUI
import AppKit

/// F6 Session Replay — FULL variant (not fallback-only).
///
/// Loads the session's JSONL from `~/.claude/projects/<slug>/<sessionId>.jsonl`
/// (the same files Parser.swift consumes), then renders the message list with
/// per-turn cost attribution.
///
/// A "Reveal JSONL in Finder" button is always present as a graceful escape.
struct SessionReplayView: View {
    let sessionId: String
    /// Entries already parsed for this session — gives us cost/turn without
    /// re-running the cost calculator.
    let entries: [UsageEntry]

    @Environment(\.dismiss) var dismiss
    @State private var messages: [ReplayTurn] = []
    @State private var jsonlPath: URL?
    @State private var loadError: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if loading {
                ProgressView("Loading session…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loadError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2).foregroundStyle(.orange)
                    Text("Couldn't load session transcript")
                        .font(.headline)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let path = jsonlPath {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([path])
                        } label: {
                            Label("Reveal JSONL in Finder", systemImage: "folder")
                        }
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
                    Text("No transcribable turns found in this session.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(messages) { t in TurnRow(turn: t) }
                    }
                    .padding(14)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, idealWidth: 640, minHeight: 480, idealHeight: 640)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Session replay").font(.headline)
                Text(short(sessionId)).font(.caption).monospaced().foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "$%.2f total", entries.reduce(0) { $0 + $1.cost }))
                .font(.callout).bold().monospacedDigit().foregroundStyle(Theme.accent)
        }
        .padding(14)
    }

    private var footer: some View {
        HStack {
            if let path = jsonlPath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([path])
                } label: {
                    Label("Reveal JSONL in Finder", systemImage: "folder")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            Spacer()
            Text("\(messages.count) turns").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func short(_ s: String) -> String {
        s.isEmpty ? "(no-id)" : s
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        let result = await Task.detached(priority: .userInitiated) { () -> (URL?, [ReplayTurn], String?) in
            return Self.findAndParse(sessionId: sessionId, entries: entries)
        }.value
        self.jsonlPath = result.0
        self.messages = result.1
        self.loadError = result.2
    }

    /// Locate the JSONL file under `~/.claude/projects` whose basename matches
    /// the sessionId, then stream-parse it into ReplayTurn rows.
    nonisolated static func findAndParse(sessionId: String, entries: [UsageEntry]) -> (URL?, [ReplayTurn], String?) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = home.appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsDir.path) else {
            return (nil, [], "~/.claude/projects not found.")
        }
        // Walk the tree, find <sessionId>.jsonl
        var match: URL?
        if let enumerator = fm.enumerator(at: projectsDir, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                if url.lastPathComponent == "\(sessionId).jsonl" {
                    match = url
                    break
                }
            }
        }
        guard let jsonl = match else {
            return (nil, [], "Could not locate \(sessionId).jsonl in ~/.claude/projects.")
        }
        guard let data = try? Data(contentsOf: jsonl) else {
            return (jsonl, [], "Failed to read transcript file.")
        }

        // Build cost index keyed by message id (matches Parser.swift's `key = "<msgId>|<reqId>"`).
        var costByMsgId: [String: Double] = [:]
        for e in entries {
            let parts = e.id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            if let mid = parts.first {
                costByMsgId[String(mid), default: 0] += e.cost
            }
        }

        let decoder = JSONDecoder()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]

        var turns: [ReplayTurn] = []
        turns.reserveCapacity(128)

        for chunk in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let line = try? decoder.decode(ReplayLine.self, from: Data(chunk)) else { continue }
            let role: ReplayTurn.Role
            switch line.type {
            case "user":      role = .user
            case "assistant": role = .assistant
            case "system":    role = .system
            default: continue
            }

            // Pull a previewable string from message.content. Content can be
            // a string, an array of blocks, or absent.
            let text = Self.extractText(from: line.message?.content) ?? ""
            let ts = line.timestamp.flatMap { iso.date(from: $0) ?? iso2.date(from: $0) }
            let cost: Double? = {
                if let mid = line.message?.id { return costByMsgId[mid] }
                return nil
            }()
            let model = line.message?.model
            let tokensIn = line.message?.usage?.input_tokens
            let tokensOut = line.message?.usage?.output_tokens

            turns.append(ReplayTurn(
                id: UUID(),
                role: role,
                timestamp: ts,
                text: text,
                cost: cost,
                model: model,
                inputTokens: tokensIn,
                outputTokens: tokensOut
            ))
        }
        return (jsonl, turns, nil)
    }

    nonisolated private static func extractText(from content: ReplayContent?) -> String? {
        guard let content else { return nil }
        switch content {
        case .string(let s): return s
        case .blocks(let blocks):
            var parts: [String] = []
            for b in blocks {
                if let t = b.text, !t.isEmpty { parts.append(t) }
                else if b.type == "tool_use", let name = b.name { parts.append("⟳ tool: \(name)") }
                else if b.type == "tool_result" { parts.append("← tool result") }
            }
            return parts.joined(separator: "\n")
        }
    }
}

// MARK: - Decoders

private struct ReplayLine: Decodable {
    let type: String?
    let timestamp: String?
    let message: ReplayMessage?
}

private struct ReplayMessage: Decodable {
    let id: String?
    let model: String?
    let role: String?
    let content: ReplayContent?
    let usage: ReplayUsage?
}

private struct ReplayUsage: Decodable {
    let input_tokens: Int?
    let output_tokens: Int?
}

private enum ReplayContent: Decodable {
    case string(String)
    case blocks([ReplayBlock])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .string(s); return
        }
        if let arr = try? c.decode([ReplayBlock].self) {
            self = .blocks(arr); return
        }
        self = .string("")
    }
}

private struct ReplayBlock: Decodable {
    let type: String?
    let text: String?
    let name: String?
}

// MARK: - View model

struct ReplayTurn: Identifiable {
    enum Role { case user, assistant, system }
    let id: UUID
    let role: Role
    let timestamp: Date?
    let text: String
    let cost: Double?
    let model: String?
    let inputTokens: Int?
    let outputTokens: Int?
}

private struct TurnRow: View {
    let turn: ReplayTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color).font(.caption)
                Text(label).font(.caption).bold().foregroundStyle(color)
                if let m = turn.model {
                    Text("·").foregroundStyle(.tertiary)
                    Text(Aggregator.shortModel(m)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                if let ts = turn.timestamp {
                    Text("·").foregroundStyle(.tertiary)
                    Text(ts.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
                Spacer()
                if let c = turn.cost, c > 0 {
                    Text(String(format: "$%.3f", c))
                        .font(.caption).bold().monospacedDigit().foregroundStyle(Theme.accent)
                }
            }
            if !turn.text.isEmpty {
                Text(turn.text)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(6)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if (turn.inputTokens ?? 0) > 0 || (turn.outputTokens ?? 0) > 0 {
                HStack(spacing: 6) {
                    if let i = turn.inputTokens, i > 0 {
                        Text("in \(i)").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    if let o = turn.outputTokens, o > 0 {
                        Text("· out \(o)").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var color: Color {
        switch turn.role {
        case .user:      return .blue
        case .assistant: return Theme.accent
        case .system:    return .gray
        }
    }
    private var icon: String {
        switch turn.role {
        case .user:      return "person.fill"
        case .assistant: return "brain.head.profile"
        case .system:    return "gearshape.fill"
        }
    }
    private var label: String {
        switch turn.role {
        case .user:      return "USER"
        case .assistant: return "ASSISTANT"
        case .system:    return "SYSTEM"
        }
    }
}
