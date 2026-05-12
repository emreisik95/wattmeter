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

    // MARK: - F2 Tool attribution hook integration

    enum HookInstallResult: Equatable { case installed, alreadyInstalled, scriptCopyFailed, patchFailed }
    enum HookRemoveResult: Equatable { case removed, notInstalled, settingsMissing, patchFailed }

    /// Path on disk where the bundled `log_tool.sh` wrapper is copied. Lives in `~/.claude/wattmeter/`
    /// so that the hook command remains stable across app updates and the JSON marker for
    /// idempotent install/uninstall is the wrapper-script path itself.
    nonisolated static var hookWrapperURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/wattmeter/log_tool.sh")
    }

    /// Expanded marker prefix used to identify Wattmeter-owned hook entries.
    /// An entry is OURS iff its `command` STARTS WITH this expanded path.
    nonisolated static var hookMarkerPrefix: String { hookWrapperURL.path }

    /// Install the bundled wrapper script under `~/.claude/wattmeter/log_tool.sh`, then merge
    /// `PreToolUse` / `PostToolUse` hooks into `~/.claude/settings.json`. Existing hooks (with
    /// other markers) are preserved. Idempotent: a second call is a no-op.
    @discardableResult
    func installToolHooks(bundledScriptURL: URL? = nil) -> HookInstallResult {
        let wrapper = Self.hookWrapperURL
        let source = bundledScriptURL ?? Self.defaultBundledScriptURL()
        // 1. Copy wrapper script.
        if !Self.copyHookWrapper(from: source, to: wrapper) {
            return .scriptCopyFailed
        }
        // 2. Merge into settings.json.
        return Self.mergeToolHooks(settingsURL: Self.settingsURL, wrapperPath: wrapper.path)
    }

    /// Remove ALL hook entries whose `command` starts with our wrapper-script marker prefix.
    /// Does not delete the wrapper script itself (cheap, harmless to leave on disk).
    @discardableResult
    func removeToolHooks() -> HookRemoveResult {
        Self.filterToolHooks(settingsURL: Self.settingsURL, markerPrefix: Self.hookMarkerPrefix)
    }

    // MARK: - Hook install/remove implementation (static so it's unit-testable)

    /// Test seam: pass the path to the bundled `log_tool.sh` (defaults to `Bundle.module` lookup
    /// when SwiftPM resources are available, falling back to a sibling Resources/ directory).
    nonisolated static func defaultBundledScriptURL() -> URL? {
        // SPM resource bundle (when available — requires .process in Package.swift, which we
        // intentionally don't set so this stays portable across binary distributions).
        // Fall through to repo-local Resources/ lookup so dev/test still finds the file.
        let candidates: [URL] = [
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()        // Sources/Wattmeter
                .deletingLastPathComponent()        // Sources
                .deletingLastPathComponent()        // repo root
                .appendingPathComponent("Resources/log_tool.sh"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/log_tool.sh")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    nonisolated static func copyHookWrapper(from source: URL?, to dest: URL) -> Bool {
        let fm = FileManager.default
        let dir = dest.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let source else {
            // No bundled source — last resort: synthesize a minimal wrapper inline so the
            // installer doesn't silently fail in environments where the resource isn't shipped.
            let inline = Self.inlineWrapperScript
            do {
                try inline.write(to: dest, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
                return true
            } catch {
                return false
            }
        }
        guard let data = try? Data(contentsOf: source) else { return false }
        do {
            try data.write(to: dest, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            return true
        } catch {
            return false
        }
    }

    /// Merge our PreToolUse + PostToolUse entries into `settings.json` at `settingsURL`.
    /// Atomic write. Preserves all unrelated keys and all third-party hook entries.
    nonisolated static func mergeToolHooks(settingsURL: URL, wrapperPath: String) -> HookInstallResult {
        let fm = FileManager.default
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            obj = parsed
        }
        var hooks = obj["hooks"] as? [String: Any] ?? [:]

        // Build our group entry (matcher: "*", hooks: [{type:"command", command:"<wrapper> <phase>"}])
        func ourEntry(phase: String) -> [String: Any] {
            return [
                "matcher": "*",
                "hooks": [[
                    "type": "command",
                    "command": "\(wrapperPath) \(phase)"
                ] as [String: Any]]
            ]
        }

        var changed = false
        for (key, phase) in [("PreToolUse", "pre"), ("PostToolUse", "post")] {
            var arr = hooks[key] as? [Any] ?? []
            let alreadyHasOurs = arr.contains { item in
                guard let dict = item as? [String: Any],
                      let inner = dict["hooks"] as? [Any] else { return false }
                return inner.contains { h in
                    guard let hd = h as? [String: Any],
                          let cmd = hd["command"] as? String else { return false }
                    return cmd.hasPrefix(wrapperPath)
                }
            }
            if !alreadyHasOurs {
                arr.append(ourEntry(phase: phase))
                hooks[key] = arr
                changed = true
            }
        }

        if !changed {
            return .alreadyInstalled
        }
        obj["hooks"] = hooks

        // Atomic write: write to tmp then rename.
        let dir = settingsURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Backup existing.
        if fm.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.appendingPathExtension("bak.\(Int(Date().timeIntervalSince1970))")
            try? fm.copyItem(at: settingsURL, to: backup)
        }
        guard let out = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        ) else { return .patchFailed }

        let tmp = settingsURL.appendingPathExtension("tmp.\(UUID().uuidString)")
        do {
            try out.write(to: tmp, options: .atomic)
            // Atomic rename. Use replaceItemAt so it works even if target exists.
            _ = try fm.replaceItemAt(settingsURL, withItemAt: tmp)
            return .installed
        } catch {
            try? fm.removeItem(at: tmp)
            return .patchFailed
        }
    }

    /// Remove all hook entries whose inner command starts with `markerPrefix`.
    /// If after filtering an outer entry has no remaining inner hooks, the outer entry itself
    /// is dropped. Removes empty arrays (and the `hooks` key if it becomes empty).
    nonisolated static func filterToolHooks(settingsURL: URL, markerPrefix: String) -> HookRemoveResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path) else { return .settingsMissing }
        guard let data = try? Data(contentsOf: settingsURL),
              var obj = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return .patchFailed
        }
        guard var hooks = obj["hooks"] as? [String: Any] else { return .notInstalled }

        var changed = false
        for key in ["PreToolUse", "PostToolUse"] {
            guard let arr = hooks[key] as? [Any] else { continue }
            var filtered: [Any] = []
            filtered.reserveCapacity(arr.count)
            for item in arr {
                guard let dict = item as? [String: Any] else {
                    filtered.append(item)
                    continue
                }
                if let inner = dict["hooks"] as? [Any] {
                    let keptInner = inner.filter { h in
                        guard let hd = h as? [String: Any],
                              let cmd = hd["command"] as? String else { return true }
                        return !cmd.hasPrefix(markerPrefix)
                    }
                    if keptInner.count == inner.count {
                        filtered.append(item)
                    } else if !keptInner.isEmpty {
                        var copy = dict
                        copy["hooks"] = keptInner
                        filtered.append(copy)
                        changed = true
                    } else {
                        // entirely ours — drop
                        changed = true
                    }
                } else {
                    filtered.append(item)
                }
            }
            if filtered.isEmpty {
                hooks.removeValue(forKey: key)
                if !arr.isEmpty { changed = true }
            } else {
                hooks[key] = filtered
            }
        }

        if !changed { return .notInstalled }
        if hooks.isEmpty {
            obj.removeValue(forKey: "hooks")
        } else {
            obj["hooks"] = hooks
        }

        guard let out = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        ) else { return .patchFailed }
        let tmp = settingsURL.appendingPathExtension("tmp.\(UUID().uuidString)")
        do {
            try out.write(to: tmp, options: .atomic)
            _ = try fm.replaceItemAt(settingsURL, withItemAt: tmp)
            return .removed
        } catch {
            try? fm.removeItem(at: tmp)
            return .patchFailed
        }
    }

    /// Minimal fallback wrapper used only when no `Resources/log_tool.sh` is found. Kept in sync
    /// with `Resources/log_tool.sh`.
    nonisolated private static let inlineWrapperScript: String = """
    #!/bin/sh
    phase="${1:-unknown}"
    out="$HOME/.claude/wattmeter_tools.jsonl"
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    payload=$(cat 2>/dev/null || printf '')
    mkdir -p "$HOME/.claude" 2>/dev/null || exit 0
    tool=""
    if command -v jq >/dev/null 2>&1; then
        tool=$(printf '%s' "$payload" | jq -rc '.tool_name // .tool // empty' 2>/dev/null || printf '')
    fi
    esc_payload=$(printf '%s' "$payload" | tr -d '\\n\\r' | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g')
    esc_tool=$(printf '%s' "$tool" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g')
    printf '{"ts":"%s","phase":"%s","tool":"%s","raw":"%s"}\\n' \\
        "$ts" "$phase" "$esc_tool" "$esc_payload" >> "$out" 2>/dev/null
    exit 0
    """

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
