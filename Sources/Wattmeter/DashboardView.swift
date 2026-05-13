import SwiftUI
import Charts

// MARK: - Range / tabs

enum TimeRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case week = "7d"
    case month = "30d"
    case all = "All"
    var id: String { rawValue }

    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let start: Date
        switch self {
        case .today: start = calendar.startOfDay(for: now)
        case .week:  start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .month: start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .all:   start = .distantPast
        }
        return DateInterval(start: start, end: now)
    }
}

enum DashTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case models   = "Models"
    case projects = "Projects"
    case sessions = "Sessions"
    case tools    = "Tools"
    case insights = "Insights"
    case limits   = "Limits"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "chart.bar.fill"
        case .models:   return "cpu"
        case .projects: return "folder.fill"
        case .sessions: return "bubble.left.and.bubble.right.fill"
        case .tools:    return "wrench.and.screwdriver.fill"
        case .insights: return "sparkles"
        case .limits:   return "gauge.with.dots.needle.67percent"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .overview: return "1"
        case .models:   return "2"
        case .projects: return "3"
        case .sessions: return "4"
        case .tools:    return "5"
        case .insights: return "6"
        case .limits:   return "7"
        }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var limits: LimitsConfig
    @EnvironmentObject var settings: AppSettings
    @State private var range: TimeRange = .week
    @State private var tab: DashTab = .overview
    @State private var showSettings = false
    @State private var filterText = ""
    @State private var rangeFiltered: [UsageEntry] = []
    @State private var searchFiltered: [UsageEntry] = []
    @State private var cachedSummary: Aggregator.Summary = .init()
    @State private var cachedByModel: [Aggregator.ModelSlice] = []
    @State private var cachedByProject: [Aggregator.ProjectSlice] = []
    @State private var cachedBySession: [Aggregator.SessionSlice] = []
    @State private var cachedTopRequests: [UsageEntry] = []
    @State private var cachedByDay: [Aggregator.DayBucket] = []
    @State private var debounceTask: Task<Void, Never>? = nil

    private func scheduleRecompute(immediate: Bool = false) {
        debounceTask?.cancel()
        if immediate {
            recomputeFilters()
            return
        }
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            recomputeFilters()
        }
    }

    private func recomputeFilters() {
        let rf = Aggregator.filter(store.entries, range: range.interval())
        rangeFiltered = rf
        let sf: [UsageEntry]
        if filterText.isEmpty {
            sf = rf
        } else {
            let needle = filterText.lowercased()
            sf = rf.filter {
                $0.model.lowercased().contains(needle)
                || $0.project.lowercased().contains(needle)
                || $0.sessionId.lowercased().contains(needle)
            }
        }
        searchFiltered = sf
        cachedSummary = Aggregator.summary(sf)
        cachedByModel = Aggregator.byModel(sf)
        cachedByProject = Aggregator.byProject(sf, top: 100)
        cachedBySession = Aggregator.bySession(sf, top: 200)
        cachedTopRequests = Aggregator.topRequests(sf, top: 20)
        cachedByDay = Aggregator.byDay(sf)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                footer
            }
            if !settings.didOnboard {
                OnboardingOverlay()
                    .environmentObject(limits)
                    .environmentObject(settings)
            }
        }
        .onAppear { scheduleRecompute(immediate: true) }
        .onChange(of: store.entries.count) { scheduleRecompute() }
        .onChange(of: store.lastRefresh) { scheduleRecompute() }
        .onChange(of: range) { scheduleRecompute(immediate: true) }
        .onChange(of: filterText) { scheduleRecompute() }
        .sheet(isPresented: $showSettings) {
            IntegrationSettingsView()
                .environmentObject(limits)
                .environmentObject(settings)
                .tint(Theme.accent)
        }
        .background(
            Group {
                Button("") { Task { await store.refresh(); limits.load() } }
                    .keyboardShortcut("r", modifiers: .command).hidden()
                ForEach(DashTab.allCases) { t in
                    Button("") { tab = t }
                        .keyboardShortcut(t.shortcut, modifiers: .command).hidden()
                }
                Button("") { showSettings = true }
                    .keyboardShortcut(",", modifiers: .command).hidden()
            }
        )
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                Text("Wattmeter").font(.title2).bold()
                DashboardChips()
                Spacer()
                if tab != .limits {
                    Picker("Range", selection: $range) {
                        ForEach(TimeRange.allCases) { r in Text(r.rawValue).tag(r) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .help("Integration & settings (⌘,)")
                Button {
                    Task { await store.refresh() }
                    limits.load()
                } label: {
                    Image(systemName: store.isLoading ? "hourglass" : "arrow.clockwise")
                }
                .disabled(store.isLoading)
                .buttonStyle(.borderless)
                .help("Refresh (⌘R)")
            }
            HStack(spacing: 8) {
                tabBar
            }
            if tab != .limits {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.callout)
                    TextField("Filter by model, project, or session…", text: $filterText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                    if !filterText.isEmpty {
                        Button { filterText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(DashTab.allCases) { t in
                Button {
                    tab = t
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.icon).font(.callout)
                        Text(t.rawValue)
                            .font(.callout).bold()
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(tab == t ? Theme.accent.opacity(0.14) : Color.clear)
                    )
                    .foregroundStyle(tab == t ? Theme.accent : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if limits.isConnected {
                limitChip(limits.live(.fiveHour))
                limitChip(limits.live(.weekly))
            } else {
                Button {
                    showSettings = true
                } label: {
                    Label("Not connected", systemImage: "link.badge.plus")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
            }
        }
    }

    private func limitChip(_ l: LiveLimit) -> some View {
        let color: Color = l.exceeded ? .red : (l.nearing ? .orange : .green)
        let label = l.kind == .fiveHour ? "5h" : "7d"
        return HStack(spacing: 4) {
            Image(systemName: l.kind.icon).font(.subheadline)
            Text("\(label) \(limits.percentStyle.format(l.percentage))")
                .font(.subheadline).bold().monospacedDigit()
            if let r = l.resetsAt {
                Text("· \(resetShort(r, kind: l.kind))").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
        .help("\(l.kind.title) · \(limits.percentStyle.format(l.percentage)) used")
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview: OverviewTab(
            entries: searchFiltered,
            all: store.entries,
            summary: cachedSummary,
            byModel: cachedByModel,
            byProject: cachedByProject,
            topRequests: cachedTopRequests
        )
        case .models:   ModelsTab(entries: searchFiltered, byModel: cachedByModel)
        case .projects: ProjectsTab(entries: searchFiltered, byProject: cachedByProject)
        case .sessions: SessionsTab(entries: searchFiltered, bySession: cachedBySession)
        case .tools:    ToolBreakdownView()
        case .insights: InsightsView()
        case .limits:   LimitsTab(entries: store.entries)
        }
    }

    private struct PulseModifier: ViewModifier {
        @State private var on = false
        func body(content: Content) -> some View {
            content
                .scaleEffect(on ? 1.0 : 0.6)
                .opacity(on ? 1.0 : 0.4)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
                .onAppear { on = true }
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 4) {
                if store.isLoading {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                        .opacity(0.85)
                        .modifier(PulseModifier())
                    Text("Updating…")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text(store.lastRefresh.map { "Updated \(rel($0))" } ?? "Loading…")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !rangeFiltered.isEmpty {
                Text("\(searchFiltered.count) of \(rangeFiltered.count) requests")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Export.saveCSV(entries: searchFiltered)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func rel(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Header chips

/// Profile selector + service-status dot, rendered next to the title in the
/// dashboard header. Both depend on env-objects wired by the lead session at
/// integration — kept in a thin wrapper so the rest of the header compiles
/// even if either is replaced later.
private struct DashboardChips: View {
    var body: some View {
        HStack(spacing: 6) {
            ProfileChip()
            ServiceStatusBadge()
        }
    }
}

// MARK: - Overview tab

private struct OverviewTab: View {
    let entries: [UsageEntry]
    let all: [UsageEntry]
    let summary: Aggregator.Summary
    let byModel: [Aggregator.ModelSlice]
    let byProject: [Aggregator.ProjectSlice]
    let topRequests: [UsageEntry]

    var body: some View {
        let s = summary
        let standup = Insights.standup(all)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                StandupCard(standup: standup, compact: true)
                summaryRow(s)
                Section(header: sectionHeader("Cost over time", icon: "chart.line.uptrend.xyaxis")) {
                    CostOverTimeChart(entries: entries).frame(height: 160)
                }
                Section(header: sectionHeader("Activity heatmap (7d × 24h)", icon: "square.grid.3x3.fill")) {
                    HeatmapView(entries: all).frame(height: 130)
                }
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Top models", icon: "cpu")
                        UsageBarList(items: byModel.prefix(5).map {
                            UsageBarItem(name: $0.model, cost: $0.cost)
                        }, color: Theme.accent, totalCost: s.cost)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Top projects", icon: "folder.fill")
                        UsageBarList(items: byProject.prefix(5).map {
                            UsageBarItem(name: $0.project, cost: $0.cost)
                        }, color: Theme.accent, totalCost: s.cost)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Top expensive requests", icon: "flame.fill")
                    let top = Array(topRequests.prefix(8))
                    if top.isEmpty {
                        EmptyHint(text: "No requests in range").padding(.vertical, 8)
                    } else {
                        ForEach(top) { e in
                            TopRequestRow(entry: e)
                            Divider()
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private func summaryRow(_ s: Aggregator.Summary) -> some View {
        HStack(spacing: 8) {
            StatCard(title: "Cost", value: fmt(s.cost), accent: Theme.accent)
            StatCard(title: "Input", value: shortNum(s.inputTokens), accent: .primary)
            StatCard(title: "Output", value: shortNum(s.outputTokens), accent: .primary)
            StatCard(title: "Cache W", value: shortNum(s.cacheWriteTokens), accent: .primary)
            StatCard(title: "Cache R", value: shortNum(s.cacheReadTokens), accent: .primary)
        }
    }

    private func fmt(_ d: Double) -> String { String(format: "$%.2f", d) }
}

private struct TopRequestRow: View {
    let entry: UsageEntry
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Aggregator.shortModel(entry.model)).font(.callout).bold()
                    Text("·").foregroundStyle(.tertiary)
                    Text(entry.project).font(.callout).lineLimit(1).truncationMode(.middle)
                }
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(shortNum(entry.totalTokens)) tok").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            Text(String(format: "$%.3f", entry.cost))
                .font(.title3).bold().monospacedDigit().foregroundStyle(Theme.accent)
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString("\(entry.timestamp.ISO8601Format())  \(entry.model)  \(entry.project)  $\(entry.cost)", forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.clipboard")
                    .foregroundStyle(copied ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)
            .help("Copy details")
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Heatmap

private struct HeatmapView: View {
    let entries: [UsageEntry]

    var body: some View {
        let (grid, start) = Aggregator.heatmap(entries, days: 7)
        let maxVal = max(grid.flatMap { $0 }.max() ?? 0, 0.001)
        GeometryReader { geo in
            let totalW = geo.size.width
            let labelW: CGFloat = 36
            let cellW = max(2, (totalW - labelW - 24) / 24)
            let cellH: CGFloat = 14
            VStack(spacing: 2) {
                HStack(spacing: 1) {
                    Color.clear.frame(width: labelW, height: 10)
                    ForEach(0..<24, id: \.self) { h in
                        Text(h % 6 == 0 ? "\(h)" : "")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(width: cellW, alignment: .leading)
                    }
                }
                ForEach(0..<7, id: \.self) { day in
                    HStack(spacing: 1) {
                        Text(dayLabel(start: start, offset: day))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: labelW, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            let v = grid[day][hour]
                            let intensity = v / maxVal
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.heat(intensity))
                                .frame(width: cellW, height: cellH)
                                .help(String(format: "%@ %02d:00 — $%.3f", dayFull(start: start, offset: day), hour, v))
                        }
                    }
                }
            }
        }
    }

    private func dayLabel(start: Date, offset: Int) -> String {
        let cal = Calendar.current
        guard let d = cal.date(byAdding: .day, value: offset, to: start) else { return "" }
        let f = DateFormatter(); f.dateFormat = "EEE"
        return f.string(from: d)
    }
    private func dayFull(start: Date, offset: Int) -> String {
        let cal = Calendar.current
        guard let d = cal.date(byAdding: .day, value: offset, to: start) else { return "" }
        let f = DateFormatter(); f.dateFormat = "EEE MMM d"
        return f.string(from: d)
    }
}

// MARK: - Models tab

private struct ModelsTab: View {
    let entries: [UsageEntry]
    let byModel: [Aggregator.ModelSlice]

    var body: some View {
        let data = byModel
        let total = data.reduce(0.0) { $0 + $1.cost }
        ScrollView {
            VStack(spacing: 0) {
                if data.isEmpty {
                    EmptyHint(text: "No model data in range").padding(40)
                } else {
                    ForEach(data) { d in
                        DetailRow(
                            name: d.model,
                            icon: modelIcon(d.model),
                            iconColor: modelColor(d.model),
                            cost: d.cost,
                            fraction: total > 0 ? d.cost / total : 0,
                            entries: entries.filter { Aggregator.shortModel($0.model) == d.model }
                        )
                        Divider()
                    }
                }
            }
            .padding(14)
        }
    }

    private func modelIcon(_ m: String) -> String {
        let l = m.lowercased()
        if l.contains("opus")   { return "crown.fill" }
        if l.contains("sonnet") { return "music.note" }
        if l.contains("haiku")  { return "leaf.fill" }
        return "cpu"
    }

    private func modelColor(_ m: String) -> Color {
        // Monochrome — model identity carried by icon shape + label, not color.
        return .secondary
    }
}

// MARK: - Projects tab

private struct ProjectsTab: View {
    let entries: [UsageEntry]
    let byProject: [Aggregator.ProjectSlice]

    var body: some View {
        let data = byProject
        let total = data.reduce(0.0) { $0 + $1.cost }
        ScrollView {
            VStack(spacing: 0) {
                if data.isEmpty {
                    EmptyHint(text: "No project data in range").padding(40)
                } else {
                    ForEach(data) { d in
                        DetailRow(
                            name: d.project,
                            icon: "folder.fill",
                            iconColor: .secondary,
                            cost: d.cost,
                            fraction: total > 0 ? d.cost / total : 0,
                            entries: entries.filter { $0.project == d.project }
                        )
                        Divider()
                    }
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Sessions tab

private struct SessionsTab: View {
    let entries: [UsageEntry]
    let bySession: [Aggregator.SessionSlice]
    @State private var expanded: String?
    @State private var replaySessionId: String?

    var body: some View {
        let sessions = bySession
        let total = sessions.reduce(0.0) { $0 + $1.cost }
        ScrollView {
            VStack(spacing: 0) {
                if sessions.isEmpty {
                    EmptyHint(text: "No sessions in range").padding(40)
                } else {
                    ForEach(sessions) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                expanded = expanded == s.sessionId ? nil : s.sessionId
                            } label: {
                                SessionRow(
                                    session: s,
                                    fraction: total > 0 ? s.cost / total : 0,
                                    expanded: expanded == s.sessionId,
                                    onReplay: { replaySessionId = s.sessionId }
                                )
                            }
                            .buttonStyle(.plain)
                            if expanded == s.sessionId {
                                let sessEntries = entries.filter { $0.sessionId == s.sessionId }
                                SessionDetail(entries: sessEntries)
                            }
                        }
                        Divider()
                    }
                }
            }
            .padding(14)
        }
        .sheet(item: Binding(
            get: { replaySessionId.map { ReplayBinding(id: $0) } },
            set: { replaySessionId = $0?.id }
        )) { bind in
            let sessEntries = entries.filter { $0.sessionId == bind.id }
            SessionReplayView(sessionId: bind.id, entries: sessEntries)
        }
    }
}

private struct ReplayBinding: Identifiable { let id: String }

private struct SessionRow: View {
    let session: Aggregator.SessionSlice
    let fraction: Double
    let expanded: Bool
    let onReplay: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .foregroundStyle(.secondary).font(.callout).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(short(session.sessionId)).font(.title3).bold().monospaced()
                    Text("·").foregroundStyle(.tertiary)
                    Text(session.project).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text("\(session.entryCount) requests").font(.subheadline).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(shortNum(session.tokens) + " tok").font(.subheadline).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(durationStr(session.duration)).font(.subheadline).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(session.lastSeen.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                onReplay()
            } label: {
                Image(systemName: "play.rectangle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accent)
            .help("Replay session transcript")
            Text(String(format: "$%.2f", session.cost))
                .font(.title3).bold().monospacedDigit().foregroundStyle(Theme.accent)
            Text(String(format: "%.0f%%", fraction * 100))
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func short(_ s: String) -> String {
        s.isEmpty ? "(no-id)" : String(s.prefix(8))
    }

    private func durationStr(_ t: TimeInterval) -> String {
        if t < 60 { return String(format: "%.0fs", t) }
        if t < 3600 { return String(format: "%.0fm", t / 60) }
        return String(format: "%.1fh", t / 3600)
    }
}

private struct SessionDetail: View {
    let entries: [UsageEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let byModel = Dictionary(grouping: entries, by: { Aggregator.shortModel($0.model) })
                .mapValues { es in (cost: es.reduce(0.0) { $0 + $1.cost }, n: es.count) }
                .sorted { $0.value.cost > $1.value.cost }
            ForEach(byModel, id: \.key) { (model, info) in
                HStack {
                    Text("• \(model)").font(.callout).monospacedDigit()
                    Spacer()
                    Text("\(info.n) reqs").font(.subheadline).foregroundStyle(.secondary)
                    Text(String(format: "$%.3f", info.cost))
                        .font(.callout).bold().monospacedDigit().foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, 24)
        .padding(.trailing, 8)
    }
}

// MARK: - Limits tab

private struct LimitsTab: View {
    @EnvironmentObject var limits: LimitsConfig
    @EnvironmentObject var settings: AppSettings
    let entries: [UsageEntry]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if !limits.isConnected {
                    NotConnectedCard()
                } else {
                    ForEach(LimitKind.allCases) { kind in
                        LimitCard(live: limits.live(kind), plan: settings.plan, entries: entries)
                    }
                    ContextCard(percentage: limits.contextPercentage)
                    if let mod = limits.lastUpdated {
                        Text("Live data updated \(rel(mod))")
                            .font(.subheadline).foregroundStyle(.tertiary)
                    }
                }

                PlanPickerCard()

                DailyProjectionCard(entries: entries)

                VStack(alignment: .leading, spacing: 6) {
                    Label("Cost in last 5h (from session logs)", systemImage: "clock.arrow.circlepath")
                        .font(.callout).bold().foregroundStyle(.secondary)
                    let cal = Calendar.current
                    let nowDate = Date()
                    let start = cal.date(byAdding: .hour, value: -5, to: nowDate) ?? nowDate
                    let iv = DateInterval(start: start, end: nowDate)
                    let recent = entries.filter { iv.contains($0.timestamp) }
                    if recent.isEmpty {
                        EmptyHint(text: "No activity in last 5h").padding(20)
                    } else {
                        let recentCost = recent.reduce(0.0) { $0 + $1.cost }
                        Text(String(format: "$%.2f", recentCost))
                            .font(.title2).bold().foregroundStyle(Theme.accent).monospacedDigit()
                        FiveHourBucketsChart(entries: recent).frame(height: 120)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(14)
        }
    }

    private func rel(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

private struct PlanPickerCard: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Plan (used for $-projection)", systemImage: "creditcard")
                .font(.callout).bold().foregroundStyle(.secondary)
            Picker("Plan", selection: $settings.plan) {
                ForEach(Plan.allCases) { p in Text(p.title).tag(p) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if settings.plan != .custom {
                Text("Approximate caps: 5h $\(Int(settings.plan.fiveHourCeiling)) · 7d $\(Int(settings.plan.weeklyCeiling))")
                    .font(.subheadline).foregroundStyle(.tertiary)
            } else {
                Text("Custom plan — no projection ceiling assumed.")
                    .font(.subheadline).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DailyProjectionCard: View {
    let entries: [UsageEntry]

    var body: some View {
        let today = Forecasting.costToday(entries)
        let burnPerSec = Forecasting.burnRate(entries: entries, lookbackSeconds: 1800)
        let secsLeftToday = endOfDayInterval()
        let projected = today + burnPerSec * secsLeftToday
        VStack(alignment: .leading, spacing: 6) {
            Label("Today", systemImage: "sun.max.fill")
                .font(.callout).bold().foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "$%.2f", today))
                    .font(.title2).bold().monospacedDigit().foregroundStyle(Theme.accent)
                Text("so far").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "Projected end-of-day: $%.2f", projected))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(String(format: "Burn rate (30m avg): $%.2f / hour", burnPerSec * 3600))
                .font(.subheadline).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func endOfDayInterval() -> TimeInterval {
        let cal = Calendar.current
        let now = Date()
        let startOfTomorrow = cal.startOfDay(for: now).addingTimeInterval(86400)
        return max(0, startOfTomorrow.timeIntervalSince(now))
    }
}

private struct NotConnectedCard: View {
    @EnvironmentObject var limits: LimitsConfig
    @State private var msg: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "link.badge.plus").foregroundStyle(.orange)
                Text("Not connected to Claude limits").font(.headline)
                Spacer()
            }
            Text("Wattmeter shows real 5-hour and weekly limits straight from Claude Code. Connect once — it patches your statusLine to write the JSON to `~/.claude/rate_limits.json` after every prompt.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button {
                    let r = limits.installStatusLineIntegration()
                    switch r {
                    case .installed:        msg = "Connected. Send a Claude prompt to populate."
                    case .alreadyInstalled: msg = "Already installed. File appears after next prompt."
                    case .settingsMissing:  msg = "~/.claude/settings.json not found."
                    case .noStatusLine:     msg = "Force-installed default statusLine."
                    case .patchFailed:      msg = "Write failed (permissions?)."
                    }
                    limits.load()
                } label: {
                    Label("Connect", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                if let m = msg {
                    Text(m).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct LimitCard: View {
    @EnvironmentObject var limits: LimitsConfig
    let live: LiveLimit
    let plan: Plan
    let entries: [UsageEntry]

    private var color: Color {
        if live.exceeded { return .red }
        if live.nearing  { return .orange }
        return .green
    }

    var body: some View {
        let burnPerSec = Forecasting.burnRate(entries: entries, lookbackSeconds: 1800)
        let ceiling = live.kind == .fiveHour ? plan.fiveHourCeiling : plan.weeklyCeiling
        let forecast = Forecasting.forecast(
            currentPct: live.percentage,
            resetsAt: live.resetsAt,
            burnPerSec: burnPerSec,
            ceiling: ceiling
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: live.kind.icon).foregroundStyle(color)
                Text(live.kind.title).font(.headline)
                Spacer()
                Text(limits.percentStyle.format(live.percentage))
                    .font(.title2).bold().monospacedDigit()
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.15))
                    // Projected fraction (ghost overlay)
                    if forecast.projectedFraction > live.fraction {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(color.opacity(0.2))
                            .frame(width: max(4, geo.size.width * min(1.0, forecast.projectedFraction)))
                    }
                    RoundedRectangle(cornerRadius: 5)
                        .fill(color.gradient)
                        .frame(width: max(4, geo.size.width * live.fraction))
                }
            }
            .frame(height: 10)
            HStack(spacing: 12) {
                if let r = live.resetsAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Label(countdown(to: r, now: ctx.date), systemImage: "timer")
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text("resets \(resetStr(r))").font(.subheadline).foregroundStyle(.tertiary)
                } else {
                    Text("No reset info").font(.subheadline).foregroundStyle(.tertiary)
                }
                Spacer()
                if forecast.willExceed {
                    Label("Will exceed", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline).foregroundStyle(.red)
                } else if live.exceeded {
                    Label("Limit reached", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline).foregroundStyle(.red)
                } else if live.nearing {
                    Label("Nearing limit", systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(.orange)
                }
            }
            if forecast.costPerHour > 0 {
                HStack(spacing: 12) {
                    Text(String(format: "Burn: $%.2f/h", forecast.costPerHour))
                        .font(.subheadline).foregroundStyle(.tertiary).monospacedDigit()
                    Text(String(format: "Projected: %d%%", Int(forecast.projectedFraction * 100)))
                        .font(.subheadline).foregroundStyle(.tertiary).monospacedDigit()
                    if let hitFull = forecast.hitFullAt {
                        Text("Hit 100% at \(resetStr(hitFull))")
                            .font(.subheadline).foregroundStyle(.orange).monospacedDigit()
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func countdown(to date: Date, now: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, sec) }
        if m > 0 { return String(format: "%dm %02ds", m, sec) }
        return "\(sec)s"
    }
}

private struct ContextCard: View {
    @EnvironmentObject var limits: LimitsConfig
    let percentage: Double

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.alignleft").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Context window").font(.title3).bold()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.accent.gradient)
                            .frame(width: max(3, geo.size.width * min(1.0, percentage / 100)))
                    }
                }
                .frame(height: 8)
            }
            Text(limits.percentStyle.format(percentage))
                .font(.title3).bold().monospacedDigit().foregroundStyle(Theme.accent)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct FiveHourBucketsChart: View {
    let entries: [UsageEntry]

    var body: some View {
        let buckets = bucketize()
        Chart(buckets, id: \.start) { b in
            BarMark(
                x: .value("Time", b.start, unit: .minute),
                y: .value("Cost", b.cost)
            )
            .foregroundStyle(Theme.accent.gradient)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text("$\(String(format: "%.1f", d))").font(.subheadline)
                    }
                }
            }
        }
    }

    struct Bucket { let start: Date; let cost: Double }

    private func bucketize() -> [Bucket] {
        guard !entries.isEmpty else { return [] }
        let now = Date()
        let cal = Calendar.current
        let start = cal.date(byAdding: .hour, value: -5, to: now) ?? now
        let bucketMin = 15
        var map: [Date: Double] = [:]
        var t = start
        while t <= now {
            map[t] = 0
            t = cal.date(byAdding: .minute, value: bucketMin, to: t) ?? now.addingTimeInterval(1)
        }
        for e in entries {
            let secs = Int(e.timestamp.timeIntervalSince(start))
            let bucketSec = (secs / (bucketMin * 60)) * (bucketMin * 60)
            let key = start.addingTimeInterval(TimeInterval(bucketSec))
            map[key, default: 0] += e.cost
        }
        return map.map { Bucket(start: $0.key, cost: $0.value) }
            .sorted { $0.start < $1.start }
    }
}

// MARK: - Shared components

struct UsageBarItem: Identifiable {
    let name: String
    let cost: Double
    var id: String { name }
}

private struct UsageBarList: View {
    let items: [UsageBarItem]
    let color: Color
    let totalCost: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if items.isEmpty {
                EmptyHint(text: "No data").padding(.vertical, 8)
            } else {
                ForEach(items) { item in
                    let frac = totalCost > 0 ? item.cost / totalCost : 0
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(String(format: "$%.2f", item.cost))
                                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.12))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(color.gradient)
                                    .frame(width: max(2, geo.size.width * frac))
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
    }
}

private struct DetailRow: View {
    let name: String
    let icon: String
    let iconColor: Color
    let cost: Double
    let fraction: Double
    let entries: [UsageEntry]

    private var tokens: Int {
        entries.reduce(0) { $0 + $1.totalTokens }
    }

    private var cacheRead: Int {
        entries.reduce(0) { $0 + $1.cacheRead }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(iconColor).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.title3).bold().lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text("\(entries.count) reqs").font(.subheadline).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(shortNum(tokens)) tok").font(.subheadline).foregroundStyle(.secondary)
                        if tokens > 0 {
                            Text("·").foregroundStyle(.tertiary)
                            Text(String(format: "cache hit %.0f%%", Double(cacheRead) / Double(tokens) * 100))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Sparkline(entries: entries, color: iconColor).frame(width: 80, height: 24)
                Text(String(format: "$%.2f", cost))
                    .font(.title3).bold().monospacedDigit().foregroundStyle(iconColor)
                Text(String(format: "%.0f%%", fraction * 100))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(iconColor.gradient)
                        .frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 8)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

private struct Sparkline: View {
    let entries: [UsageEntry]
    let color: Color

    var body: some View {
        let series = Aggregator.costSeries(entries, days: 14)
        Chart(series, id: \.date) { item in
            LineMark(
                x: .value("Day", item.date, unit: .day),
                y: .value("Cost", item.cost)
            )
            .foregroundStyle(color.opacity(0.7))
            .interpolationMethod(.monotone)
            AreaMark(
                x: .value("Day", item.date, unit: .day),
                y: .value("Cost", item.cost)
            )
            .foregroundStyle(color.opacity(0.15).gradient)
            .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { p in
            p.background(Color.clear)
        }
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.title2).bold().foregroundStyle(accent).monospacedDigit()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CostOverTimeChart: View {
    let entries: [UsageEntry]

    var body: some View {
        let buckets = Aggregator.byDay(entries)
        let stride = max(1, buckets.count / 6)
        Chart(buckets) { b in
            BarMark(
                x: .value("Day", b.date, unit: .day),
                y: .value("Cost", b.cost)
            )
            .foregroundStyle(Theme.accent.gradient)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: stride)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text("$\(String(format: "%.0f", d))")
                    }
                }
            }
        }
    }
}

private struct EmptyHint: View {
    let text: String
    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private func sectionHeader(_ title: String, icon: String) -> some View {
    Label(title, systemImage: icon)
        .font(.callout).bold()
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
}

fileprivate func shortNum(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    return "\(n)"
}

private func resetStr(_ d: Date) -> String {
    let cal = Calendar.current
    let now = Date()
    let f = DateFormatter()
    if cal.isDateInToday(d) {
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
    if cal.dateComponents([.day], from: now, to: d).day ?? 0 < 7 {
        f.dateFormat = "EEE HH:mm"
        return f.string(from: d)
    }
    f.dateFormat = "MMM d HH:mm"
    return f.string(from: d)
}

private func resetShort(_ d: Date, kind: LimitKind) -> String {
    let cal = Calendar.current
    let f = DateFormatter()
    if kind == .fiveHour || cal.isDateInToday(d) {
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
    f.dateFormat = "EEE HH:mm"
    return f.string(from: d)
}

// MARK: - Integration settings sheet

struct IntegrationSettingsView: View {
    @EnvironmentObject var limits: LimitsConfig
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss
    @State private var msg: String?
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(Theme.accent)
                Text("Wattmeter settings").font(.title2).bold()
                Spacer()
            }

            statusRow

            VStack(alignment: .leading, spacing: 6) {
                Label("Percent display", systemImage: "percent")
                    .font(.callout).bold().foregroundStyle(.secondary)
                Picker("", selection: $limits.percentStyle) {
                    ForEach(PercentStyle.allCases) { s in
                        Text(s.title).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Preview: 5h \(limits.percentStyle.format(18)) · 7d \(limits.percentStyle.format(30))")
                    .font(.subheadline).foregroundStyle(.tertiary).monospacedDigit()
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Tray display", systemImage: "menubar.rectangle")
                    .font(.callout).bold().foregroundStyle(.secondary)
                Picker("", selection: $settings.trayDisplay) {
                    ForEach(TrayDisplay.allCases) { d in
                        Text(d.title).tag(d)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Text("Preview: \(settings.trayDisplay.preview)")
                    .font(.subheadline).foregroundStyle(.tertiary).monospacedDigit()
                Toggle("Colorize tray on warning", isOn: $settings.colorizeTray).font(.callout)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Notifications", systemImage: "bell.fill")
                    .font(.callout).bold().foregroundStyle(.secondary)
                Toggle("Notify on 50/80/100% thresholds", isOn: Binding(
                    get: { NotificationManager.shared.enabled },
                    set: { NotificationManager.shared.enabled = $0 }
                )).font(.callout)
                Toggle("Sound on limit reached", isOn: Binding(
                    get: { NotificationManager.shared.soundOnExceed },
                    set: { NotificationManager.shared.soundOnExceed = $0 }
                )).font(.callout)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("System", systemImage: "gearshape.fill")
                    .font(.callout).bold().foregroundStyle(.secondary)
                Toggle("Launch at login", isOn: $settings.launchAtLogin).font(.callout)
            }

            HStack(spacing: 10) {
                Button {
                    let r = limits.installStatusLineIntegration()
                    isError = false
                    switch r {
                    case .installed:        msg = "Installed. Backup saved next to settings.json. Send a Claude prompt to populate."
                    case .alreadyInstalled: msg = "Already installed."
                    case .settingsMissing:  msg = "Created settings.json with default statusLine."
                    case .noStatusLine:     msg = "Force-installed default statusLine."
                    case .patchFailed:      msg = "Write failed (permissions?)."; isError = true
                    }
                    limits.load()
                } label: {
                    Label("Install / Reinstall", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    let r = limits.removeStatusLineIntegration()
                    isError = false
                    switch r {
                    case .removed:         msg = "Removed."
                    case .notInstalled:    msg = "Not installed."
                    case .settingsMissing: msg = "settings.json not found."; isError = true
                    case .patchFailed:     msg = "Write failed."; isError = true
                    }
                    limits.load()
                } label: {
                    Label("Uninstall", systemImage: "link.badge.plus")
                }

                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if let m = msg {
                Text(m).font(.callout).foregroundStyle(isError ? .red : .secondary)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(limits.isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(limits.isConnected ? "Connected — receiving live data" : (limits.fileMissing ? "No rate_limits.json yet" : "Waiting for data"))
                .font(.callout).bold()
            Spacer()
            if let d = limits.lastUpdated {
                Text("Last: \(d.formatted(date: .omitted, time: .standard))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Onboarding

private struct OnboardingOverlay: View {
    @EnvironmentObject var limits: LimitsConfig
    @EnvironmentObject var settings: AppSettings
    @State private var msg: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 48)).foregroundStyle(Theme.accent)
                Text("Welcome to Wattmeter").font(.title2).bold()
                Text("See your real 5-hour and weekly limits, cost, models, projects, and sessions — straight from Claude Code.")
                    .font(.title3).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 8) {
                    bullet("Live limits read from Claude statusLine", "gauge.with.dots.needle.67percent")
                    bullet("Cost breakdown by model, project, session", "chart.bar.fill")
                    bullet("Threshold notifications + burn-rate forecast", "bell.fill")
                    bullet("Heatmap, sparklines, CSV export", "square.grid.3x3.fill")
                }
                .padding(.horizontal)
                HStack(spacing: 10) {
                    Button {
                        let r = limits.installStatusLineIntegration()
                        switch r {
                        case .installed, .alreadyInstalled, .noStatusLine, .settingsMissing:
                            msg = "Connected — send a Claude prompt to populate."
                            settings.didOnboard = true
                        case .patchFailed:
                            msg = "Couldn't write settings.json (permissions?)."
                        }
                        limits.load()
                    } label: {
                        Label("Connect to Claude limits", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Skip") {
                        settings.didOnboard = true
                    }
                }
                .frame(maxWidth: 320)
                if let m = msg {
                    Text(m).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 20)
            .padding()
        }
    }

    private func bullet(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 22)
            Text(text).font(.callout)
            Spacer()
        }
    }
}
