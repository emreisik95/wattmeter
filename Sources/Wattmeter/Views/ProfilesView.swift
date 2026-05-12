import SwiftUI
import AppKit

/// F5 — list/create/edit/delete profiles (Claude data directories).
struct ProfilesView: View {
    @EnvironmentObject var profiles: ProfileManager
    @State private var editing: UsageProfile?
    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
        }
        .sheet(isPresented: $showEditor) {
            ProfileEditor(
                initial: editing,
                onSave: { p in
                    if editing == nil {
                        profiles.addAndSave(label: p.label, claudeDir: p.claudeDir)
                    } else {
                        profiles.update(p.id, label: p.label, claudeDir: p.claudeDir)
                    }
                    showEditor = false
                },
                onCancel: { showEditor = false }
            )
        }
    }

    private var header: some View {
        HStack {
            Label("Profiles", systemImage: "person.crop.circle.fill")
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
                if profiles.profiles.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.title2).foregroundStyle(.tertiary)
                        Text("No profiles yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(40)
                } else {
                    ForEach(profiles.profiles) { p in
                        ProfileRow(
                            profile: p,
                            isActive: p.id == profiles.activeID,
                            onSelect: { profiles.setActiveAndSave(p.id) },
                            onEdit: { editing = p; showEditor = true },
                            onDelete: { profiles.removeAndSave(p.id) }
                        )
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }
}

/// A compact chip used inside the dashboard header.
struct ProfileChip: View {
    @EnvironmentObject var profiles: ProfileManager
    var body: some View {
        if let activeID = profiles.activeID,
           let active = profiles.profiles.first(where: { $0.id == activeID }),
           profiles.profiles.count > 1 {
            Menu {
                ForEach(profiles.profiles) { p in
                    Button {
                        profiles.setActiveAndSave(p.id)
                    } label: {
                        if p.id == activeID {
                            Label(p.label, systemImage: "checkmark")
                        } else {
                            Text(p.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle.fill").font(.caption2)
                    Text(active.label).font(.caption2).bold().lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Theme.accent.opacity(0.15), in: Capsule())
                .foregroundStyle(Theme.accent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Active profile")
        }
    }
}

private struct ProfileRow: View {
    let profile: UsageProfile
    let isActive: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Theme.accent : Color.secondary)
                .frame(width: 18)
                .onTapGesture { onSelect() }
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.label).font(.callout).bold()
                Text(profile.claudeDir.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .monospaced()
            }
            Spacer()
            if isActive {
                Text("ACTIVE")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.15), in: Capsule())
                    .foregroundStyle(Theme.accent)
            }
            Button { onEdit() } label: {
                Image(systemName: "pencil")
            }.buttonStyle(.borderless).help("Edit")
            Button { onDelete() } label: {
                Image(systemName: "trash")
            }.buttonStyle(.borderless).foregroundStyle(.red).help("Delete")
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onSelect() }
    }
}

private struct ProfileEditor: View {
    @Environment(\.dismiss) var dismiss
    let initial: UsageProfile?
    let onSave: (UsageProfile) -> Void
    let onCancel: () -> Void

    @State private var label: String
    @State private var pathString: String

    init(initial: UsageProfile?, onSave: @escaping (UsageProfile) -> Void, onCancel: @escaping () -> Void) {
        self.initial = initial
        self.onSave = onSave
        self.onCancel = onCancel
        _label = State(initialValue: initial?.label ?? "")
        _pathString = State(initialValue: initial?.claudeDir.path
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(Theme.accent)
                Text(initial == nil ? "New profile" : "Edit profile").font(.title3).bold()
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Label").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. Work", text: $label)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude data directory").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("/Users/you/.claude", text: $pathString)
                        .textFieldStyle(.roundedBorder)
                        .monospaced()
                    Button("Choose…") { pickFolder() }
                }
                Text("Wattmeter reads JSONL transcripts from `<dir>/projects/**/*.jsonl`.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button(initial == nil ? "Create" : "Save") { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select your Claude data directory (typically ~/.claude)"
        if panel.runModal() == .OK, let url = panel.url {
            pathString = url.path
        }
    }

    private func commit() {
        let url = URL(fileURLWithPath: (pathString as NSString).expandingTildeInPath)
        let id = initial?.id ?? UUID()
        onSave(UsageProfile(id: id, label: label, claudeDir: url))
    }
}
