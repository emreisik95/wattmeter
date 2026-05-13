import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let store: UsageStore
    private let limits: LimitsConfig
    private let settings: AppSettings
    private let budgetEvaluator: BudgetEvaluator
    private let toolUsageStore: ToolUsageStore
    private let profileManager: ProfileManager
    private let serviceStatusMonitor: ServiceStatusMonitor
    private let pricingMonitor: PricingMonitor
    private var cancellables = Set<AnyCancellable>()
    private var titleTimer: Timer?
    private var dataRefreshTimer: Timer?
    private var outsideClickMonitor: Any?

    init(
        store: UsageStore,
        limits: LimitsConfig,
        settings: AppSettings,
        budgetEvaluator: BudgetEvaluator,
        toolUsageStore: ToolUsageStore,
        profileManager: ProfileManager,
        serviceStatusMonitor: ServiceStatusMonitor,
        pricingMonitor: PricingMonitor
    ) {
        self.store = store
        self.limits = limits
        self.settings = settings
        self.budgetEvaluator = budgetEvaluator
        self.toolUsageStore = toolUsageStore
        self.profileManager = profileManager
        self.serviceStatusMonitor = serviceStatusMonitor
        self.pricingMonitor = pricingMonitor
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        let host = NSHostingController(
            rootView: DashboardView()
                .environmentObject(store)
                .environmentObject(limits)
                .environmentObject(settings)
                .environmentObject(budgetEvaluator)
                .environmentObject(toolUsageStore)
                .environmentObject(profileManager)
                .environmentObject(serviceStatusMonitor)
                .environmentObject(pricingMonitor)
                .tint(Theme.accent)
        )
        popover.contentViewController = host
        popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: 1020, height: 720)
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeft
        }

        observe()
        refreshTitle()
        scheduleDataRefresh()
        Task { @MainActor in
            if store.entries.isEmpty {
                await store.refresh()
                refreshTitle()
            }
        }
    }

    deinit {
        titleTimer?.invalidate()
        dataRefreshTimer?.invalidate()
    }

    private func observe() {
        limits.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshTitle()
                self?.evaluateNotifications()
            }
            .store(in: &cancellables)
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshTitle() }
            .store(in: &cancellables)
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshTitle() }
            .store(in: &cancellables)
        // Backup poll every 5s in case Combine misses (file mtime changes etc.)
        titleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTitle()
                self?.evaluateNotifications()
            }
        }
    }

    private func evaluateNotifications() {
        guard limits.isConnected else { return }
        NotificationManager.shared.evaluate(kind: .fiveHour, percentage: limits.live(.fiveHour).percentage)
        NotificationManager.shared.evaluate(kind: .weekly,   percentage: limits.live(.weekly).percentage)
    }

    private func scheduleDataRefresh() {
        dataRefreshTimer?.invalidate()
        let interval = TimeInterval(max(15, settings.refreshIntervalSec))
        dataRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.store.refresh()
            }
        }
    }

    // MARK: - Title

    private func refreshTitle() {
        guard let button = statusItem.button else { return }
        let l = limits.live(.fiveHour)
        let w = limits.live(.weekly)
        let style = limits.percentStyle
        let display = settings.trayDisplay
        let connected = limits.isConnected

        let baseColor: NSColor = {
            guard settings.colorizeTray, connected else { return .labelColor }
            if l.exceeded { return .systemRed }
            if l.nearing  { return .systemOrange }
            return .labelColor
        }()

        var text = ""
        if connected {
            switch display {
            case .iconOnly: text = ""
            case .iconPct, .pctOnly:
                text = style.format(l.percentage)
            case .dual:
                text = "5h \(style.format(l.percentage)) · 7d \(style.format(w.percentage))"
            case .pctReset:
                if let r = l.resetsAt {
                    let f = DateFormatter(); f.dateFormat = "HH:mm"
                    text = "\(style.format(l.percentage)) · \(f.string(from: r))"
                } else {
                    text = style.format(l.percentage)
                }
            }
        }

        if display == .pctOnly {
            button.image = nil
        } else {
            let img = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "Wattmeter")
            button.image = img
        }

        if text.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: baseColor,
                .font: NSFont.menuBarFont(ofSize: 0)
            ]
            button.attributedTitle = NSAttributedString(string: " " + text, attributes: attrs)
            button.imagePosition = display == .pctOnly ? .noImage : .imageLeft
        }
    }

    // MARK: - Click handling

    @objc private func handleClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { togglePopover(); return }
        let ctrlClick = event.modifierFlags.contains(.control)
        if event.type == .rightMouseUp || ctrlClick {
            showRightClickMenu()
        } else {
            togglePopover()
        }
    }

    /// Public entry point for URL scheme open action.
    func openPopover() { togglePopover() }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            limits.load()
            Task { await store.refresh() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            installOutsideClickMonitor()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        removeOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in self.removeOutsideClickMonitor() }
    }

    // MARK: - Right-click menu

    private func showRightClickMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Live status header (disabled)
        let l = limits.live(.fiveHour)
        let w = limits.live(.weekly)
        let header: String
        if limits.isConnected {
            header = "5h \(limits.percentStyle.format(l.percentage))   ·   7d \(limits.percentStyle.format(w.percentage))"
        } else {
            header = "Not connected to Claude limits"
        }
        let hi = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        hi.isEnabled = false
        menu.addItem(hi)

        // Cost line
        let today = Forecasting.costToday(store.entries)
        let week  = Forecasting.costThisWeek(store.entries)
        let costLine = String(format: "Today: $%.2f   ·   Week: $%.2f", today, week)
        let ci = NSMenuItem(title: costLine, action: nil, keyEquivalent: "")
        ci.isEnabled = false
        menu.addItem(ci)

        // Reset times
        if limits.isConnected {
            if let r5 = l.resetsAt {
                let ri = NSMenuItem(title: "5h resets \(humanReset(r5))", action: nil, keyEquivalent: "")
                ri.isEnabled = false
                menu.addItem(ri)
            }
            if let rw = w.resetsAt {
                let ri = NSMenuItem(title: "7d resets \(humanReset(rw))", action: nil, keyEquivalent: "")
                ri.isEnabled = false
                menu.addItem(ri)
            }
        }
        menu.addItem(.separator())

        let open = item("Open Dashboard", action: #selector(openDashboardItem), key: "")
        menu.addItem(open)
        let refresh = item("Refresh Now", action: #selector(refreshItem), key: "r")
        menu.addItem(refresh)
        let copy = item("Copy Usage to Clipboard", action: #selector(copyUsageItem), key: "c")
        menu.addItem(copy)
        let exportItem = NSMenuItem(title: "Export…", action: nil, keyEquivalent: "")
        let exportMenu = NSMenu()
        exportMenu.addItem(item("CSV…", action: #selector(exportCsvItem), key: ""))
        exportMenu.addItem(item("HTML…", action: #selector(exportHtmlItem), key: ""))
        exportMenu.addItem(item("PDF…", action: #selector(exportPdfItem), key: ""))
        exportItem.submenu = exportMenu
        menu.addItem(exportItem)
        menu.addItem(.separator())

        // Tray display submenu
        let trayItem = NSMenuItem(title: "Tray Display", action: nil, keyEquivalent: "")
        let trayMenu = NSMenu()
        for d in TrayDisplay.allCases {
            let i = NSMenuItem(
                title: "\(d.title)  —  \(d.preview)",
                action: #selector(setTrayDisplayItem(_:)),
                keyEquivalent: ""
            )
            i.target = self
            i.representedObject = d.rawValue
            i.state = settings.trayDisplay == d ? .on : .off
            trayMenu.addItem(i)
        }
        trayItem.submenu = trayMenu
        menu.addItem(trayItem)

        // Percent style submenu
        let pctItem = NSMenuItem(title: "Percent Format", action: nil, keyEquivalent: "")
        let pctMenu = NSMenu()
        for s in PercentStyle.allCases {
            let i = NSMenuItem(
                title: "\(s.title)",
                action: #selector(setPercentStyleItem(_:)),
                keyEquivalent: ""
            )
            i.target = self
            i.representedObject = s.rawValue
            i.state = limits.percentStyle == s ? .on : .off
            pctMenu.addItem(i)
        }
        pctItem.submenu = pctMenu
        menu.addItem(pctItem)

        // Colorize toggle
        let colorize = NSMenuItem(
            title: "Colorize Tray on Warning",
            action: #selector(toggleColorize),
            keyEquivalent: ""
        )
        colorize.target = self
        colorize.state = settings.colorizeTray ? .on : .off
        menu.addItem(colorize)

        // Plan submenu
        let planItem = NSMenuItem(title: "Plan", action: nil, keyEquivalent: "")
        let planMenu = NSMenu()
        for p in Plan.allCases {
            let i = NSMenuItem(title: p.title, action: #selector(setPlanItem(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = p.rawValue
            i.state = settings.plan == p ? .on : .off
            planMenu.addItem(i)
        }
        planItem.submenu = planMenu
        menu.addItem(planItem)

        // Notifications toggle
        let notif = NSMenuItem(
            title: "Threshold Notifications (50/80/100%)",
            action: #selector(toggleNotifications),
            keyEquivalent: ""
        )
        notif.target = self
        notif.state = NotificationManager.shared.enabled ? .on : .off
        menu.addItem(notif)

        let sound = NSMenuItem(
            title: "Sound on Limit Reached",
            action: #selector(toggleSound),
            keyEquivalent: ""
        )
        sound.target = self
        sound.state = NotificationManager.shared.soundOnExceed ? .on : .off
        menu.addItem(sound)

        // Launch at login
        let lal = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        lal.target = self
        lal.state = settings.launchAtLogin ? .on : .off
        menu.addItem(lal)

        // Refresh interval submenu
        let intervalItem = NSMenuItem(title: "Auto-refresh", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for sec in [30, 60, 120, 300, 600] {
            let label = sec < 60 ? "\(sec)s" : "\(sec / 60) min"
            let i = NSMenuItem(title: label, action: #selector(setIntervalItem(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = sec
            i.state = settings.refreshIntervalSec == sec ? .on : .off
            intervalMenu.addItem(i)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        menu.addItem(.separator())

        // File shortcuts
        let openFiles = NSMenuItem(title: "Open in Finder", action: nil, keyEquivalent: "")
        let openFilesMenu = NSMenu()
        openFilesMenu.addItem(item("~/.claude", action: #selector(openClaudeDir), key: ""))
        openFilesMenu.addItem(item("rate_limits.json", action: #selector(openRateLimitsFile), key: ""))
        openFilesMenu.addItem(item("settings.json", action: #selector(openSettingsFile), key: ""))
        openFiles.submenu = openFilesMenu
        menu.addItem(openFiles)

        // Integration
        let intLabel = limits.isConnected ? "Reinstall Statusline Hook" : "Install Statusline Hook"
        let install = item(intLabel, action: #selector(installIntegrationItem), key: "")
        menu.addItem(install)
        if limits.isConnected || !limits.fileMissing {
            let uninstall = item("Uninstall Statusline Hook", action: #selector(uninstallIntegrationItem), key: "")
            menu.addItem(uninstall)
        }
        menu.addItem(.separator())

        let check = NSMenuItem(title: "Check for Updates…", action: #selector(UpdaterBridge.checkForUpdates(_:)), keyEquivalent: "")
        check.target = UpdaterBridge.shared
        menu.addItem(check)
        let about = item("About Wattmeter", action: #selector(aboutItem), key: "")
        menu.addItem(about)
        let quit = item("Quit", action: #selector(quitItem), key: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    // MARK: - Menu actions

    @objc private func openDashboardItem() { togglePopover() }
    @objc private func refreshItem() {
        Task { await store.refresh() }
        limits.load()
    }
    @objc private func setTrayDisplayItem(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let d = TrayDisplay(rawValue: raw) {
            settings.trayDisplay = d
            refreshTitle()
        }
    }
    @objc private func setPercentStyleItem(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let s = PercentStyle(rawValue: raw) {
            limits.percentStyle = s
            refreshTitle()
        }
    }
    @objc private func toggleColorize() {
        settings.colorizeTray.toggle()
        refreshTitle()
    }
    @objc private func setIntervalItem(_ sender: NSMenuItem) {
        if let sec = sender.representedObject as? Int {
            settings.refreshIntervalSec = sec
            scheduleDataRefresh()
        }
    }
    @objc private func installIntegrationItem() {
        _ = limits.installStatusLineIntegration()
        limits.load()
        refreshTitle()
    }
    @objc private func uninstallIntegrationItem() {
        _ = limits.removeStatusLineIntegration()
        limits.load()
        refreshTitle()
    }
    @objc private func aboutItem() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    @objc private func quitItem() { NSApp.terminate(nil) }

    @objc private func copyUsageItem() {
        let l = limits.live(.fiveHour)
        let w = limits.live(.weekly)
        let today = Forecasting.costToday(store.entries)
        let week  = Forecasting.costThisWeek(store.entries)
        let parts: [String] = [
            limits.isConnected ? "5h:\(Int(l.percentage.rounded()))%" : "5h:-",
            limits.isConnected ? "7d:\(Int(w.percentage.rounded()))%" : "7d:-",
            String(format: "today:$%.2f", today),
            String(format: "week:$%.2f", week),
        ]
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(parts.joined(separator: " "), forType: .string)
    }

    @objc private func exportCsvItem() {
        Export.saveCSV(entries: store.entries)
    }

    @objc private func exportHtmlItem() {
        Export.saveHTML(entries: store.entries)
    }

    @objc private func exportPdfItem() {
        Export.savePDF(entries: store.entries)
    }

    @objc private func setPlanItem(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let p = Plan(rawValue: raw) {
            settings.plan = p
        }
    }

    @objc private func toggleNotifications() {
        NotificationManager.shared.enabled.toggle()
    }

    @objc private func toggleSound() {
        NotificationManager.shared.soundOnExceed.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        settings.launchAtLogin.toggle()
    }

    @objc private func openClaudeDir() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
    @objc private func openRateLimitsFile() {
        let u = LimitsConfig.ratelimitsURL
        if FileManager.default.fileExists(atPath: u.path) {
            NSWorkspace.shared.activateFileViewerSelecting([u])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([u.deletingLastPathComponent()])
        }
    }
    @objc private func openSettingsFile() {
        let u = LimitsConfig.settingsURL
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }

    private func humanReset(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(d) {
            f.dateFormat = "'today at' HH:mm"
        } else if cal.isDateInTomorrow(d) {
            f.dateFormat = "'tomorrow at' HH:mm"
        } else {
            f.dateFormat = "EEE MMM d HH:mm"
        }
        return f.string(from: d)
    }
}
