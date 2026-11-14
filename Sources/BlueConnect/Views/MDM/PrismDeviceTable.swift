import SwiftUI
import AppKit

enum DeviceSortKey: String { case name, serial, model, os, fileVault, compliance, lastSeen }

/// One column of the device table (Device is always shown; the rest are
/// reorderable per layout and hideable via the column menu).
struct DeviceColumn: Identifiable {
    let key: String
    let title: String
    let width: CGFloat
    let sort: DeviceSortKey?
    var id: String { key }
}

/// The dashboard's Devices / Security table — a horizontally scrolling,
/// sortable, column-configurable device list with a natural-language
/// search box. Extracted from `GroupDashboardView` so its search / sort /
/// hover / column state lives here and doesn't re-render the rest of the
/// dashboard.
struct PrismDeviceTable: View {
    let title: String
    let security: Bool
    /// Devices in scope (already filtered to the selected smart group).
    let devices: [MDMEnrollment]
    let facts: DashboardFacts
    @Binding var selection: Set<Int>
    let enablingAll: Bool
    let onEnableReporting: () -> Void

    @Binding var tableSearch: String
    @AppStorage("mdmDeviceSortKey") private var sortKey: DeviceSortKey = .name
    @AppStorage("mdmDeviceSortAscending") private var sortAsc = true
    @State private var hoveredRow: String?
    @AppStorage("prismHiddenColumns") private var hiddenColumnsRaw = ""
    /// User-dragged column widths, keyed by column key ("device" is the name
    /// column). Persisted so a resized layout survives relaunch. Columns not
    /// in the map fall back to their natural width.
    @AppStorage("prismColWidthsJSON") private var colWidthsRaw = ""
    /// Width captured at the start of a drag so cumulative translation isn't
    /// re-applied to an already-updated width (which would run away).
    @State private var resizeStart: CGFloat?
    /// The column being dragged right now + its live width. Kept in memory so
    /// the drag is smooth (no per-tick disk write); persisted once on release.
    @State private var liveResize: (key: String, width: CGFloat)?

    @State private var exportError: String?

    // Row control-click menu.
    @EnvironmentObject private var settings: SettingsStore
    @Environment(MDMFleetIndex.self) private var fleet
    @AppStorage("connectPanelVisible") private var connectPanelVisible = true
    @AppStorage("connectPanelTab") private var connectPanelTab = "mdm"
    @State private var actionError: String?
    @Environment(ActivityLog.self) private var activity
    /// Brief "it worked" line at the bottom of the table; clears itself.
    @State private var notice: String?
    @State private var lockTarget: MDMEnrollment?
    @State private var restartTarget: MDMEnrollment?
    @State private var unenrollTarget: MDMEnrollment?

    /// The persisted width map, decoded once per body (not per cell).
    private var savedWidths: [String: Double] {
        guard let data = colWidthsRaw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return map
    }
    private func width(for key: String, default def: CGFloat, in map: [String: Double]) -> CGFloat {
        if let lr = liveResize, lr.key == key { return lr.width }
        return map[key].map { CGFloat($0) } ?? def
    }
    private func setWidth(_ key: String, to newWidth: CGFloat) {
        var map: [String: Double] = [:]
        if let data = colWidthsRaw.data(using: .utf8),
           let m = try? JSONDecoder().decode([String: Double].self, from: data) { map = m }
        map[key] = Double(max(48, newWidth))
        if let data = try? JSONEncoder().encode(map), let s = String(data: data, encoding: .utf8) {
            colWidthsRaw = s
        }
    }

    /// A thin draggable divider on a header cell's trailing edge. Height is
    /// fixed so the handle can't stretch vertically and inflate the header row.
    private func resizeHandle(key: String, currentWidth: CGFloat) -> some View {
        Color.clear.frame(width: 8, height: 14)
            .overlay(Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1))
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .trailing))
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if resizeStart == nil { resizeStart = currentWidth }
                    liveResize = (key, max(48, (resizeStart ?? currentWidth) + v.translation.width))
                }
                .onEnded { _ in
                    if let lr = liveResize { setWidth(lr.key, to: lr.width) }
                    liveResize = nil; resizeStart = nil
                })
            .accessibilityHidden(true)
    }

    var body: some View {
        // Filter/sort and width decode once per render — hover re-runs body.
        let rows = self.rows
        let widths = savedWidths
        VStack(spacing: 0) {
            toolbar(count: rows.count)
            // Fixed-width columns inside a horizontal scroll so a wide
            // table scrolls instead of forcing the whole window layout to
            // shift; the column header stays put while rows scroll down.
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    tableHeader(widths)
                    Divider()
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(rows, id: \.id) { d in
                                tableRow(d, widths)
                                Divider().opacity(0.4)
                            }
                        }
                    }
                    .deviceArrowKeys(rows.map { facts.hostID(for: $0) },
                                     selected: rows.map { facts.hostID(for: $0) }.first(where: selection.contains),
                                     select: { selection = [$0] })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Couldn't save CSV", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportError ?? "") }
        .alert("Couldn't complete that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
        .overlay(alignment: .bottom) {
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(3))
                        if !Task.isCancelled { self.notice = nil }
                    }
            }
        }
        .sheet(item: $lockTarget) { d in
            LockDeviceSheet(deviceName: facts.label(for: d)) { pin, message in
                await perform("Lock command sent", [d]) {
                    _ = try await NanoMDMService(settings: settings).lock(enrollmentID: d.id, pin: pin, message: message)
                    _ = try? await NanoMDMService(settings: settings).push(enrollmentIDs: d.id)
                }
            }
        }
        .alert("Restart \(restartTarget.map(facts.label(for:)) ?? "")?",
               isPresented: Binding(get: { restartTarget != nil }, set: { if !$0 { restartTarget = nil } }),
               presenting: restartTarget) { d in
            Button("Cancel", role: .cancel) {}
            Button("Restart", role: .destructive) {
                Task { await perform("Restart command sent", [d]) {
                    _ = try await NanoMDMService(settings: settings).restart(enrollmentID: d.id)
                    _ = try? await NanoMDMService(settings: settings).push(enrollmentIDs: d.id)
                } }
            }
        } message: { _ in Text("The Mac restarts when it receives the command. Unsaved work may be lost. It must be online now.") }
        .alert("Remove \(unenrollTarget.map(facts.label(for:)) ?? "") from MDM?",
               isPresented: Binding(get: { unenrollTarget != nil }, set: { if !$0 { unenrollTarget = nil } }),
               presenting: unenrollTarget) { d in
            Button("Cancel", role: .cancel) {}
            Button("Unenroll", role: .destructive) {
                Task { await perform("Unenroll command sent", [d]) {
                    _ = try await NanoMDMService(settings: settings).unenroll(enrollmentID: d.id, profileIdentifier: settings.mdmEnrollmentProfileID)
                    _ = try? await NanoMDMService(settings: settings).push(enrollmentIDs: d.id)
                } }
            }
        } message: { _ in
            Text("Sends RemoveProfile for the enrollment profile. The Mac drops management, declarations, and its MDM certificate the moment it receives the push. It must be online.")
        }
    }

    private func toolbar(count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.title3.bold())
            Text("\(count)").font(.callout).foregroundStyle(.secondary)
            Spacer()
            if devices.contains(where: { facts.osVersions[$0.id] == nil }) {
                Button { onEnableReporting() } label: {
                    if enablingAll { ProgressView().controlSize(.small) }
                    else { Label("Enable reporting", systemImage: "antenna.radiowaves.left.and.right") }
                }
                .controlSize(.small)
                .help("Subscribe every device in scope to report OS, model, and FileVault so these columns fill in.")
            }
            Menu {
                ForEach(allDeviceColumns) { col in
                    Toggle(col.title, isOn: Binding(
                        get: { !hiddenColumns.contains(col.key) },
                        set: { _ in toggleColumn(col.key) }))
                }
            } label: { Image(systemName: "slider.horizontal.3") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Show / hide columns")
            .accessibilityLabel("Show or hide columns")
            Button { exportCSV() } label: { Image(systemName: "square.and.arrow.up") }
                .help("Export this view as CSV")
                .accessibilityLabel("Export this view as CSV")
            HStack(spacing: 5) {
                Image(systemName: "sparkle.magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Search", text: $tableSearch).textFieldStyle(.plain).frame(width: 230)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
    }

    // MARK: - Columns

    /// Every toggleable device column (Device is always shown).
    private var allDeviceColumns: [DeviceColumn] {
        [DeviceColumn(key: "serial", title: "Serial", width: 116, sort: .serial),
         DeviceColumn(key: "model", title: "Model", width: 138, sort: .model),
         DeviceColumn(key: "os", title: "macOS", width: 66, sort: .os),
         DeviceColumn(key: "fv", title: "FileVault", width: 84, sort: .fileVault),
         DeviceColumn(key: "compliance", title: "Baseline", width: 140, sort: .compliance),
         DeviceColumn(key: "lastSeen", title: "Last check-in", width: 104, sort: .lastSeen)]
    }
    private var hiddenColumns: Set<String> { Set(hiddenColumnsRaw.split(separator: ",").map(String.init)) }
    private func toggleColumn(_ key: String) {
        var set = hiddenColumns
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        hiddenColumnsRaw = set.sorted().joined(separator: ",")
    }
    /// Ordered, visible columns for the current layout.
    private var visibleColumns: [DeviceColumn] {
        let order = security
            ? ["serial", "fv", "compliance", "os", "lastSeen"]
            : ["serial", "model", "os", "fv", "compliance", "lastSeen"]
        return order.compactMap { key in allDeviceColumns.first { $0.key == key } }
            .filter { !hiddenColumns.contains($0.key) }
    }

    // MARK: - Header + rows

    private func tableHeader(_ widths: [String: Double]) -> some View {
        HStack(spacing: 12) {
            let deviceW = width(for: "device", default: 230, in: widths)
            HStack(spacing: 0) {
                sortHeader("Device", .name).frame(width: max(40, deviceW) - 8, alignment: .leading)
                resizeHandle(key: "device", currentWidth: deviceW)
            }
            ForEach(visibleColumns) { col in
                let w = width(for: col.key, default: col.width, in: widths)
                HStack(spacing: 0) {
                    Group {
                        if let s = col.sort { sortHeader(col.title, s) } else { Text(col.title) }
                    }.frame(width: max(40, w) - 8, alignment: .leading)
                    resizeHandle(key: col.key, currentWidth: w)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 5)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func tableRow(_ d: MDMEnrollment, _ widths: [String: Double]) -> some View {
        let hovered = hoveredRow == d.id
        let selected = selection.contains(facts.hostID(for: d))
        return Button {
            let id = facts.hostID(for: d)
            if NSEvent.modifierFlags.contains(.command) {
                if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            } else { selection = [id] }
        } label: {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: facts.deviceIcon(d)).font(.caption).foregroundStyle(Color.accentColor).frame(width: 16)
                Text(facts.label(for: d)).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
            }
            .frame(width: width(for: "device", default: 230, in: widths), alignment: .leading)
            ForEach(visibleColumns) { col in
                deviceCell(col, d).frame(width: width(for: col.key, default: col.width, in: widths), alignment: .leading)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.18)
                    : (hovered ? Color.accentColor.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredRow = $0 ? d.id : (hoveredRow == d.id ? nil : hoveredRow) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(facts.label(for: d))
        .contextMenu { rowMenu(d) }
    }

    /// The rows a menu action applies to: every selected row when the
    /// clicked row is part of a multi-selection, otherwise just that row.
    private func targets(_ d: MDMEnrollment) -> [MDMEnrollment] {
        guard selection.count > 1, selection.contains(facts.hostID(for: d)) else { return [d] }
        return rows.filter { selection.contains(facts.hostID(for: $0)) }
    }

    /// Safe one-shot actions up top. Restart / lock / unenroll sit under
    /// "More", one Mac at a time, each behind a confirmation. Erase stays in
    /// the device details panel only.
    @ViewBuilder
    private func rowMenu(_ d: MDMEnrollment) -> some View {
        let ts = targets(d)
        let many = ts.count > 1
        let suffix = many ? " (\(ts.count) Macs)" : ""
        Button("Check In Now" + suffix) {
            Task { await perform("Check-in requested", ts) {
                _ = try await NanoMDMService(settings: settings).push(enrollmentIDs: ts.map(\.id).joined(separator: ","))
            } }
        }
        if !many {
            Button("Open Device Details") {
                selection = [facts.hostID(for: d)]
                connectPanelTab = "mdm"
                connectPanelVisible = true
            }
        }
        let serials = ts.compactMap(\.serialNumber).filter { !$0.isEmpty }
        Button(many ? "Copy Serial Numbers" + suffix : "Copy Serial Number") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(serials.joined(separator: "\n"), forType: .string)
        }
        .disabled(serials.isEmpty)
        Button(many ? "Refresh These Macs" + suffix : "Refresh This Mac") {
            Task {
                for t in ts { await fleet.refreshDevice(t.id, settings: settings) }
                let failed = ts.filter { fleet.errors[$0.id] != nil }
                if let first = failed.first {
                    actionError = failed.count == 1
                        ? "\(facts.label(for: first)): \(fleet.errors[first.id] ?? "")"
                        : "\(failed.count) of \(ts.count) Macs couldn't be refreshed. First: \(facts.label(for: first)) — \(fleet.errors[first.id] ?? "")"
                } else {
                    notice = many ? "Refreshed \(ts.count) Macs" : "Refreshed \(facts.label(for: d))"
                }
            }
        }
        let eligible = ts.filter(canEnableReporting)
        if !eligible.isEmpty {
            Button("Enable Reporting" + (many ? " (\(eligible.count) Macs)" : "")) {
                Task { await perform("Reporting subscription assigned", eligible) {
                    let configID = "com.hellocomputer.edict.status-subscriptions"
                    let kmf = KMFDDMService(settings: settings)
                    try await kmf.deploy(configJSON: DDMDeclarations.statusSubscriptions(identifier: configID),
                                         configID: configID, toSet: "default")
                    for t in eligible { try await kmf.assign(enrollmentID: t.id, toSet: "default") }
                    for t in eligible { await fleet.refreshDevice(t.id, settings: settings) }
                } }
            }
        }
        Divider()
        let allHidden = ts.allSatisfy { settings.isIgnoredForAttention($0.id) }
        Button((allHidden ? "Unhide from Needs Attention" : "Hide from Needs Attention") + suffix) {
            for t in ts { settings.setIgnoredForAttention(t.id, !allHidden) }
        }
        if !many, d.isEnabled {
            Divider()
            Menu("More") {
                Button("Restart…") { restartTarget = d }
                Button("Lock…") { lockTarget = d }
                Button("Unenroll…", role: .destructive) { unenrollTarget = d }
            }
        }
    }

    /// Offered only when MDM has no facts for the Mac and it isn't known to
    /// be too old to send them (DDM status needs macOS 13).
    private func canEnableReporting(_ d: MDMEnrollment) -> Bool {
        guard d.isEnabled, fleet.snapshots[d.id]?.hasData != true else { return false }
        guard let major = facts.osVersions[d.id]?.split(separator: ".").first.flatMap({ Int($0) }) else { return true }
        return major >= 13
    }

    /// Run a menu action; on success show a brief confirmation and write
    /// the Activity log, on failure show the reason.
    private func perform(_ title: String, _ ts: [MDMEnrollment], _ work: () async throws -> Void) async {
        let who = ts.count > 1 ? "\(ts.count) Macs" : ts.first.map(facts.label(for:)) ?? ""
        do {
            try await work()
            activity.record(.category, title: title, detail: ts.map(facts.label(for:)).joined(separator: ", "))
            notice = "\(title) — \(who)"
        } catch { actionError = error.localizedDescription }
    }

    @ViewBuilder
    private func deviceCell(_ col: DeviceColumn, _ d: MDMEnrollment) -> some View {
        switch col.key {
        case "serial": Text(d.serialNumber ?? "—").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case "model": Text(facts.models[d.id] ?? "—").font(.callout).foregroundStyle(facts.models[d.id] == nil ? .secondary : .primary).lineLimit(1).help(facts.sourceNote(d.id, "model"))
        case "os": Text(facts.osVersions[d.id] ?? "—").font(.callout).foregroundStyle(facts.osVersions[d.id] == nil ? .secondary : .primary).help(facts.sourceNote(d.id, "os"))
        case "fv": fvCell(d).help(facts.sourceNote(d.id, "fv"))
        case "compliance": complianceCell(d)
        case "lastSeen": Text(facts.lastSeenText(d)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        default: EmptyView()
        }
    }

    @ViewBuilder private func fvCell(_ d: MDMEnrollment) -> some View {
        switch facts.fileVaultOn(for: d) {
        case .some(true): pill("On", .green)
        case .some(false): pill("Off", .red)
        case nil: Text("—").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func complianceCell(_ d: MDMEnrollment) -> some View {
        switch facts.compliant(for: d) {
        case .some(true): pill("Meets baseline", .green)
        case .some(false): pill("Outside baseline", .orange)
        case nil: pill("Unknown", .gray)
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private func sortHeader(_ title: String, _ key: DeviceSortKey) -> some View {
        Button {
            if sortKey == key { sortAsc.toggle() } else { sortKey = key; sortAsc = true }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if sortKey == key { Image(systemName: sortAsc ? "chevron.up" : "chevron.down").font(.system(size: 8)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data

    /// Scoped devices, filtered by the search box and sorted by the active
    /// column.
    private var rows: [MDMEnrollment] {
        var rows = devices
        let q = tableSearch.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { rows = rows.filter { facts.matchesQuery($0, q) } }
        func rank(_ d: MDMEnrollment) -> Int {
            switch facts.compliant(for: d) {
            case .some(true): return 0; case .some(false): return 1; case nil: return 2
            }
        }
        func fvRank(_ d: MDMEnrollment) -> Int {
            switch facts.fileVaultOn(for: d) { case .some(true): return 0; case .some(false): return 1; case nil: return 2 }
        }
        // Strict less-than per key. Descending swaps operands (never !less):
        // negating a non-strict comparison returns true both ways on ties,
        // violating strict-weak-ordering and trapping sort(). Same fix as
        // InventoryRowSort.
        func less(_ a: MDMEnrollment, _ b: MDMEnrollment) -> Bool {
            switch sortKey {
            case .name: return facts.label(for: a).localizedCaseInsensitiveCompare(facts.label(for: b)) == .orderedAscending
            case .serial: return (a.serialNumber ?? "").localizedCaseInsensitiveCompare(b.serialNumber ?? "") == .orderedAscending
            case .model: return (facts.models[a.id] ?? "~").localizedCaseInsensitiveCompare(facts.models[b.id] ?? "~") == .orderedAscending
            case .os: return facts.osRank(facts.osVersions[a.id]) < facts.osRank(facts.osVersions[b.id])
            case .fileVault: return fvRank(a) < fvRank(b)
            case .compliance: return rank(a) < rank(b)
            case .lastSeen: return (a.lastSeenDate ?? .distantPast) < (b.lastSeenDate ?? .distantPast)
            }
        }
        rows.sort { a, b in sortAsc ? less(a, b) : less(b, a) }
        return rows
    }

    private func exportCSV() {
        let cols = security
            ? ["Device", "Serial", "FileVault", "Compliance", "macOS", "Last check-in"]
            : ["Device", "Serial", "Model", "macOS", "FileVault", "Compliance", "Last check-in"]
        func fv(_ d: MDMEnrollment) -> String {
            switch facts.fileVaultOn(for: d) { case .some(true): return "On"; case .some(false): return "Off"; case nil: return "" } }
        func comp(_ d: MDMEnrollment) -> String {
            switch facts.compliant(for: d) {
            case .some(true): return "Compliant"; case .some(false): return "Out"; case nil: return "Unknown" } }
        let outRows = rows.map { d -> [String] in
            security
                ? [facts.label(for: d), d.serialNumber ?? "", fv(d), comp(d), facts.osVersions[d.id] ?? "", facts.lastSeenText(d)]
                : [facts.label(for: d), d.serialNumber ?? "", facts.models[d.id] ?? "", facts.osVersions[d.id] ?? "", fv(d), comp(d), facts.lastSeenText(d)]
        }
        do { try TableCSVExport.save(filename: "\(title).csv", columns: cols, rows: outRows) }
        catch { exportError = error.localizedDescription }
    }
}
