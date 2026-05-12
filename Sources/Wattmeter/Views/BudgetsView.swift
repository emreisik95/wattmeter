import SwiftUI

/// Inline protocol — B owns the real `KeychainWebhookStore`. Lead injects an
/// adapter implementing this protocol at integration time.
protocol WebhookKeychainStoring {
    func loadWebhookURL(ref: String) -> String?
    func saveWebhookURL(_ url: String, ref: String) -> Bool
    func deleteWebhookURL(ref: String) -> Bool
}

/// No-op default — used when nothing has been injected yet. Keeps the View
/// renderable in previews/development.
struct NullWebhookStore: WebhookKeychainStoring {
    func loadWebhookURL(ref: String) -> String? { nil }
    func saveWebhookURL(_ url: String, ref: String) -> Bool { false }
    func deleteWebhookURL(ref: String) -> Bool { false }
}

/// Manages a list of `Budget`s. Reads/writes go through `BudgetEvaluator`'s
/// `setBudgets` so the evaluator (owned by B) sees the latest list immediately.
struct BudgetsView: View {
    @EnvironmentObject var evaluator: BudgetEvaluator

    /// Lead can replace via `.environment(\.webhookStore, KeychainWebhookStoreAdapter())`.
    var webhookStore: WebhookKeychainStoring = NullWebhookStore()

    @State private var editing: Budget?
    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
        }
        .sheet(isPresented: $showEditor) {
            BudgetEditor(
                budget: editing,
                webhookStore: webhookStore,
                onSave: { saved in
                    save(saved)
                    showEditor = false
                },
                onCancel: { showEditor = false }
            )
        }
    }

    private var header: some View {
        HStack {
            Label("Budgets", systemImage: "dollarsign.circle.fill")
                .font(.headline).foregroundStyle(Theme.accent)
            Spacer()
            Button {
                editing = nil
                showEditor = true
            } label: {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                if evaluator.budgets.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
                        Text("No budgets configured.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Click \"New\" to create one. Wattmeter notifies you at 50%, 75%, 90%, and 100% of an active budget.")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }
                    .padding(40)
                } else {
                    ForEach(evaluator.budgets) { b in
                        BudgetRow(
                            budget: b,
                            recentEvents: evaluator.lastEvents.filter { $0.budgetId == b.id },
                            onEdit: { editing = b; showEditor = true },
                            onDelete: { remove(b) }
                        )
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    private func save(_ b: Budget) {
        var list = evaluator.budgets
        if let idx = list.firstIndex(where: { $0.id == b.id }) {
            list[idx] = b
        } else {
            list.append(b)
        }
        evaluator.setBudgets(list)
    }

    private func remove(_ b: Budget) {
        if let ref = b.webhookKeychainRef {
            _ = webhookStore.deleteWebhookURL(ref: ref)
        }
        evaluator.setBudgets(evaluator.budgets.filter { $0.id != b.id })
    }
}

private struct BudgetRow: View {
    let budget: Budget
    let recentEvents: [BudgetEvent]
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: budget.hardCap ? "lock.fill" : "bell.fill")
                .foregroundStyle(budget.hardCap ? Color.orange : Theme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(budget.label).font(.callout).bold()
                    Text(windowLabel(budget.window))
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(String(format: "$%.2f", budget.amountUSD)).font(.caption).monospacedDigit()
                    Text("·").foregroundStyle(.tertiary)
                    Text(budget.hardCap ? "Hard cap" : "Notify only")
                        .font(.caption2).foregroundStyle(.secondary)
                    if budget.webhookKeychainRef != nil {
                        Text("·").foregroundStyle(.tertiary)
                        Label("webhook", systemImage: "link")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let last = recentEvents.last {
                    Text("Last: \(eventKindLabel(last.kind)) · \(Int(last.percent))% · \(last.timestamp.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            Spacer()
            Button { onEdit() } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")
            Button { onDelete() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Delete")
        }
        .padding(.vertical, 10)
    }

    private func windowLabel(_ w: BudgetWindow) -> String {
        switch w {
        case .daily:   return "DAILY"
        case .weekly:  return "WEEKLY"
        case .session: return "SESSION"
        }
    }

    private func eventKindLabel(_ k: BudgetEvent.Kind) -> String {
        switch k {
        case .crossed50: return "50%"
        case .crossed75: return "75%"
        case .crossed90: return "90%"
        case .exceeded:  return "exceeded"
        case .anomaly:   return "anomaly"
        }
    }
}

/// Modal form for create + edit.
private struct BudgetEditor: View {
    @Environment(\.dismiss) var dismiss
    let initial: Budget?
    let webhookStore: WebhookKeychainStoring
    let onSave: (Budget) -> Void
    let onCancel: () -> Void

    @State private var label: String
    @State private var amount: String
    @State private var window: BudgetWindow
    @State private var hardCap: Bool
    @State private var webhookURL: String
    @State private var webhookRef: String?

    init(budget: Budget?, webhookStore: WebhookKeychainStoring,
         onSave: @escaping (Budget) -> Void, onCancel: @escaping () -> Void) {
        self.initial = budget
        self.webhookStore = webhookStore
        self.onSave = onSave
        self.onCancel = onCancel
        _label = State(initialValue: budget?.label ?? "Daily limit")
        _amount = State(initialValue: budget.map { String(format: "%.2f", $0.amountUSD) } ?? "5.00")
        _window = State(initialValue: budget?.window ?? .daily)
        _hardCap = State(initialValue: budget?.hardCap ?? false)
        _webhookRef = State(initialValue: budget?.webhookKeychainRef)
        let existing = budget?.webhookKeychainRef.flatMap { webhookStore.loadWebhookURL(ref: $0) } ?? ""
        _webhookURL = State(initialValue: existing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "dollarsign.circle.fill").foregroundStyle(Theme.accent)
                Text(initial == nil ? "New budget" : "Edit budget").font(.title3).bold()
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Label").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. Daily limit", text: $label)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Amount (USD)").font(.caption).foregroundStyle(.secondary)
                    TextField("5.00", text: $amount)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Window").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $window) {
                        Text("Daily").tag(BudgetWindow.daily)
                        Text("Weekly").tag(BudgetWindow.weekly)
                        Text("Session").tag(BudgetWindow.session)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
            }
            Toggle("Hard cap (writes sentinel file at 100%)", isOn: $hardCap).font(.caption)
            VStack(alignment: .leading, spacing: 6) {
                Text("Webhook URL (Slack/Discord, optional)").font(.caption).foregroundStyle(.secondary)
                TextField("https://hooks.slack.com/…", text: $webhookURL)
                    .textFieldStyle(.roundedBorder)
                Text("Stored securely in Keychain.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button(initial == nil ? "Create" : "Save") { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(amountValue == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var amountValue: Double? {
        let cleaned = amount.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
        return Double(cleaned).flatMap { $0 > 0 ? $0 : nil }
    }

    private func commit() {
        guard let amt = amountValue else { return }
        // Persist webhook in keychain if URL provided.
        var ref = webhookRef
        let trimmed = webhookURL.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let key = ref ?? "budget-\(UUID().uuidString)"
            _ = webhookStore.saveWebhookURL(trimmed, ref: key)
            ref = key
        } else if let oldRef = ref {
            _ = webhookStore.deleteWebhookURL(ref: oldRef)
            ref = nil
        }

        let id = initial?.id ?? UUID()
        let b = Budget(
            id: id,
            label: label.isEmpty ? "Untitled" : label,
            amountUSD: amt,
            window: window,
            hardCap: hardCap,
            webhookKeychainRef: ref
        )
        onSave(b)
    }
}
