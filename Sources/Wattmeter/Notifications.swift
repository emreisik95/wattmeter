import Foundation
import UserNotifications
import AppKit

@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "notify.enabled") }
    }
    @Published var soundOnExceed: Bool {
        didSet { UserDefaults.standard.set(soundOnExceed, forKey: "notify.soundOnExceed") }
    }

    private var firedThresholds: [String: Int] = [:]

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: "notify.enabled") == nil {
            self.enabled = true
        } else {
            self.enabled = d.bool(forKey: "notify.enabled")
        }
        if d.object(forKey: "notify.soundOnExceed") == nil {
            self.soundOnExceed = true
        } else {
            self.soundOnExceed = d.bool(forKey: "notify.soundOnExceed")
        }
        requestAuth()
    }

    func requestAuth() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Fire notification when crossing a threshold (50/80/100). Per-kind dedup.
    func evaluate(kind: LimitKind, percentage: Double) {
        guard enabled else { return }
        let thresholds = [50, 80, 100]
        let pct = Int(percentage.rounded())
        let last = firedThresholds[kind.rawValue] ?? 0
        // Reset dedup if percentage dropped (new window)
        if pct < last - 5 {
            firedThresholds[kind.rawValue] = 0
        }
        for t in thresholds where pct >= t && last < t {
            send(title: "\(kind.title) limit \(t)%", body: bodyFor(kind: kind, pct: pct), critical: t >= 100)
            firedThresholds[kind.rawValue] = t
        }
    }

    private func bodyFor(kind: LimitKind, pct: Int) -> String {
        if pct >= 100 { return "Limit reached. Wait for reset." }
        if pct >= 80  { return "Nearing cap — \(pct)% used." }
        return "\(pct)% used."
    }

    private func send(title: String, body: String, critical: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        if soundOnExceed && critical {
            content.sound = .defaultCritical
        } else if soundOnExceed {
            content.sound = .default
        }
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
