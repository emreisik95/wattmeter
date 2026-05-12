import Foundation
import AppKit
import UniformTypeIdentifiers

enum Export {
    static func csv(entries: [UsageEntry]) -> String {
        var s = "timestamp,model,project,session,input,output,cache_write_5m,cache_write_1h,cache_read,total_tokens,cost\n"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        for e in entries {
            let ts = iso.string(from: e.timestamp)
            let model = quoted(e.model)
            let proj  = quoted(e.project)
            let sess  = quoted(e.sessionId)
            s += "\(ts),\(model),\(proj),\(sess),\(e.inputTokens),\(e.outputTokens),\(e.cacheWrite5m),\(e.cacheWrite1h),\(e.cacheRead),\(e.totalTokens),\(String(format: "%.6f", e.cost))\n"
        }
        return s
    }

    private static func quoted(_ v: String) -> String {
        if v.contains(",") || v.contains("\"") || v.contains("\n") {
            let escaped = v.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return v
    }

    @MainActor
    static func saveCSV(entries: [UsageEntry], suggestedName: String = "claude-usage.csv") {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = csv(entries: entries)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Save an HTML report to a user-chosen location.
    /// Uses `HTMLReport.render` with the inclusive date range derived from `entries`.
    @MainActor
    static func saveHTML(entries: [UsageEntry], suggestedName: String = "claude-usage.html") {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let range = dateRange(entries)
        let html = HTMLReport.render(entries: entries, range: range)
        try? html.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Save a PDF report. Renders the same HTML report then prints it to PDF
    /// via an off-screen WKWebView.
    @MainActor
    static func savePDF(entries: [UsageEntry], suggestedName: String = "claude-usage.pdf") {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let range = dateRange(entries)
        let html = HTMLReport.render(entries: entries, range: range)
        Task { @MainActor in
            do {
                let data = try await PDFExporter.renderPDF(html: html)
                try data.write(to: url, options: [.atomic])
            } catch {
                NSLog("[Export] PDF export failed: \(error)")
            }
        }
    }

    private static func dateRange(_ entries: [UsageEntry]) -> ClosedRange<Date> {
        guard let first = entries.map(\.timestamp).min(),
              let last  = entries.map(\.timestamp).max(),
              first <= last else {
            let now = Date()
            return now...now
        }
        return first...last
    }
}
