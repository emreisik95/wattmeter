import Foundation

// Extension to the FrozenAPI ProfileManager: persistence + auto-discovery.
// The base class lives in FrozenAPI.swift; we add behavior here.

extension ProfileManager {

    private static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Wattmeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.json")
    }

    /// Codable wrapper for on-disk storage.
    private struct Persisted: Codable {
        let profiles: [UsageProfile]
        let activeID: UUID?
    }

    /// Load from disk; if missing or empty, auto-discover from ~/.claude and ~/.codex/sessions.
    /// Safe to call multiple times. Idempotent.
    func bootstrap() {
        if loadFromDisk() {
            return
        }
        autoDiscover()
        save()
    }

    @discardableResult
    func loadFromDisk() -> Bool {
        let url = Self.storeURL
        guard let data = try? Data(contentsOf: url) else { return false }
        guard let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return false }
        guard !p.profiles.isEmpty else { return false }
        self.profiles = p.profiles
        self.activeID = p.activeID ?? p.profiles.first?.id
        return true
    }

    func save() {
        let url = Self.storeURL
        let p = Persisted(profiles: profiles, activeID: activeID)
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Scan known directories and pre-populate with whatever profiles look usable.
    func autoDiscover() {
        var found: [UsageProfile] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeDir = home.appendingPathComponent(".claude")
        if FileManager.default.fileExists(atPath: claudeDir.path) {
            found.append(UsageProfile(label: "Claude (default)", claudeDir: claudeDir))
        }
        // Codex sessions live under ~/.codex/sessions/*.jsonl. We don't yet *consume* them
        // from this view, but registering as a profile lets the lead wire it to providers later.
        let codexDir = home.appendingPathComponent(".codex/sessions")
        if FileManager.default.fileExists(atPath: codexDir.path) {
            found.append(UsageProfile(label: "Codex sessions", claudeDir: codexDir))
        }
        if found.isEmpty {
            // No directories detected — still register the default ~/.claude so the user
            // sees *something*; activeClaudeDir already falls back to ~/.claude anyway.
            found.append(UsageProfile(label: "Claude (default)", claudeDir: claudeDir))
        }
        self.profiles = found
        self.activeID = found.first?.id
    }

    /// Add a profile + persist.
    func addAndSave(label: String, claudeDir: URL) {
        let p = UsageProfile(label: label, claudeDir: claudeDir)
        profiles.append(p)
        if activeID == nil { activeID = p.id }
        save()
    }

    /// Update an existing profile (label and/or dir) + persist.
    func update(_ id: UUID, label: String? = nil, claudeDir: URL? = nil) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        var p = profiles[idx]
        if let label { p.label = label }
        if let claudeDir { p.claudeDir = claudeDir }
        profiles[idx] = p
        save()
    }

    /// Remove a profile + persist.
    func removeAndSave(_ id: UUID) {
        remove(id)
        save()
    }

    /// Switch active and persist.
    func setActiveAndSave(_ id: UUID) {
        setActive(id)
        save()
    }
}
