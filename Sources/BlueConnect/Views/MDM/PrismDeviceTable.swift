import SwiftUI
import AppKit

enum DeviceSortKey { case name, model, os, fileVault, compliance, lastSeen }

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

    @State private var tableSearch = ""
    @State private var sortKey: DeviceSortKey = .name
    @State private var sortAsc = true
    @State private var hoveredRow: String?
    @AppStorage("prismHiddenColumns") private var hiddenColumnsRaw = ""
    /// User-dragged column widths, keyed by column key ("device" is the name
    /// column). Persisted so a resized layout survives relaunch. Columns not
    /// in the map fall back to their natural width.
    @AppStorage("prismColWidthsJSON") private var colWidthsRaw = ""
    /// Width captured at the start of a drag so cumulative translation isn't
    /// re-applied to an already-updated width (which would run away).
    @State private var resizeStart: CGFloat?

    private func width(for key: String, default def: CGFloat) -> CGFloat {
        guard let data = colWidthsRaw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: Double].self, from: data),
              let w = map[key] else { return def }
        return CGFloat(w)
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

    /// A thin draggable divider on a header cell's trailing edge.
    private func resizeHandle(key: String, currentWidth: CGFloat) -> some View {
        Rectangle().fill(Color.clear).frame(width: 8)
            .overlay(Divider())
            .contentShape(Rectangle())
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    if resizeStart == nil { resizeStart = currentWidth }
                    setWidth(key, to: (resizeStart ?? currentWidth) + v.translation.width)
                }
                .onEnded { _ in resizeStart = nil })
            .accessibilityHidden(true)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            // Fixed-width columns inside a horizontal scroll so a wide
            // table scrolls instead of forcing the whole window layout to
            // shift; the column header stays put while rows scroll down.
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    tableHeader
                    Divider()
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(rows, id: \.id) { d in
                                tableRow(d)
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(title).font(.title3.bold())
            Text("\(rows.count)").font(.callout).foregroundStyle(.secondary)
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
                TextField("Search — e.g. “Sonoma FileVault off”", text: $tableSearch).textFieldStyle(.plain).frame(width: 230)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
    }

    // MARK: - Columns

    /// Every toggleable device column (Device is always shown).
    private var allDeviceColumns: [DeviceColumn] {
        [DeviceColumn(key: "serial", title: "Serial", width: 116, sort: nil),
         DeviceColumn(key: "model", title: "Model", width: 138, sort: .model),
         DeviceColumn(key: "os", title: "macOS", width: 66, sort: .os),
         DeviceColumn(key: "fv", title: "FileVault", width: 84, sort: .fileVault),
         DeviceColumn(key: "compliance", title: "Compliance", width: 104, sort: .compliance),
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

    private var tableHeader: some View {
        HStack(spacing: 12) {
            let deviceW = width(for: "device", default: 230)
            HStack(spacing: 0) {
                sortHeader("Device", .name).frame(width: max(40, deviceW) - 8, alignment: .leading)
                resizeHandle(key: "device", currentWidth: deviceW)
            }
            ForEach(visibleColumns) { col in
                let w = width(for: col.key, default: col.width)
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

    private func tableRow(_ d: MDMEnrollment) -> some View {
        let hovered = hoveredRow == d.id
        let selected = selection.contains(facts.hostID(for: d))
        return HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: facts.deviceIcon(d)).font(.caption).foregroundStyle(Color.accentColor).frame(width: 16)
                Text(facts.label(for: d)).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
            }
            .frame(width: width(for: "device", default: 230), alignment: .leading)
            ForEach(visibleColumns) { col in
                deviceCell(col, d).frame(width: width(for: col.key, default: col.width), alignment: .leading)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.18)
                    : (hovered ? Color.accentColor.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { selection = [facts.hostID(for: d)] }
        .onHover { hoveredRow = $0 ? d.id : (hoveredRow == d.id ? nil : hoveredRow) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(facts.label(for: d))
    }

    @ViewBuilder
    private func deviceCell(_ col: DeviceColumn, _ d: MDMEnrollment) -> some View {
        switch col.key {
        case "serial": Text(d.serialNumber ?? "—").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case "model": Text(facts.models[d.id] ?? "—").font(.callout).foregroundStyle(facts.models[d.id] == nil ? .secondary : .primary).lineLimit(1)
        case "os": Text(facts.osVersions[d.id] ?? "—").font(.callout).foregroundStyle(facts.osVersions[d.id] == nil ? .secondary : .primary)
        case "fv": fvCell(d)
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
        case .some(true): pill("Compliant", .green)
        case .some(false): pill("Out", .orange)
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
        rows.sort { a, b in
            let asc: Bool
            switch sortKey {
            case .name: asc = facts.label(for: a).localizedCaseInsensitiveCompare(facts.label(for: b)) == .orderedAscending
            case .model: asc = (facts.models[a.id] ?? "~").localizedCaseInsensitiveCompare(facts.models[b.id] ?? "~") == .orderedAscending
            case .os: asc = facts.osRank(facts.osVersions[a.id]) < facts.osRank(facts.osVersions[b.id])
            case .fileVault: asc = fvRank(a) < fvRank(b)
            case .compliance: asc = rank(a) < rank(b)
            case .lastSeen: asc = (a.lastSeenDate ?? .distantPast) < (b.lastSeenDate ?? .distantPast)
            }
            return sortAsc ? asc : !asc
        }
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
        TableCSVExport.save(filename: "\(title).csv", columns: cols, rows: outRows)
    }
}
