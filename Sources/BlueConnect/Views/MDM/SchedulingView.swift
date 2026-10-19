import SwiftUI

/// Edict MDM scheduling — recurring automation that runs while the console
/// is open. Add tasks (fleet checks, FileVault remediation, profile drift
/// correction), set an interval, and Edict runs them on its own.
struct SchedulingView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(MDMScheduler.self) private var scheduler

    @State private var editing: ScheduledTask?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if settings.scheduledTasks.isEmpty {
                empty
            } else {
                List {
                    ForEach(settings.scheduledTasks) { t in row(t) }
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: $editing) { t in
            ScheduledTaskEditor(task: t) { saved in
                var list = settings.scheduledTasks
                if let idx = list.firstIndex(where: { $0.id == saved.id }) { list[idx] = saved }
                else { list.append(saved) }
                settings.scheduledTasks = list
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Scheduling").font(.headline)
            Text("\(settings.scheduledTasks.count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let a = scheduler.lastActivity {
                Text(a).font(.caption).foregroundStyle(.secondary)
            }
            Button { Task { await scheduler.tick() } } label: { Label("Run due now", systemImage: "bolt") }
                .help("Run any tasks that are due right now")
            Button { editing = ScheduledTask(name: "New task", kind: .fleetCheck) } label: {
                Label("New Task", systemImage: "plus")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.checkmark").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("No scheduled tasks").font(.headline)
            Text("Add automation that runs while Edict is open — periodic fleet checks, FileVault remediation, or re-applying a profile to a group to correct drift.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Text("Tasks run only while the app is running. Leave it open on an always-on Mac for unattended automation.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ t: ScheduledTask) -> some View {
        HStack(spacing: 10) {
            Toggle(t.name, isOn: Binding(
                get: { t.enabled },
                set: { v in update(t) { $0.enabled = v } }
            )).labelsHidden().toggleStyle(.switch).controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.name)
                Text("\(t.kind.rawValue) · every \(intervalLabel(t.intervalHours))"
                     + (t.lastRun.map { " · last \($0.formatted(.relative(presentation: .named)))" } ?? " · never run"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit \(t.name)", systemImage: "pencil") { editing = t }
                .labelStyle(.iconOnly).buttonStyle(.plain)
            Button("Delete \(t.name)", systemImage: "trash", role: .destructive) {
                settings.scheduledTasks.removeAll { $0.id == t.id }
            }
            .labelStyle(.iconOnly).buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private func intervalLabel(_ h: Double) -> String {
        h < 1 ? "\(Int(h * 60)) min" : (h == 1 ? "hour" : "\(Int(h)) h")
    }

    private func update(_ t: ScheduledTask, _ change: (inout ScheduledTask) -> Void) {
        var list = settings.scheduledTasks
        guard let idx = list.firstIndex(where: { $0.id == t.id }) else { return }
        change(&list[idx])
        settings.scheduledTasks = list
    }
}

private struct ScheduledTaskEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @State var task: ScheduledTask
    let onSave: (ScheduledTask) -> Void

    @State private var savedProfiles: [SavedProfile] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scheduled Task").font(.headline)
            Form {
                TextField("Name", text: $task.name)
                Picker("Do", selection: $task.kind) {
                    ForEach(ScheduledTask.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                Text(task.kind.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Every", selection: $task.intervalHours) {
                    Text("1 hour").tag(1.0); Text("6 hours").tag(6.0)
                    Text("12 hours").tag(12.0); Text("Daily").tag(24.0)
                }
                if task.kind == .reapplyProfile {
                    Picker("Group", selection: $task.groupID) {
                        Text("Choose a group").tag(Optional<UUID>.none)
                        ForEach(settings.smartGroups) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("Profile", selection: $task.savedProfileID) {
                        Text("Choose a profile").tag(Optional<UUID>.none)
                        ForEach(savedProfiles) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(task); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(task.name.trimmingCharacters(in: .whitespaces).isEmpty || !taskValid)
            }
        }
        .padding(20).frame(width: 460)
        .onAppear { savedProfiles = SavedProfilesStore.load() }
    }

    private var taskValid: Bool {
        task.kind != .reapplyProfile || (task.groupID != nil && task.savedProfileID != nil)
    }
}
