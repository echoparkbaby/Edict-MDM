import SwiftUI

/// Every device remains visible, including those with no security evidence.
struct MDMSecurityPane: View {
    let devices: [MDMEnrollment]
    let facts: DashboardFacts
    let snapshots: [String: MDMStatusSnapshot]
    let live: [String: MDMSecurityFacts]
    let liveAt: [String: Date]
    let errors: [String: String]
    @Binding var selection: Set<Int>
    let pulling: Bool
    let onRefresh: () -> Void
    @Environment(MunkiReportInventoryStore.self) private var inventory
    @State private var deviceSelection: Set<String> = []
    @State private var filter = "All devices"
    @State private var search = ""

    private let filters = ["All devices", "FileVault off", "Firewall off", "SIP off", "Missing evidence"]
    private var rows: [MDMEnrollment] {
        devices.filter { d in
            let mr = report(d)
            let fv = live[d.id]?.fileVaultEnabled ?? facts.fileVaultOn(for: d)
            let fw = live[d.id]?.firewallEnabled ?? mr?.firewall?.globalstate.map { $0 > 0 }
            let sip = live[d.id]?.sipEnabled.map { $0 ? "On" : "Off" } ?? mr?.security?.sipText ?? "Unknown"
            let scope = filter == "All devices"
                || (filter == "FileVault off" && fv == false)
                || (filter == "Firewall off" && fw == false)
                || (filter == "SIP off" && ["off", "disabled", "0", "false"].contains(sip.lowercased()))
                || (filter == "Missing evidence" && (fv == nil || fw == nil || sip == "Unknown" || errors[d.id] != nil))
            return scope && (search.isEmpty || facts.label(for: d).localizedStandardContains(search)
                             || (d.serialNumber ?? "").localizedStandardContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Show", selection: $filter) { ForEach(filters, id: \.self) { Text($0) } }.frame(maxWidth: 240)
                TextField("Search devices", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Button("Refresh security", systemImage: "arrow.clockwise", action: onRefresh).disabled(pulling)
                if pulling { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 18).padding(.top, 14)
            Text("Observed security controls. Unknown evidence is never treated as a pass. Select a device to inspect or deploy a policy.")
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 18)
            Table(rows, selection: $deviceSelection) {
                TableColumn("Device") { d in
                    Button(facts.label(for: d)) { selection = [facts.hostID(for: d)] }
                        .buttonStyle(.plain)
                }.width(min: 160, ideal: 210)
                TableColumn("FileVault") { d in
                    value(live[d.id]?.fileVaultEnabled ?? facts.fileVaultOn(for: d))
                }.width(min: 65, ideal: 85)
                TableColumn("Firewall") { d in
                    value(live[d.id]?.firewallEnabled ?? report(d)?.firewall?.globalstate.map { $0 > 0 })
                }.width(min: 65, ideal: 85)
                TableColumn("SIP") { d in
                    if let sip = live[d.id]?.sipEnabled { value(sip) }
                    else { Text(report(d)?.security?.sipText ?? "Unknown").foregroundStyle(.secondary) }
                }.width(min: 65, ideal: 85)
                TableColumn("Gatekeeper") { d in
                    Text(report(d)?.security?.gatekeeperText ?? "Unknown").foregroundStyle(.secondary)
                }.width(min: 80, ideal: 110)
                TableColumn("Recovery key") { d in
                    Text(live[d.id]?.personalRecoveryKeyPresent == true ? "Exists; escrow unverified" : "Escrow unverified")
                        .foregroundStyle(.secondary)
                }.width(min: 150, ideal: 170)
                TableColumn("Evidence") { d in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(live[d.id] != nil ? "MDM query · MunkiReport fallback" : "DDM · MunkiReport fallback")
                        if errors[d.id] != nil { Text("Status read failed; last-known values").foregroundStyle(.orange) }
                        if let at = liveAt[d.id] { Text("\(Date().timeIntervalSince(at) > 86400 ? "Stale · " : "")MDM answered \(at.formatted(.relative(presentation: .named)))") }
                        else if let at = report(d)?.reportdata?.lastCheckInDate { Text("Inventory reported \(at.formatted(.relative(presentation: .named)))") }
                        else { Text("Observation time unknown").foregroundStyle(.orange) }
                    }.font(.caption).foregroundStyle(.secondary)
                }.width(min: 170, ideal: 240)
            }
            .onChange(of: deviceSelection) { _, ids in
                selection = Set(devices.filter { ids.contains($0.id) }.map { facts.hostID(for: $0) })
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView.search(text: search.isEmpty ? filter : search)
                }
            }
        }
    }

    private func report(_ device: MDMEnrollment) -> MRHostInventory? {
        guard let serial = device.serialNumber else { return nil }
        return inventory.bySerial[serial]
    }

    @ViewBuilder private func value(_ flag: Bool?) -> some View {
        if let flag {
            Label(flag ? "On" : "Off", systemImage: flag ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(flag ? Color.primary : .orange)
        } else { Label("Unknown", systemImage: "questionmark.circle").foregroundStyle(.secondary) }
    }
}
