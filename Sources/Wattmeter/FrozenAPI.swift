import Foundation
import SwiftUI
import Combine

// MARK: - F3 Multi-provider

protocol UsageProvider {
    var id: String { get }
    var displayName: String { get }
    var isEnabled: Bool { get }
    func fetch() async -> [UsageEntry]
}

// MARK: - F2 Tool attribution

struct ToolStat: Codable, Hashable {
    let count: Int
    let tokens: Int
}

@MainActor
final class ToolUsageStore: ObservableObject {
    @Published private(set) var perTool: [String: ToolStat] = [:]
    @Published private(set) var perFile: [String: ToolStat] = [:]
    @Published var lastRefresh: Date?

    static let snapshotURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Wattmeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tool_usage.json")
    }()

    func refresh() async {}

    func _setForTesting(perTool: [String: ToolStat], perFile: [String: ToolStat]) {
        self.perTool = perTool
        self.perFile = perFile
    }
}

// MARK: - F1 Budgets + F12 Anomaly (shared event bus)

enum BudgetWindow: String, Codable, Hashable, CaseIterable {
    case daily, weekly, session
}

struct Budget: Codable, Identifiable, Hashable {
    let id: UUID
    var label: String
    var amountUSD: Double
    var window: BudgetWindow
    var hardCap: Bool
    var webhookKeychainRef: String?

    init(id: UUID = UUID(), label: String, amountUSD: Double, window: BudgetWindow, hardCap: Bool = false, webhookKeychainRef: String? = nil) {
        self.id = id
        self.label = label
        self.amountUSD = amountUSD
        self.window = window
        self.hardCap = hardCap
        self.webhookKeychainRef = webhookKeychainRef
    }
}

struct BudgetEvent: Identifiable, Hashable {
    enum Kind: String, Codable, Hashable { case crossed50, crossed75, crossed90, exceeded, anomaly }
    let id: UUID
    let budgetId: UUID?
    let percent: Double
    let kind: Kind
    let timestamp: Date
    let note: String?

    init(id: UUID = UUID(), budgetId: UUID?, percent: Double, kind: Kind, timestamp: Date = Date(), note: String? = nil) {
        self.id = id
        self.budgetId = budgetId
        self.percent = percent
        self.kind = kind
        self.timestamp = timestamp
        self.note = note
    }
}

@MainActor
final class BudgetEvaluator: ObservableObject {
    @Published var lastEvents: [BudgetEvent] = []
    @Published var budgets: [Budget] = []

    func setBudgets(_ b: [Budget]) { budgets = b }

    func evaluate(_ entries: [UsageEntry], limits: LimitsConfig) async {}

    func push(_ event: BudgetEvent) {
        lastEvents.append(event)
        if lastEvents.count > 200 { lastEvents.removeFirst(lastEvents.count - 200) }
    }
}

// MARK: - F9 Service status

struct ServiceStatus: Equatable, Hashable {
    enum Indicator: String, Codable, Hashable {
        case none, minor, major, critical, maintenance
    }
    let indicator: Indicator
    let description: String

    var isHealthy: Bool { indicator == .none }

    static let healthy = ServiceStatus(indicator: .none, description: "")
}

@MainActor
final class ServiceStatusMonitor: ObservableObject {
    @Published var current: ServiceStatus = .healthy
    @Published var lastCheck: Date?

    /// Optional engine that drives this monitor. Set in WattmeterApp.
    var engine: ServiceStatusEngine?

    private var cancellables: Set<AnyCancellable> = []

    func bind(to engine: ServiceStatusEngine) {
        self.engine = engine
        cancellables.removeAll()
        engine.$current.receive(on: RunLoop.main).assign(to: &$current)
        engine.$lastCheck.receive(on: RunLoop.main).assign(to: &$lastCheck)
    }

    func start() { engine?.start() }
    func stop() { engine?.stop() }
}

// MARK: - F10 Pricing monitor

struct PricingChange: Equatable, Hashable, Identifiable {
    let id: UUID
    let model: String
    let oldInputUSD: Double
    let newInputUSD: Double
    let oldOutputUSD: Double
    let newOutputUSD: Double
    let detectedAt: Date

    init(id: UUID = UUID(), model: String, oldInputUSD: Double, newInputUSD: Double, oldOutputUSD: Double, newOutputUSD: Double, detectedAt: Date = Date()) {
        self.id = id
        self.model = model
        self.oldInputUSD = oldInputUSD
        self.newInputUSD = newInputUSD
        self.oldOutputUSD = oldOutputUSD
        self.newOutputUSD = newOutputUSD
        self.detectedAt = detectedAt
    }
}

@MainActor
final class PricingMonitor: ObservableObject {
    @Published var changes: [PricingChange] = []
    @Published var lastRefresh: Date?

    var engine: PricingMonitorEngine?

    func bind(to engine: PricingMonitorEngine) {
        self.engine = engine
        engine.$changes.receive(on: RunLoop.main).assign(to: &$changes)
        engine.$lastRefresh.receive(on: RunLoop.main).assign(to: &$lastRefresh)
    }

    func refresh() async {
        await engine?.refresh()
    }
}

// MARK: - F5 Profiles

struct UsageProfile: Codable, Identifiable, Hashable {
    let id: UUID
    var label: String
    var claudeDir: URL

    init(id: UUID = UUID(), label: String, claudeDir: URL) {
        self.id = id
        self.label = label
        self.claudeDir = claudeDir
    }
}

@MainActor
final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published var profiles: [UsageProfile] = []
    @Published var activeID: UUID?

    var activeClaudeDir: URL {
        profiles.first { $0.id == activeID }?.claudeDir
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    func setActive(_ id: UUID) { activeID = id }
    func add(_ p: UsageProfile) { profiles.append(p) }
    func remove(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeID == id { activeID = profiles.first?.id }
    }
}
