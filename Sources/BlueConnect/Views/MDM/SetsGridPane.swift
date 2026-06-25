import SwiftUI

/// The library's "Sets" view — a master/detail editor for KMFDDM sets. The
/// left list is every set (plus an "unassigned" bucket for orphan
/// declarations); the right pane is the selected set's actual contents: the
/// declarations in it, inline fixes for ones that won't take effect, add /
/// remove, and a preview of what a Mac assigned the set receives. Local-only —
/// it edits the library's set membership; Sync (Library tab) pushes to KMFDDM.
struct SetsGridPane: View {
    @Environment(DDMLibraryStore.self) private var library

    /// Sets typed here that don't exist in the library yet — empty columns to
    /// start checking declarations into.
    @State private var extraSets: [String] = []
    @State private var newSet = ""
    @State private var selection: Selection?
    @State private var addSearch = ""
    @State private var previewTarget: PreviewTarget?

    private enum Selection: Hashable { case set(String); case orphans }
    private struct PreviewTarget: Identifiable { let id: String }

    private var matrix: DDMSetsMatrix {
        DDMSetsMatrix.make(from: library.items, extraSets: extraSets)
    }

    var body: some View {
        Group {
            if library.items.isEmpty {
                empty
            } else {
                HSplitView {
                    setList.frame(minWidth: 210, idealWidth: 240, maxWidth: 320)
                    detail.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .sheet(item: $previewTarget) { SetContentsPreview(set: $0.id) }
        .onAppear(perform: ensureSelection)
        .onChange(of: matrix.sets) { _, _ in ensureSelection() }
    }

    /// Land on a sensible default selection (first set, else orphans).
    private func ensureSelection() {
        let valid: Bool
        switch selection {
        case .set(let s): valid = matrix.sets.contains(s)
        case .orphans:    valid = !matrix.orphans.isEmpty
        case nil:         valid = false
        }
        if !valid {
            selection = matrix.sets.first.map(Selection.set)
                ?? (matrix.orphans.isEmpty ? nil : .orphans)
        }
    }

    // MARK: - Left: set list

    private var setList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sets").font(.headline)
                Spacer()
                Text("\(matrix.sets.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            List(selection: $selection) {
                if !matrix.orphans.isEmpty {
                    orphanRow.tag(Selection.orphans)
                }
                ForEach(matrix.sets, id: \.self) { set in
                    setRow(set).tag(Selection.set(set))
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 6) {
                TextField("New set name", text: $newSet)
                    .textFieldStyle(.roundedBorder).onSubmit(addSet)
                Button { addSet() } label: { Image(systemName: "plus") }
                    .disabled(trimmedNewSet.isEmpty || matrix.sets.contains(trimmedNewSet))
                    .help("Add an empty set, then check declarations into it")
            }
            .padding(8)
        }
    }

    private func setRow(_ set: String) -> some View {
        let count = matrix.count(for: set)
        let warn = matrix.rows.contains { $0.unactivatedSets.contains(set) }
        return HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(set).lineLimit(1)
                Text("\(count) declaration\(count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if warn {
                Image(systemName: "bolt.slash.fill").font(.caption2).foregroundStyle(.orange)
                    .help("Has configurations that won't take effect")
            }
        }
        .padding(.vertical, 2)
    }

    private var orphanRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Not in any set")
                Text("\(matrix.orphans.count) declaration\(matrix.orphans.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Right: detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .set(let name): setDetail(name)
        case .orphans:       orphansDetail
        case nil:            placeholder
        }
    }

    private var placeholder: some View {
        ContentUnavailableHint(icon: "square.stack.3d.up",
                               title: "Pick a set",
                               message: "Select a set on the left to see and edit what a Mac assigned it receives.")
    }

    private func setDetail(_ set: String) -> some View {
        let members = matrix.rows.filter { $0.isMember(of: set) }
        let unactivated = members.filter { $0.isUnactivated(in: set) }
        let nonMembers = matrix.rows.filter { !$0.isMember(of: set) }.filter {
            addSearch.isEmpty
                || $0.title.localizedCaseInsensitiveContains(addSearch)
                || $0.identifier.localizedCaseInsensitiveContains(addSearch)
        }
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(set).font(.title3.bold())
                    Text("\(members.count) declaration\(members.count == 1 ? "" : "s") — a Mac assigned this set receives them")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { previewTarget = PreviewTarget(id: set) } label: {
                    Label("Preview", systemImage: "eye")
                }
                .help("See exactly what a Mac in “\(set)” receives")
            }
            .padding(12)

            if !unactivated.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.slash.fill").foregroundStyle(.orange)
                    Text("\(unactivated.count) configuration\(unactivated.count == 1 ? "" : "s") won't take effect — nothing activates them in this set.")
                        .font(.caption)
                    Spacer()
                    Button("Activate all") { for r in unactivated { library.activate(configID: r.identifier, in: set) } }
                        .help("Add the missing activation so these configurations apply")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
            }
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeader("In this set")
                    if members.isEmpty {
                        hint("Empty — add declarations from below.")
                    } else {
                        ForEach(members) { row in
                            memberRow(row, set: set)
                            Divider().opacity(0.35)
                        }
                    }
                    sectionHeader("Add declarations")
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                        TextField("Filter", text: $addSearch).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 12).padding(.bottom, 4)
                    if nonMembers.isEmpty {
                        hint(addSearch.isEmpty ? "Every declaration is already in this set." : "No match.")
                    } else {
                        ForEach(nonMembers) { row in
                            addRow(row, set: set)
                            Divider().opacity(0.35)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private func memberRow(_ row: DDMSetsMatrix.Row, set: String) -> some View {
        let broken = row.isUnactivated(in: set)
        return HStack(spacing: 10) {
            declIcon(row)
            declText(row)
            Spacer(minLength: 8)
            if broken {
                Button { library.activate(configID: row.identifier, in: set) } label: {
                    Label("Activate", systemImage: "bolt").font(.caption)
                }
                .buttonStyle(.borderless).foregroundStyle(.orange)
                .help("Won't take effect here — add an activation that references it")
            }
            Button { library.setMembership(row.id, set: set, isMember: false) } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("Remove from “\(set)”")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(broken ? Color.orange.opacity(0.06) : .clear)
    }

    private func addRow(_ row: DDMSetsMatrix.Row, set: String) -> some View {
        HStack(spacing: 10) {
            declIcon(row, dim: true)
            declText(row)
            Spacer(minLength: 8)
            Button { library.setMembership(row.id, set: set, isMember: true) } label: {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain).help("Add to “\(set)”")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: - Orphans detail

    private var orphansDetail: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Not in any set", systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.bold()).foregroundStyle(.orange)
                Text("These sync to KMFDDM but no device receives them until they're in a set.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matrix.orphans) { row in
                        HStack(spacing: 10) {
                            declIcon(row, dim: true)
                            declText(row)
                            Spacer(minLength: 8)
                            Menu("Add to set") {
                                if matrix.sets.isEmpty {
                                    Text("No sets yet — create one on the left")
                                } else {
                                    ForEach(matrix.sets, id: \.self) { set in
                                        Button(set) { library.setMembership(row.id, set: set, isMember: true) }
                                    }
                                }
                            }
                            .fixedSize()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        Divider().opacity(0.35)
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Shared row bits

    private func declIcon(_ row: DDMSetsMatrix.Row, dim: Bool = false) -> some View {
        Image(systemName: kindIcon(row.kind))
            .foregroundStyle(dim ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            .frame(width: 20)
            .help(row.kind.capitalized)
    }

    private func declText(_ row: DDMSetsMatrix.Row) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.title).font(.callout).lineLimit(1).truncationMode(.tail)
            Text(row.identifier).font(.caption2.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func kindIcon(_ kind: String) -> String {
        switch kind {
        case "configuration": return "gearshape.fill"
        case "activation":    return "bolt.fill"
        case "asset":         return "shippingbox.fill"
        case "management":    return "checkmark.shield.fill"
        default:              return "doc.fill"
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
    }
    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: - New set

    private var trimmedNewSet: String { newSet.trimmingCharacters(in: .whitespaces) }
    private func addSet() {
        let s = trimmedNewSet
        guard !s.isEmpty, !matrix.sets.contains(s) else { return }
        extraSets.append(s)
        newSet = ""
        selection = .set(s)
    }

    private var empty: some View {
        ContentUnavailableHint(
            icon: "square.stack.3d.up",
            title: "No declarations yet",
            message: "Add declarations on the Library tab. They'll show here so you can group them into sets.")
    }
}

/// Small reusable centered empty-state hint (macOS-14 friendly, since
/// ContentUnavailableView's full API is macOS 15+).
private struct ContentUnavailableHint: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 36)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
