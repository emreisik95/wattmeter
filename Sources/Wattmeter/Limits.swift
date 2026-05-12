import Foundation
import SwiftUI

// MARK: - Snapshot from statusline JSON

struct RateLimitsSnapshot: Decodable {
    struct Bucket: Decodable {
        let used_percentage: Double?
        let resets_at: Double?
    }
    struct Limits: Decodable {
        let five_hour: Bucket?
        let seven_day: Bucket?
    }
    struct Ctx: Decodable {
        let used_percentage: Double?
    }
    let rate_limits: Limits?
    let context_window: Ctx?
}

enum LimitKind: String, CaseIterable, Identifiable {
    case fiveHour
    case weekly
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveHour: return "5-hour"
        case .weekly:   return "Weekly (7d)"
        }
    }

    var icon: String {
        switch self {
        case .fiveHour: return "clock.fill"
        case .weekly:   return "calendar"
        }
    }
}

struct LiveLimit {
    let kind: LimitKind
    let percentage: Double   // 0-100
    let resetsAt: Date?

    var fraction: Double { min(1.0, max(0, percentage / 100.0)) }
    var exceeded: Bool { percentage >= 100 }
    var nearing: Bool { percentage >= 80 && !exceeded }
    var hasData: Bool { percentage > 0 || resetsAt != nil }
}

// MARK: - Store

enum PercentStyle: String, CaseIterable, Identifiable {
    case suffix   // "18%"
    case prefix   // "%18"
    var id: String { rawValue }
    var sample: String {
        switch self {
        case .suffix: return "18%"
        case .prefix: return "%18"
        }
    }
    var title: String {
        switch self {
        case .suffix: return "18% (suffix)"
        case .prefix: return "%18 (prefix)"
        }
    }
    func format(_ v: Double) -> String {
        let n = Int(v.rounded())
        switch self {
        case .suffix: return "\(n)%"
        case .prefix: return "%\(n)"
        }
    }
}

@MainActor
final class LimitsConfig: ObservableObject {
    @Published private(set) var snapshot: RateLimitsSnapshot?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var fileMissing: Bool = true
    private var lastFingerprint: String = ""
    private var lastMtime: Date?
    @Published var percentStyle: PercentStyle {
        didSet { UserDefaults.standard.set(percentStyle.rawValue, forKey: "limits.percentStyle") }
    }
    private var timer: Timer?

    static var ratelimitsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/rate_limits.json")
    }

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: "limits.percentStyle") ?? PercentStyle.prefix.rawValue
        self.percentStyle = PercentStyle(rawValue: raw) ?? .prefix
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
    }

    deinit { timer?.invalidate() }

    func load() {
        let url = Self.ratelimitsURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            if !fileMissing { fileMissing = true }
            return
        }
        // mtime gate — skip read if unchanged
        let mtime = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let mtime, mtime == lastMtime { return }
        lastMtime = mtime
        if fileMissing { fileMissing = false }
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(RateLimitsSnapshot.self, from: data) else { return }
        // content fingerprint — only publish on actual change
        let fp = "\(s.rate_limits?.five_hour?.used_percentage ?? -1)|\(s.rate_limits?.five_hour?.resets_at ?? -1)|\(s.rate_limits?.seven_day?.used_percentage ?? -1)|\(s.rate_limits?.seven_day?.resets_at ?? -1)|\(s.context_window?.used_percentage ?? -1)"
        if fp == lastFingerprint { return }
        lastFingerprint = fp
        snapshot = s
        if let mtime { lastUpdated = mtime }
    }

    var isConnected: Bool { snapshot != nil }

    func live(_ kind: LimitKind) -> LiveLimit {
        let b: RateLimitsSnapshot.Bucket?
        switch kind {
        case .fiveHour: b = snapshot?.rate_limits?.five_hour
        case .weekly:   b = snapshot?.rate_limits?.seven_day
        }
        return LiveLimit(
            kind: kind,
            percentage: b?.used_percentage ?? 0,
            resetsAt: b?.resets_at.map { Date(timeIntervalSince1970: $0) }
        )
    }

    var contextPercentage: Double {
        snapshot?.context_window?.used_percentage ?? 0
    }

    // MARK: Integration installer

    enum InstallResult { case installed, alreadyInstalled, settingsMissing, noStatusLine, patchFailed }

    private static let teeShell: String = #"mkdir -p "$HOME/.claude" >/dev/null 2>&1; printf %s "$input" > "$HOME/.claude/rate_limits.json"; "#

    private static let defaultStatusLineCommand: String =
        #"input=$(cat); "# + teeShell +
        #"five=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty'); week=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty'); ctx=$(echo "$input" | jq -r '.context_window.used_percentage // empty'); out=""; [ -n "$five" ] && out="5h:$(printf '%.0f' "$five")%"; [ -n "$week" ] && out="${out:+$out }7d:$(printf '%.0f' "$week")%"; [ -n "$ctx" ] && out="${out:+$out }ctx:$(printf '%.0f' "$ctx")%"; echo "$out""#

    @discardableResult
    func installStatusLineIntegration() -> InstallResult {
        let url = Self.settingsURL

        // 1. Try in-place text injection (preserves key order) when current command has the standard marker.
        if let raw = try? String(contentsOf: url, encoding: .utf8) {
            if raw.contains("rate_limits.json") {
                return .alreadyInstalled
            }
            // The marker appears inside a JSON string, so $ and quote stay literal in the text.
            let markerJSON = #"input=$(cat); "#
            if raw.range(of: markerJSON) != nil {
                // Inside JSON the double-quotes are escaped as \". Build escaped tee snippet.
                let escapedTee = #"mkdir -p \"$HOME/.claude\" >/dev/null 2>&1; printf %s \"$input\" > \"$HOME/.claude/rate_limits.json\"; "#
                let patched = raw.replacingOccurrences(of: markerJSON, with: markerJSON + escapedTee)
                if backupAndWrite(url: url, content: patched) { return .installed }
                return .patchFailed
            }
        }

        // 2. Fall back to JSON-structural edit: handles missing file, missing statusLine, custom command.
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            obj = parsed
        }
        var sl = obj["statusLine"] as? [String: Any] ?? [:]
        var cmd = (sl["command"] as? String) ?? ""

        if cmd.contains("rate_limits.json") {
            return .alreadyInstalled
        }

        if cmd.isEmpty {
            cmd = Self.defaultStatusLineCommand
        } else if cmd.hasPrefix("input=$(cat); ") {
            cmd = "input=$(cat); " + Self.teeShell + cmd.dropFirst("input=$(cat); ".count)
        } else if cmd.contains("input=$(cat)") {
            cmd = cmd.replacingOccurrences(
                of: "input=$(cat)",
                with: "input=$(cat); " + Self.teeShell.trimmingCharacters(in: .whitespaces) + " #"
            )
            // Above is risky — safer: wrap entire command.
            cmd = "input=$(cat); " + Self.teeShell + cmd
        } else {
            // Unknown shape: wrap so existing logic still runs after the tee.
            cmd = "input=$(cat); " + Self.teeShell + cmd
        }

        sl["command"] = cmd
        if sl["type"] == nil { sl["type"] = "command" }
        obj["statusLine"] = sl

        guard let data = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        ) else {
            return .patchFailed
        }
        guard let text = String(data: data, encoding: .utf8) else { return .patchFailed }

        if backupAndWrite(url: url, content: text) { return .installed }
        return .patchFailed
    }

    private func backupAndWrite(url: URL, content: String) -> Bool {
        let fm = FileManager.default
        // ensure parent dir
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak.\(Int(Date().timeIntervalSince1970))")
            try? fm.copyItem(at: url, to: backup)
        }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    enum RemoveResult { case removed, notInstalled, settingsMissing, patchFailed }

    @discardableResult
    func removeStatusLineIntegration() -> RemoveResult {
        let url = Self.settingsURL
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return .settingsMissing
        }
        let inject = #"mkdir -p \"$HOME/.claude\" >/dev/null 2>&1; printf %s \"$input\" > \"$HOME/.claude/rate_limits.json\"; "#
        guard raw.contains(inject) else {
            return .notInstalled
        }
        let cleaned = raw.replacingOccurrences(of: inject, with: "")
        do {
            try cleaned.write(to: url, atomically: true, encoding: .utf8)
            return .removed
        } catch {
            return .patchFailed
        }
    }
}
