import Foundation
import SwiftUI

enum TrayDisplay: String, CaseIterable, Identifiable {
    case iconOnly
    case iconPct
    case pctOnly
    case dual
    case pctReset
    var id: String { rawValue }

    var title: String {
        switch self {
        case .iconOnly: return "Icon only"
        case .iconPct:  return "Icon + 5h %"
        case .pctOnly:  return "5h % only"
        case .dual:     return "5h + 7d %"
        case .pctReset: return "5h % + reset time"
        }
    }

    var preview: String {
        switch self {
        case .iconOnly: return "🧠"
        case .iconPct:  return "🧠 %18"
        case .pctOnly:  return "%18"
        case .dual:     return "5h %18 · 7d %30"
        case .pctReset: return "%18 · 16:30"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var trayDisplay: TrayDisplay {
        didSet { UserDefaults.standard.set(trayDisplay.rawValue, forKey: "app.trayDisplay") }
    }
    @Published var colorizeTray: Bool {
        didSet { UserDefaults.standard.set(colorizeTray, forKey: "app.colorizeTray") }
    }
    @Published var refreshIntervalSec: Int {
        didSet { UserDefaults.standard.set(refreshIntervalSec, forKey: "app.refreshIntervalSec") }
    }
    @Published var plan: Plan {
        didSet { UserDefaults.standard.set(plan.rawValue, forKey: "app.plan") }
    }
    @Published var didOnboard: Bool {
        didSet { UserDefaults.standard.set(didOnboard, forKey: "app.didOnboard") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "app.launchAtLogin")
            LaunchAtLogin.isEnabled = launchAtLogin
        }
    }

    init() {
        let d = UserDefaults.standard
        let rawTray = d.string(forKey: "app.trayDisplay") ?? TrayDisplay.iconPct.rawValue
        self.trayDisplay = TrayDisplay(rawValue: rawTray) ?? .iconPct
        if d.object(forKey: "app.colorizeTray") == nil {
            self.colorizeTray = true
        } else {
            self.colorizeTray = d.bool(forKey: "app.colorizeTray")
        }
        let interval = d.integer(forKey: "app.refreshIntervalSec")
        self.refreshIntervalSec = interval > 0 ? interval : 60
        let rawPlan = d.string(forKey: "app.plan") ?? Plan.max5x.rawValue
        self.plan = Plan(rawValue: rawPlan) ?? .max5x
        self.didOnboard = d.bool(forKey: "app.didOnboard")
        self.launchAtLogin = d.bool(forKey: "app.launchAtLogin")
    }
}
