import SwiftUI

/// Colored dot + tooltip showing the current Anthropic service status.
/// Consumed by the dashboard header (and, at integration time, optionally by the menu bar tray).
struct ServiceStatusBadge: View {
    @EnvironmentObject var monitor: ServiceStatusMonitor

    var showLabel: Bool = false

    var body: some View {
        let s = monitor.current
        HStack(spacing: 5) {
            Circle()
                .fill(color(for: s.indicator))
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                )
            if showLabel {
                Text(label(for: s.indicator))
                    .font(.caption2).bold().monospacedDigit()
                    .foregroundStyle(color(for: s.indicator))
            }
        }
        .help(tooltip(for: s))
    }

    private func color(for ind: ServiceStatus.Indicator) -> Color {
        switch ind {
        case .none:        return .green
        case .minor:       return .yellow
        case .major:       return .orange
        case .critical:    return .red
        case .maintenance: return .blue
        }
    }

    private func label(for ind: ServiceStatus.Indicator) -> String {
        switch ind {
        case .none:        return "OK"
        case .minor:       return "Minor"
        case .major:       return "Major"
        case .critical:    return "Down"
        case .maintenance: return "Maint"
        }
    }

    private func tooltip(for s: ServiceStatus) -> String {
        let head: String
        switch s.indicator {
        case .none:        head = "Anthropic services: all systems normal"
        case .minor:       head = "Anthropic services: minor incident"
        case .major:       head = "Anthropic services: major incident"
        case .critical:    head = "Anthropic services: critical outage"
        case .maintenance: head = "Anthropic services: scheduled maintenance"
        }
        if s.description.isEmpty {
            return head
        }
        return "\(head)\n\(s.description)"
    }
}
