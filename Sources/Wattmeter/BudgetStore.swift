import Foundation

/// Persists `[Budget]` to
/// `~/Library/Application Support/Wattmeter/budgets.plist`
/// using atomic writes. No webhook URLs are persisted here — only
/// `webhookKeychainRef` strings; raw URLs live in Keychain.
@MainActor
final class BudgetStore: ObservableObject {
    @Published private(set) var budgets: [Budget] = []

    static let plistURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Wattmeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("budgets.plist")
    }()

    init(autoload: Bool = true) {
        if autoload { load() }
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.plistURL) else {
            budgets = []
            return
        }
        let decoder = PropertyListDecoder()
        if let decoded = try? decoder.decode([Budget].self, from: data) {
            budgets = decoded
        } else {
            budgets = []
        }
    }

    func save() {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        guard let data = try? encoder.encode(budgets) else { return }
        // Atomic write: temp file + rename
        let tmp = Self.plistURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(Self.plistURL, withItemAt: tmp)
        } catch {
            // Best-effort fallback
            try? data.write(to: Self.plistURL, options: .atomic)
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    // MARK: - CRUD

    func add(_ b: Budget) {
        budgets.append(b)
        save()
    }

    func update(_ b: Budget) {
        if let i = budgets.firstIndex(where: { $0.id == b.id }) {
            budgets[i] = b
            save()
        }
    }

    func remove(id: UUID) {
        if let b = budgets.first(where: { $0.id == id }),
           let ref = b.webhookKeychainRef {
            KeychainWebhookStore.delete(ref: ref)
        }
        budgets.removeAll { $0.id == id }
        save()
    }

    func replaceAll(_ new: [Budget]) {
        budgets = new
        save()
    }
}
