import SwiftUI

/// Per-tool / per-file breakdown of tool-use cost from `ToolUsageStore` (F2).
struct ToolBreakdownView: View {
    @EnvironmentObject var toolStore: ToolUsageStore

    enum Mode: String, CaseIterable, Identifiable {
        case tool = "By tool"
        case file = "By file"
        var id: String { rawValue }
    }
    @State private var mode: Mode = .tool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Tool usage", systemImage: "wrench.and.screwdriver.fill")
                    .font(.headline).foregroundStyle(Theme.accent)
                Spacer()
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                Button {
                    Task { await toolStore.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding(14)
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let rows: [(name: String, stat: ToolStat)] = {
            let src = mode == .tool ? toolStore.perTool : toolStore.perFile
            return src.map { (name: $0.key, stat: $0.value) }
                .sorted { lhs, rhs in
                    if lhs.stat.tokens != rhs.stat.tokens { return lhs.stat.tokens > rhs.stat.tokens }
                    return lhs.name < rhs.name
                }
        }()
        if rows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
                Text("No tool usage recorded yet.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Install hooks from Settings → Tools to start tracking PreToolUse / PostToolUse events.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                let maxTokens = max(1, rows.map(\.stat.tokens).max() ?? 1)
                let totalCount = rows.reduce(0) { $0 + $1.stat.count }
                VStack(spacing: 0) {
                    ForEach(rows, id: \.name) { row in
                        ToolRow(
                            name: row.name,
                            stat: row.stat,
                            fraction: Double(row.stat.tokens) / Double(maxTokens),
                            countShare: totalCount > 0 ? Double(row.stat.count) / Double(totalCount) : 0,
                            isTool: mode == .tool
                        )
                        Divider()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
    }
}

private struct ToolRow: View {
    let name: String
    let stat: ToolStat
    let fraction: Double
    let countShare: Double
    let isTool: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: isTool ? toolIcon(name) : "doc.text")
                    .foregroundStyle(Theme.accent).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.callout).bold()
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text("\(stat.count) uses")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(shortNum(stat.tokens)) tok")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer()
                Text(String(format: "%.0f%%", countShare * 100))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.12))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.accent.gradient)
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 10)
    }

    private func toolIcon(_ tool: String) -> String {
        let l = tool.lowercased()
        if l.contains("bash") || l.contains("shell") { return "terminal.fill" }
        if l.contains("read") { return "doc.text" }
        if l.contains("write") { return "square.and.pencil" }
        if l.contains("edit") { return "pencil" }
        if l.contains("grep") || l.contains("search") { return "magnifyingglass" }
        if l.contains("web") { return "globe" }
        return "wrench.and.screwdriver.fill"
    }

    private func shortNum(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}
