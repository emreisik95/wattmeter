import SwiftUI

/// Full Insights tab: "Today's Standup" expanded with peak-hour, top model, top project.
struct InsightsView: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        let s = Insights.standup(store.entries)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                StandupCard(standup: s, compact: false)

                if s.requestCountToday == 0 {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "tray")
                                .font(.title2).foregroundStyle(.tertiary)
                            Text("No activity today yet.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(40)
                }

                // Hour-of-day bar (peak visualised)
                if let peak = s.peakHour {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Peak hour (7d)", systemImage: "clock.fill")
                            .font(.caption).bold().foregroundStyle(.secondary)
                        Text("\(Insights.formatHour(peak)) — $\(String(format: "%.2f", s.peakHourCost))")
                            .font(.title3).bold().monospacedDigit()
                            .foregroundStyle(Theme.accent)
                        Text("Across the past 7 days, this hour-of-day had the highest spend.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(14)
        }
    }
}

/// Compact card used both inside InsightsView and at top of the overview tab.
struct StandupCard: View {
    let standup: Insights.Standup
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sun.max.fill").foregroundStyle(Theme.accent)
                Text("Today's standup").font(.headline)
                Spacer()
                deltaPill
            }

            HStack(spacing: 12) {
                metric(title: "Today", value: dollars(standup.todayCost), accent: true)
                metric(title: "Yesterday", value: dollars(standup.yesterdayCost), accent: false)
                metric(title: "Requests", value: "\(standup.requestCountToday)", accent: false)
            }

            if !compact {
                Divider().padding(.vertical, 2)
                detailGrid
            } else {
                compactRow
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var deltaPill: some View {
        if let pct = standup.deltaPercent {
            let up = pct >= 0
            let color: Color = up ? .orange : .green
            HStack(spacing: 3) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right").font(.caption2)
                Text(String(format: "%@%.0f%%", up ? "+" : "", pct))
                    .font(.caption2).bold().monospacedDigit()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
        } else if standup.todayCost > 0 {
            Text("new")
                .font(.caption2).bold()
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Theme.accent.opacity(0.15), in: Capsule())
                .foregroundStyle(Theme.accent)
        } else {
            EmptyView()
        }
    }

    private var detailGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow(icon: "clock.fill", title: "Peak hour",
                      value: standup.peakHour.map { "\(Insights.formatHour($0))  ·  $\(String(format: "%.2f", standup.peakHourCost))" } ?? "—")
            detailRow(icon: "cpu", title: "Top model",
                      value: standup.topModel.map { "\($0)  ·  $\(String(format: "%.2f", standup.topModelCost))" } ?? "—")
            detailRow(icon: "folder.fill", title: "Top project",
                      value: standup.topProject.map { "\($0)  ·  $\(String(format: "%.2f", standup.topProjectCost))" } ?? "—")
        }
    }

    private var compactRow: some View {
        HStack(spacing: 12) {
            if let h = standup.peakHour {
                Label(Insights.formatHour(h), systemImage: "clock.fill")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let m = standup.topModel {
                Label(m, systemImage: "cpu")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if let p = standup.topProject {
                Label(p, systemImage: "folder.fill")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func detailRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).bold().monospacedDigit().lineLimit(1).truncationMode(.middle)
        }
    }

    private func metric(title: String, value: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3).bold().monospacedDigit()
                .foregroundStyle(accent ? Theme.accent : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dollars(_ v: Double) -> String { String(format: "$%.2f", v) }
}
