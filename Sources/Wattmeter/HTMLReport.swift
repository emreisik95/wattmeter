import Foundation

/// Deterministic HTML report renderer.
///
/// Given a list of `UsageEntry` and a date range, produces a self-contained HTML
/// document with inline CSS, a sortable summary table, and a per-day inline-SVG
/// bar chart. The output is byte-stable across runs given identical input:
/// - entries are sorted by (timestamp, id) before rendering
/// - all timestamps formatted as ISO-8601 UTC
/// - all numeric formatting uses en_US_POSIX locale
/// - no time-dependent fields (no "generated at" timestamp)
enum HTMLReport {

    // MARK: - Public API

    /// Render a complete HTML document for the given entries and date range.
    /// - Parameters:
    ///   - entries: usage entries to include (will be sorted; original input untouched)
    ///   - range:   inclusive [start, end] reporting window; used in header
    ///   - title:   report title; defaults to "Wattmeter Usage Report"
    static func render(entries: [UsageEntry],
                       range: ClosedRange<Date>,
                       title: String = "Wattmeter Usage Report") -> String {
        let sorted = entries.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id < rhs.id
        }
        let rangeText = "\(isoDay(range.lowerBound)) — \(isoDay(range.upperBound))"
        let totals = computeTotals(sorted)
        let perDay = computePerDay(sorted)

        var html = ""
        html += "<!DOCTYPE html>\n"
        html += "<html lang=\"en\">\n"
        html += "<head>\n"
        html += "<meta charset=\"UTF-8\">\n"
        html += "<title>\(escape(title))</title>\n"
        html += styleBlock()
        html += "</head>\n"
        html += "<body>\n"
        html += "<header>\n"
        html += "  <h1>\(escape(title))</h1>\n"
        html += "  <p class=\"range\">Range: \(escape(rangeText))</p>\n"
        html += "</header>\n"
        html += summarySection(totals)
        html += chartSection(perDay)
        html += tableSection(sorted)
        html += "</body>\n"
        html += "</html>\n"
        return html
    }

    // MARK: - Sections

    private static func summarySection(_ t: Totals) -> String {
        var s = "<section class=\"summary\">\n"
        s += "  <h2>Summary</h2>\n"
        s += "  <ul>\n"
        s += "    <li><span class=\"k\">Entries</span><span class=\"v\">\(formatInt(t.count))</span></li>\n"
        s += "    <li><span class=\"k\">Input tokens</span><span class=\"v\">\(formatInt(t.input))</span></li>\n"
        s += "    <li><span class=\"k\">Output tokens</span><span class=\"v\">\(formatInt(t.output))</span></li>\n"
        s += "    <li><span class=\"k\">Cache write (5m)</span><span class=\"v\">\(formatInt(t.cacheWrite5m))</span></li>\n"
        s += "    <li><span class=\"k\">Cache write (1h)</span><span class=\"v\">\(formatInt(t.cacheWrite1h))</span></li>\n"
        s += "    <li><span class=\"k\">Cache read</span><span class=\"v\">\(formatInt(t.cacheRead))</span></li>\n"
        s += "    <li><span class=\"k\">Total tokens</span><span class=\"v\">\(formatInt(t.totalTokens))</span></li>\n"
        s += "    <li><span class=\"k\">Total cost</span><span class=\"v\">$\(formatUSD(t.cost))</span></li>\n"
        s += "  </ul>\n"
        s += "</section>\n"
        return s
    }

    private static func chartSection(_ days: [DayBucket]) -> String {
        guard !days.isEmpty else {
            return "<section class=\"chart\"><h2>Per-day cost</h2><p>No data.</p></section>\n"
        }
        let width = 800
        let height = 220
        let padLeft = 56
        let padRight = 16
        let padTop = 16
        let padBottom = 40
        let plotW = width - padLeft - padRight
        let plotH = height - padTop - padBottom
        let maxCost = max(days.map { $0.cost }.max() ?? 0.0, 0.0001)
        let n = days.count
        let barW = Double(plotW) / Double(n)

        var svg = "<section class=\"chart\">\n"
        svg += "  <h2>Per-day cost</h2>\n"
        svg += "  <svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(width) \(height)\" role=\"img\" aria-label=\"Per-day cost bar chart\">\n"
        // axes
        svg += "    <line x1=\"\(padLeft)\" y1=\"\(padTop)\" x2=\"\(padLeft)\" y2=\"\(padTop + plotH)\" stroke=\"#888\" stroke-width=\"1\"/>\n"
        svg += "    <line x1=\"\(padLeft)\" y1=\"\(padTop + plotH)\" x2=\"\(padLeft + plotW)\" y2=\"\(padTop + plotH)\" stroke=\"#888\" stroke-width=\"1\"/>\n"
        // y-axis labels (max + mid + 0)
        svg += "    <text x=\"\(padLeft - 6)\" y=\"\(padTop + 4)\" text-anchor=\"end\" font-size=\"10\" fill=\"#555\">$\(formatUSD(maxCost))</text>\n"
        svg += "    <text x=\"\(padLeft - 6)\" y=\"\(padTop + plotH / 2 + 3)\" text-anchor=\"end\" font-size=\"10\" fill=\"#555\">$\(formatUSD(maxCost / 2.0))</text>\n"
        svg += "    <text x=\"\(padLeft - 6)\" y=\"\(padTop + plotH + 3)\" text-anchor=\"end\" font-size=\"10\" fill=\"#555\">$0.00</text>\n"
        // bars
        for (i, d) in days.enumerated() {
            let h = (d.cost / maxCost) * Double(plotH)
            let x = Double(padLeft) + Double(i) * barW + 1.0
            let y = Double(padTop + plotH) - h
            let w = max(barW - 2.0, 1.0)
            svg += "    <rect x=\"\(fmtCoord(x))\" y=\"\(fmtCoord(y))\" width=\"\(fmtCoord(w))\" height=\"\(fmtCoord(h))\" fill=\"#3b82f6\"><title>\(escape(d.day)): $\(formatUSD(d.cost))</title></rect>\n"
        }
        // x-axis day labels (every Nth so they don't overlap)
        let step = max(1, n / 8)
        for i in stride(from: 0, to: n, by: step) {
            let cx = Double(padLeft) + Double(i) * barW + barW / 2.0
            let y = Double(padTop + plotH) + 14.0
            svg += "    <text x=\"\(fmtCoord(cx))\" y=\"\(fmtCoord(y))\" text-anchor=\"middle\" font-size=\"10\" fill=\"#555\">\(escape(days[i].day))</text>\n"
        }
        svg += "  </svg>\n"
        svg += "</section>\n"
        return svg
    }

    private static func tableSection(_ entries: [UsageEntry]) -> String {
        var s = "<section class=\"entries\">\n"
        s += "  <h2>Entries (\(formatInt(entries.count)))</h2>\n"
        s += "  <table id=\"entries\">\n"
        s += "    <thead><tr>"
        s += "<th data-col=\"0\">Timestamp (UTC)</th>"
        s += "<th data-col=\"1\">Provider</th>"
        s += "<th data-col=\"2\">Model</th>"
        s += "<th data-col=\"3\">Project</th>"
        s += "<th data-col=\"4\">Session</th>"
        s += "<th data-col=\"5\" class=\"num\">Input</th>"
        s += "<th data-col=\"6\" class=\"num\">Output</th>"
        s += "<th data-col=\"7\" class=\"num\">CW5m</th>"
        s += "<th data-col=\"8\" class=\"num\">CW1h</th>"
        s += "<th data-col=\"9\" class=\"num\">CR</th>"
        s += "<th data-col=\"10\" class=\"num\">Tokens</th>"
        s += "<th data-col=\"11\" class=\"num\">Cost USD</th>"
        s += "</tr></thead>\n"
        s += "    <tbody>\n"
        for e in entries {
            s += "      <tr>"
            s += "<td>\(escape(isoTimestamp(e.timestamp)))</td>"
            s += "<td>\(escape(e.providerOrClaude))</td>"
            s += "<td>\(escape(e.model))</td>"
            s += "<td>\(escape(e.project))</td>"
            s += "<td>\(escape(e.sessionId))</td>"
            s += "<td class=\"num\">\(formatInt(e.inputTokens))</td>"
            s += "<td class=\"num\">\(formatInt(e.outputTokens))</td>"
            s += "<td class=\"num\">\(formatInt(e.cacheWrite5m))</td>"
            s += "<td class=\"num\">\(formatInt(e.cacheWrite1h))</td>"
            s += "<td class=\"num\">\(formatInt(e.cacheRead))</td>"
            s += "<td class=\"num\">\(formatInt(e.totalTokens))</td>"
            s += "<td class=\"num\">\(formatUSD(e.cost))</td>"
            s += "</tr>\n"
        }
        s += "    </tbody>\n"
        s += "  </table>\n"
        s += sortScript()
        s += "</section>\n"
        return s
    }

    private static func styleBlock() -> String {
        var css = "<style>\n"
        css += "body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#222;margin:24px;background:#fff;}\n"
        css += "header h1{margin:0 0 4px 0;font-size:22px;}\n"
        css += "header .range{margin:0;color:#666;font-size:13px;}\n"
        css += "section{margin-top:28px;}\n"
        css += "section h2{font-size:16px;margin:0 0 12px 0;color:#333;border-bottom:1px solid #eee;padding-bottom:4px;}\n"
        css += ".summary ul{list-style:none;padding:0;margin:0;display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:8px;}\n"
        css += ".summary li{background:#f7f7f9;border-radius:6px;padding:8px 10px;display:flex;justify-content:space-between;font-size:13px;}\n"
        css += ".summary .k{color:#666;}\n"
        css += ".summary .v{font-weight:600;color:#111;}\n"
        css += ".chart svg{max-width:100%;height:auto;display:block;}\n"
        css += "table{width:100%;border-collapse:collapse;font-size:12px;}\n"
        css += "th,td{padding:4px 8px;border-bottom:1px solid #eee;text-align:left;vertical-align:top;}\n"
        css += "th{background:#fafafa;cursor:pointer;user-select:none;position:sticky;top:0;}\n"
        css += "th:hover{background:#f0f0f0;}\n"
        css += "td.num,th.num{text-align:right;font-variant-numeric:tabular-nums;}\n"
        css += "tbody tr:nth-child(even){background:#fcfcfd;}\n"
        css += "</style>\n"
        return css
    }

    private static func sortScript() -> String {
        // Lightweight client-side column sort. Deterministic: no data baked in.
        var js = "<script>\n"
        js += "(function(){\n"
        js += "  var table=document.getElementById('entries'); if(!table)return;\n"
        js += "  var ths=table.querySelectorAll('th'); var dir=1; var last=-1;\n"
        js += "  ths.forEach(function(th){ th.addEventListener('click', function(){\n"
        js += "    var col=parseInt(th.getAttribute('data-col'),10);\n"
        js += "    if(col===last){dir=-dir;}else{dir=1;last=col;}\n"
        js += "    var tbody=table.tBodies[0]; var rows=Array.prototype.slice.call(tbody.rows);\n"
        js += "    var isNum=th.classList.contains('num');\n"
        js += "    rows.sort(function(a,b){\n"
        js += "      var x=a.cells[col].textContent.trim(); var y=b.cells[col].textContent.trim();\n"
        js += "      if(isNum){ var xn=parseFloat(x.replace(/,/g,''))||0; var yn=parseFloat(y.replace(/,/g,''))||0; return (xn-yn)*dir; }\n"
        js += "      return x.localeCompare(y)*dir;\n"
        js += "    });\n"
        js += "    rows.forEach(function(r){tbody.appendChild(r);});\n"
        js += "  });});\n"
        js += "})();\n"
        js += "</script>\n"
        return js
    }

    // MARK: - Aggregation

    private struct Totals {
        var count: Int = 0
        var input: Int = 0
        var output: Int = 0
        var cacheWrite5m: Int = 0
        var cacheWrite1h: Int = 0
        var cacheRead: Int = 0
        var cost: Double = 0
        var totalTokens: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }
    }

    private static func computeTotals(_ entries: [UsageEntry]) -> Totals {
        var t = Totals()
        t.count = entries.count
        for e in entries {
            t.input += e.inputTokens
            t.output += e.outputTokens
            t.cacheWrite5m += e.cacheWrite5m
            t.cacheWrite1h += e.cacheWrite1h
            t.cacheRead += e.cacheRead
            t.cost += e.cost
        }
        return t
    }

    private struct DayBucket {
        let day: String   // YYYY-MM-DD UTC
        let cost: Double
    }

    private static func computePerDay(_ entries: [UsageEntry]) -> [DayBucket] {
        var map: [String: Double] = [:]
        for e in entries {
            let key = isoDay(e.timestamp)
            map[key, default: 0.0] += e.cost
        }
        return map.keys.sorted().map { DayBucket(day: $0, cost: map[$0] ?? 0) }
    }

    // MARK: - Formatting helpers (locale-stable)

    private static let posix: Locale = Locale(identifier: "en_US_POSIX")

    private static let isoDayFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withFullDate]
        return f
    }()

    private static let isoTsFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func isoDay(_ d: Date) -> String {
        isoDayFormatter.string(from: d)
    }

    private static func isoTimestamp(_ d: Date) -> String {
        isoTsFormatter.string(from: d)
    }

    private static func formatInt(_ n: Int) -> String {
        let nf = NumberFormatter()
        nf.locale = posix
        nf.numberStyle = .decimal
        nf.usesGroupingSeparator = true
        nf.groupingSeparator = ","
        return nf.string(from: NSNumber(value: n)) ?? String(n)
    }

    private static func formatUSD(_ v: Double) -> String {
        // Locale-stable, 2-decimal money formatting (no currency symbol; caller prefixes "$").
        return String(format: "%.2f", locale: posix, v)
    }

    private static func fmtCoord(_ v: Double) -> String {
        // 3-decimal stable formatting for SVG numeric attributes.
        return String(format: "%.3f", locale: posix, v)
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&#39;")
            default: out.append(ch)
            }
        }
        return out
    }
}
