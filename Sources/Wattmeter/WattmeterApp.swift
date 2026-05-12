import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusController: StatusBarController?
    let store = UsageStore()
    let limits = LimitsConfig()
    let settings = AppSettings()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = UpdaterBridge.shared
        statusController = StatusBarController(store: store, limits: limits, settings: settings)
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
