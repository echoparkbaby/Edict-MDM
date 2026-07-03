import SwiftUI

// Inventory tables + the searchable device picker, split out of the large
// GroupDashboardView. This is a same-type extension: behavior is unchanged and
// all @State stays on the main struct — only the code location moved. The
// parent members these methods reach are internal (not private) for cross-file
// access within this single module.
extension GroupDashboardView {
    private var devicePickerPopover: some View {
        let q = devicePickerQuery.trimmingCharacters(in: .whitespaces)
        let matches = q.isEmpty ? scoped : scoped.filter {
            label(for: $0).localizedCaseInsensitiveContains(q)
                || ($0.serialNumber ?? "").localizedCaseInsensitiveContains(q)
        }
        return VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Search Macs", text: $devicePickerQuery).textFieldStyle(.plain)
            }
            .padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    devicePickerRow(label: "All Macs", sub: nil, selected: inventoryDeviceID == nil) {
                        inventoryDeviceID = nil; showDevicePicker = false
                    }
                    ForEach(matches, id: \.id) { d in
                        devicePickerRow(label: label(for: d), sub: d.serialNumber,
                                        selected: inventoryDeviceID == d.id) {
                            inventoryDeviceID = d.id; showDevicePicker = false
                        }
                    }
                    if matches.isEmpty {
                        Text("No match").font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 260)
    }

    @ViewBuilder
    private func devicePickerRow(label: String, sub: String?, selected: Bool,
                                 _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "laptopcomputer")
                    .foregroundStyle(selected ? Color.accentColor : .secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).lineLimit(1)
                    if let sub, !sub.isEmpty {
                        Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.1) : .clear)
    }

    /// When a per-device inventory row (Storage, Updates, Firewall, …) is
    /// tapped, select that Mac in the main window so the right-hand inspector
    /// shows it — same behavior the Devices/Security table gives.
    private func selectHost(forRowID rowID: String) {
        guard let dev = scoped.first(where: { $0.id == rowID }) else { return }
        selection = [df.hostID(for: dev)]
    }
    /// The main-window selection id for a per-device row, to highlight it.
    private func isRowSelected(_ rowID: String) -> Bool {
        guard let dev = scoped.first(where: { $0.id == rowID }) else { return false }
        return selection.contains(df.hostID(for: dev))
    }

    private func filteredRows(_ rows: [(id: String, cells: [String])]) -> [(id: String, cells: [String])] {
        let q = tableSearch.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return rows }
        return rows.filter { row in row.cells.contains { $0.localizedCaseInsensitiveContains(q) } }
    }

    // MARK: - Inventory-table sort + resizable columns

    /// Effective column widths for the current category: dragged overrides if
    /// present (and still matching the column count), else the natural widths.
    private func invWidths(_ columns: [(String, CGFloat)]) -> [CGFloat] {
        var widths = columns.map(\.1)
        if let data = invColWidthsRaw.data(using: .utf8),
           let map = try? JSONDecoder().decode([String: [Double]].self, from: data),
           let saved = map[category.rawValue], saved.count == columns.count {
            widths = saved.map { CGFloat($0) }
        }
        if let lr = invLiveResize, lr.index < widths.count { widths[lr.index] = lr.width }
        return widths
    }

    private func setInvWidth(_ columns: [(String, CGFloat)], index: Int, to newWidth: CGFloat) {
        var widths = invWidths(columns)
        guard index < widths.count else { return }
        widths[index] = max(48, newWidth)
        var map: [String: [Double]] = [:]
        if let data = invColWidthsRaw.data(using: .utf8),
           let m = try? JSONDecoder().decode([String: [Double]].self, from: data) { map = m }
        map[category.rawValue] = widths.map { Double($0) }
        if let data = try? JSONEncoder().encode(map), let s = String(data: data, encoding: .utf8) {
            invColWidthsRaw = s
        }
    }

    private func toggleInvSort(_ i: Int) {
        if invSortCol == i { invSortAsc.toggle() } else { invSortCol = i; invSortAsc = true }
    }

    /// Sort the (already filtered) rows by the active column. Numeric when the
    /// cell starts with a number ("12 of 30", "45.2 GB"), else case-insensitive
    /// text. nil sort column leaves the rows in their incoming order.
    private func sortedRows(_ rows: [(id: String, cells: [String])]) -> [(id: String, cells: [String])] {
        InventoryRowSort.sorted(rows, column: invSortCol, ascending: invSortAsc)
    }

    /// A sortable, drag-to-resize header cell for the inventory tables.
    @ViewBuilder
    private func invHeaderCell(_ title: String, width: CGFloat, index: Int,
                               columns: [(String, CGFloat)]) -> some View {
        HStack(spacing: 0) {
            Button { toggleInvSort(index) } label: {
                HStack(spacing: 3) {
                    Text(title)
                    if invSortCol == index {
                        Image(systemName: invSortAsc ? "chevron.up" : "chevron.down").font(.system(size: 8))
                    }
                }
                .frame(width: max(40, width) - 8, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Color.clear.frame(width: 8, height: 14)
                .overlay(Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1))
                .contentShape(Rectangle())
                .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if invResizeStart == nil { invResizeStart = width }
                        invLiveResize = (index, max(48, (invResizeStart ?? width) + v.translation.width))
                    }
                    .onEnded { _ in
                        if let lr = invLiveResize { setInvWidth(columns, index: lr.index, to: lr.width) }
                        invLiveResize = nil; invResizeStart = nil
                    })
                .accessibilityHidden(true)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    /// Generic Kandji-style category table: a toolbar with title + filter,
    /// then a horizontally-scrolling sortable-width table. Column width 0
    /// means "flexible".
    func inventoryTable(columns: [(String, CGFloat)], rows: [(id: String, cells: [String])],
                                source: InvSource? = nil,
                                deviceRows: Bool = false,
                                drillDevices: ((String) -> [String])? = nil,
                                onPullMDM: (() -> Void)? = nil) -> some View {
        let widths = invWidths(columns)
        let filtered = sortedRows(filteredRows(rows))
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(category.rawValue).font(.title3.bold())
                Text("\(filtered.count)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let onPullMDM {
                    Button { onPullMDM() } label: {
                        if pullingSecurity { ProgressView().controlSize(.small) }
                        else { Label("Pull via MDM", systemImage: "antenna.radiowaves.left.and.right") }
                    }
                    .controlSize(.small)
                    .disabled(pullingSecurity)
                    .help("Query firewall + SIP live from each Mac in scope via MDM, overriding MunkiReport for the ones that answer.")
                }
                Button {
                    devicePickerQuery = ""
                    showDevicePicker = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "laptopcomputer").font(.caption).foregroundStyle(.secondary)
                        Text(inventoryDeviceID.flatMap { id in scoped.first { $0.id == id }.map { label(for: $0) } } ?? "All Macs")
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(width: 190)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Roll up every Mac, or search to narrow to just one")
                .popover(isPresented: $showDevicePicker, arrowEdge: .bottom) { devicePickerPopover }
                Button {
                    TableCSVExport.save(filename: "\(category.rawValue).csv", columns: columns.map(\.0), rows: filtered.map(\.cells))
                } label: { Image(systemName: "square.and.arrow.up") }
                .help("Export this view as CSV").disabled(filtered.isEmpty)
                .accessibilityLabel("Export this view as CSV")
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                    TextField("Filter", text: $tableSearch).textFieldStyle(.plain).frame(width: 150)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
            if let source { sourceCaption(source) }
            if filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Nothing reported yet — MunkiReport fills this in as Macs check in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                // Wrap in a horizontal scroll so wide columns scroll *within*
                // the pane instead of overflowing and shoving the whole window
                // layout sideways. (No trailing Spacer: inside a horizontal
                // scroll it would expand to infinite width.)
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            // Keep header aligned with the rows' disclosure chevron.
                            if drillDevices != nil { Color.clear.frame(width: 12, height: 1) }
                            ForEach(columns.indices, id: \.self) { i in
                                invHeaderCell(columns[i].0, width: widths[i], index: i, columns: columns)
                            }
                        }
                        .padding(.horizontal, 18).padding(.vertical, 5)
                        Divider()
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(spacing: 0) {
                                ForEach(filtered, id: \.id) { row in
                                    inventoryRow(row, columns: columns, widths: widths,
                                                 deviceRows: deviceRows, drillDevices: drillDevices)
                                    Divider().opacity(0.4)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// One category-table row. When `drillDevices` is supplied (rolled-up
    /// Apps / Local Users), the row is tappable to reveal which Macs it's on.
    @ViewBuilder
    private func inventoryRow(_ row: (id: String, cells: [String]), columns: [(String, CGFloat)],
                             widths: [CGFloat],
                             deviceRows: Bool = false,
                             drillDevices: ((String) -> [String])?) -> some View {
        let expandable = drillDevices != nil
        let isOpen = expandedInventoryRow == row.id
        let selected = deviceRows && isRowSelected(row.id)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if expandable {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 12)
                }
                ForEach(columns.indices, id: \.self) { i in
                    invCell(i < row.cells.count ? row.cells[i] : "", widths[i], header: false, first: i == 0)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 5)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                if expandable { expandedInventoryRow = isOpen ? nil : row.id }
                else if deviceRows { selectHost(forRowID: row.id) }
            }
            .accessibilityAddTraits((expandable || deviceRows) ? .isButton : [])
            if isOpen, let drillDevices {
                let macs = drillDevices(row.id)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(macs, id: \.self) { m in
                        HStack(spacing: 6) {
                            Image(systemName: "laptopcomputer").font(.caption2).foregroundStyle(.secondary)
                            Text(m).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 48).padding(.trailing, 18).padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.05))
            }
        }
    }

    @ViewBuilder
    private func invCell(_ text: String, _ width: CGFloat, header: Bool, first: Bool = false) -> some View {
        let view = Text(text.isEmpty && !header ? "—" : text)
            .font(header ? .caption.weight(.semibold) : (first ? .callout.weight(.medium) : .callout))
            .foregroundStyle(header ? .secondary : (first ? .primary : .secondary))
            .lineLimit(1).truncationMode(.tail)
        if width == 0 { view.frame(maxWidth: .infinity, alignment: .leading) }
        else { view.frame(width: width, alignment: .leading) }
    }
}
