import Foundation

/// Pricing JSON document — both the bundled seed and the GitHub-raw mirror
/// share this shape.
struct PricingDocument: Codable, Equatable {
    let version: Int
    let updated: String?
    let models: [String: PricingDocumentRow]

    struct PricingDocumentRow: Codable, Equatable, Hashable {
        let inputPerMTok: Double
        let outputPerMTok: Double
    }

    /// Flat conversion: `[PriceRow]` ready for `PricingTable.shared.setTable`.
    var rows: [PriceRow] {
        models.map { PriceRow(model: $0.key,
                              inputPerMTok: $0.value.inputPerMTok,
                              outputPerMTok: $0.value.outputPerMTok) }
    }

    /// Diff against another document. Returns one `PricingChange` per model
    /// whose input OR output price differs in `other`. Newly-added or removed
    /// models are skipped (not a "change", just an addition/removal).
    func diff(against other: PricingDocument, now: Date = Date()) -> [PricingChange] {
        var out: [PricingChange] = []
        for (model, newRow) in other.models {
            guard let oldRow = self.models[model] else { continue }
            if oldRow != newRow {
                out.append(PricingChange(
                    model: model,
                    oldInputUSD: oldRow.inputPerMTok,
                    newInputUSD: newRow.inputPerMTok,
                    oldOutputUSD: oldRow.outputPerMTok,
                    newOutputUSD: newRow.outputPerMTok,
                    detectedAt: now
                ))
            }
        }
        return out.sorted { $0.model < $1.model }
    }
}

protocol PricingFetcher {
    func fetchRemote() async throws -> PricingDocument
}

struct URLSessionPricingFetcher: PricingFetcher {
    static let endpoint = URL(string: "https://raw.githubusercontent.com/emreisik95/wattmeter/main/pricing.json")!
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func fetchRemote() async throws -> PricingDocument {
        var req = URLRequest(url: Self.endpoint)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(PricingDocument.self, from: data)
    }
}

enum PricingLoader {
    /// Loads the bundled seed pricing.json. Falls back to a built-in default
    /// matching `Pricing.opus/sonnet/haiku` constants if the resource is
    /// missing (e.g. when running `swift test` outside the app bundle).
    static func loadBundledSeed() -> PricingDocument {
        if let url = Bundle.main.url(forResource: "pricing", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let doc = try? JSONDecoder().decode(PricingDocument.self, from: data) {
            return doc
        }
        return defaultDocument
    }

    static let defaultDocument = PricingDocument(
        version: 1,
        updated: nil,
        models: [
            "claude-opus-4-7":   .init(inputPerMTok: 15.0, outputPerMTok: 75.0),
            "claude-sonnet-4-6": .init(inputPerMTok: 3.0,  outputPerMTok: 15.0),
            "claude-haiku-4-5":  .init(inputPerMTok: 0.80, outputPerMTok: 4.0)
        ]
    )
}

/// Engine that drives `PricingMonitor`. Lives outside FrozenAPI so it can
/// mutate state freely (FrozenAPI's `changes` is `private(set)`).
///
/// Behaviour:
/// 1. On init, load the bundled seed and push into `PricingTable.shared`.
/// 2. On `refresh()`, fetch the GitHub-raw mirror, diff against the last
///    known table, emit `PricingChange` for each diff, swap the active table.
/// 3. Cached daily refresh — the Phase 5 lead schedules this from a Timer.
@MainActor
final class PricingMonitorEngine: ObservableObject {
    @Published private(set) var changes: [PricingChange] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var current: PricingDocument

    private let fetcher: PricingFetcher
    private var timer: Timer?

    static let refreshInterval: TimeInterval = 86_400 // 1 day

    init(fetcher: PricingFetcher = URLSessionPricingFetcher(),
         seed: PricingDocument = PricingLoader.loadBundledSeed()) {
        self.fetcher = fetcher
        self.current = seed
        PricingTable.shared.setTable(seed.rows)
    }

    /// Begins daily refresh + a launch refresh. Idempotent.
    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    /// One-shot refresh. Diffs remote vs current, appends changes, swaps table.
    @discardableResult
    func refresh() async -> [PricingChange] {
        do {
            let remote = try await fetcher.fetchRemote()
            let diffs = current.diff(against: remote)
            if !diffs.isEmpty {
                changes.append(contentsOf: diffs)
                if changes.count > 100 {
                    changes.removeFirst(changes.count - 100)
                }
            }
            current = remote
            PricingTable.shared.setTable(remote.rows)
            lastError = nil
            lastRefresh = Date()
            return diffs
        } catch {
            lastError = error.localizedDescription
            lastRefresh = Date()
            return []
        }
    }

    /// Wipes recorded changes (after the user dismisses the banner).
    func dismissChanges() { changes.removeAll() }
}

extension PricingMonitor {
    /// Shared engine. The lead session can observe `engine.$changes` and mirror
    /// into `monitor.changes`, or swap `PricingMonitor` for `PricingMonitorEngine`
    /// directly in WattmeterApp wiring.
    static var defaultEngine: PricingMonitorEngine { PricingMonitorEngineHolder.shared }
}

@MainActor
private enum PricingMonitorEngineHolder {
    static let shared = PricingMonitorEngine()
}
