import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusController: StatusBarController?

    let store = UsageStore()
    let limits = LimitsConfig()
    let settings = AppSettings()
    let budgetEvaluator = BudgetEvaluator()
    let toolUsageStore = ToolUsageStore()
    let profileManager = ProfileManager.shared
    let serviceStatusMonitor = ServiceStatusMonitor()
    let pricingMonitor = PricingMonitor()
    let budgetStore = BudgetStore()

    func applicationWillFinishLaunching(_ notification: Notification) {
        URLSchemeHandler.register(actions: [
            "refresh": { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in await self.store.refresh() }
            },
            "open": { [weak self] _ in
                Task { @MainActor in self?.statusController?.openPopover() }
            },
            "export-csv": { [weak self] _ in
                Task { @MainActor in
                    guard let entries = self?.store.entries else { return }
                    Export.saveCSV(entries: entries)
                }
            },
            "check-updates": { _ in
                Task { @MainActor in
                    UpdaterBridge.shared.checkForUpdates(nil)
                }
            },
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = UpdaterBridge.shared

        profileManager.bootstrap()
        budgetEvaluator.setBudgets(budgetStore.budgets)
        serviceStatusMonitor.bind(to: ServiceStatusMonitor.defaultEngine)
        pricingMonitor.bind(to: PricingMonitor.defaultEngine)
        serviceStatusMonitor.start()
        Task { @MainActor in
            await pricingMonitor.refresh()
        }

        statusController = StatusBarController(
            store: store,
            limits: limits,
            settings: settings,
            budgetEvaluator: budgetEvaluator,
            toolUsageStore: toolUsageStore,
            profileManager: profileManager,
            serviceStatusMonitor: serviceStatusMonitor,
            pricingMonitor: pricingMonitor
        )

        Task { @MainActor in
            await toolUsageStore.refreshFromLog()
        }
    }
}

@main
struct WattmeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
