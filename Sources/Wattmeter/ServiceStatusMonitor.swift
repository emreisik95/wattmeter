import Foundation

/// Decoded shape of `https://status.anthropic.com/api/v2/status.json`.
///
/// Schema (per Statuspage v2): `{ "status": { "indicator": "...", "description": "..." }, ... }`
/// Indicator enum values: `none | minor | major | critical | maintenance`.
struct AnthropicStatusResponse: Decodable {
    struct Status: Decodable {
        let indicator: String
        let description: String
    }
    let status: Status
}

protocol ServiceStatusFetcher {
    func fetch() async throws -> AnthropicStatusResponse
}

struct URLSessionServiceStatusFetcher: ServiceStatusFetcher {
    static let endpoint = URL(string: "https://status.anthropic.com/api/v2/status.json")!
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func fetch() async throws -> AnthropicStatusResponse {
        var req = URLRequest(url: Self.endpoint)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(AnthropicStatusResponse.self, from: data)
    }
}

extension ServiceStatus.Indicator {
    /// Maps a Statuspage indicator string to our enum. Unknown values fall
    /// back to `.none` rather than throwing.
    static func from(_ raw: String) -> ServiceStatus.Indicator {
        switch raw.lowercased() {
        case "none":        return .none
        case "minor":       return .minor
        case "major":       return .major
        case "critical":    return .critical
        case "maintenance": return .maintenance
        default:            return .none
        }
    }
}

/// Engine that does the actual polling and decoding. Lives separately from
/// FrozenAPI's `ServiceStatusMonitor` (whose `@Published private(set)` fields
/// can't be written from another file). The lead session wires this engine
/// into the monitor's published state.
@MainActor
final class ServiceStatusEngine: ObservableObject {
    @Published private(set) var current: ServiceStatus = .healthy
    @Published private(set) var lastCheck: Date?
    @Published private(set) var lastError: String?

    private var timer: Timer?
    private let fetcher: ServiceStatusFetcher

    /// Polls every 5 minutes per plan F9.
    static let pollInterval: TimeInterval = 300

    init(fetcher: ServiceStatusFetcher = URLSessionServiceStatusFetcher()) {
        self.fetcher = fetcher
    }

    /// Start polling. Idempotent.
    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }

    /// One-shot refresh. Returns the resolved status.
    @discardableResult
    func refresh() async -> ServiceStatus {
        do {
            let resp = try await fetcher.fetch()
            let s = Self.decode(resp)
            self.current = s
            self.lastError = nil
            self.lastCheck = Date()
            return s
        } catch {
            self.lastError = error.localizedDescription
            self.lastCheck = Date()
            return current
        }
    }

    nonisolated static func decode(_ resp: AnthropicStatusResponse) -> ServiceStatus {
        ServiceStatus(
            indicator: .from(resp.status.indicator),
            description: resp.status.description
        )
    }
}

extension ServiceStatusMonitor {
    /// Convenience accessor for the shared engine. The Phase 5 lead can
    /// observe `engine.$current` and mirror it onto `monitor.current` via
    /// whatever glue is appropriate (engine-driven UI, or by replacing the
    /// monitor entirely with the engine in WattmeterApp).
    static var defaultEngine: ServiceStatusEngine { ServiceStatusEngineHolder.shared }
}

@MainActor
private enum ServiceStatusEngineHolder {
    static let shared = ServiceStatusEngine()
}
