import SwiftUI

struct MDMActivityView: View {
    var initialTab = "Commands"
    @State private var tab = "Commands"
    @State private var search = ""
    @Environment(MDMCommandStore.self) private var commands
    @Environment(MDMFleetIndex.self) private var fleet
    @Environment(ActivityLog.self) private var activity
    @EnvironmentObject private var settings: SettingsStore

    private var rows: [MDMCommandStore.Entry] {
        commands.entries.filter {
            $0.server == settings.nanoMDMBaseURL && (!fleet.activityPendingOnly || $0.state.isPending)
                && (search.isEmpty || $0.kind.localizedStandardContains(search)
                    || deviceName($0.target).localizedStandardContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity").font(.title2.bold())
                Spacer()
                Picker("Activity", selection: $tab) {
                    Text("Commands").tag("Commands")
                    Text("Automation").tag("Automation")
                    Text("Session log").tag("Session log")
                }.pickerStyle(.segmented).frame(maxWidth: 420)
            }.padding(18)
            Divider()
            switch tab {
            case "Automation": SchedulingView()
            case "Session log":
                List(activity.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title)
                        if let detail = entry.detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
                        Text(entry.timestamp, style: .time).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            default: commandTable
            }
        }
        .onAppear { tab = initialTab }
        .task { await commands.refresh(settings: settings) }
    }

    private var commandTable: some View {
        @Bindable var fleet = fleet
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search commands or devices", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Toggle("Pending only", isOn: $fleet.activityPendingOnly)
                Spacer()
                Button("Refresh results", systemImage: "arrow.clockwise") {
                    Task { await commands.refresh(settings: settings) }
                }.disabled(commands.refreshing)
            }.padding(.horizontal, 18).padding(.top, 14)
            Text("Server acceptance is a queued command. Acknowledged means the device processed it; verify ongoing policy effects from reported state.")
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 18)
            if let error = commands.errorText {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).padding(.horizontal, 18)
            }
            Table(rows) {
                TableColumn("Device") { entry in Text(deviceName(entry.target)) }.width(min: 140, ideal: 210)
                TableColumn("Command") { Text($0.kind) }.width(min: 130, ideal: 170)
                TableColumn("Result") { entry in
                    Label(entry.state.rawValue, systemImage: entry.state == .failed ? "exclamationmark.triangle" : (entry.state == .acknowledged ? "checkmark.circle" : "clock"))
                        .foregroundStyle(entry.state == .failed ? Color.orange : .primary)
                }.width(min: 150, ideal: 180)
                TableColumn("Sent") { Text($0.createdAt, style: .relative) }.width(min: 90, ideal: 110)
                TableColumn("Detail") { Text($0.detail ?? "Awaiting a device response.").foregroundStyle(.secondary) }.width(min: 180, ideal: 320)
            }.overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No matching commands", systemImage: "clock.arrow.circlepath",
                                           description: Text("New commands are tracked here. Existing server history is not imported."))
                }
            }
        }
    }

    private func deviceName(_ id: String) -> String {
        fleet.names[id] ?? settings.mdmDevices.first { $0.id == id }?.label
            ?? fleet.devices.first { $0.id == id }?.serialNumber ?? id
    }
}
