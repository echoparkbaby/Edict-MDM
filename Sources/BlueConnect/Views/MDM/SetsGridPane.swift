import SwiftUI

/// The library's "Sets" grid — a declarations × sets membership matrix so an
/// operator can see (and edit) blast radius at a glance: which declarations
/// land in which KMFDDM set, how many are in each set, and which are in no
/// set (so they'd never reach a device). Local-only — it edits the library's
/// set membership; Sync (on the Library tab) pushes the result to KMFDDM.
struct SetsGridPane: View {
    @Environment(DDMLibraryStore.self) private var library

    /// Sets typed into the grid that don't exist in the library yet — shown
    /// as empty columns so you can start checking declarations into them.
    @State private var extraSets: [String] = []
    @State private var newSet = ""
    /// The set whose "what a Mac receives" preview is open (set name).
    @State private var previewTarget: PreviewTarget?

    private struct PreviewTarget: Identifiable { let id: String }

    private var matrix: DDMSetsMatrix {
        DDMSetsMatrix.make(from: library.items, extraSets: extraSets)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if library.items.isEmpty {
                empty
            } else if matrix.sets.isEmpty {
                noSets
            } else {
                grid
            }
        }
        .sheet(item: $previewTarget) { target in
            SetContentsPreview(set: target.id)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Sets").font(.headline)
            Text("\(matrix.sets.count) set\(matrix.sets.count == 1 ? "" : "s") · \(library.items.count) declaration\(library.items.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            if !matrix.orphans.isEmpty {
                Label("\(matrix.orphans.count) in no set", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .help("These declarations belong to no set, so Sync uploads them but no device receives them. Check them into a set.")
            }
            Spacer()
            TextField("new set name", text: $newSet)
                .textFieldStyle(.roundedBorder).frame(width: 140)
                .onSubmit(addSet)
            Button("Add Set", systemImage: "plus") { addSet() }
                .disabled(trimmedNewSet.isEmpty || matrix.sets.contains(trimmedNewSet))
                .help("Add an empty set column, then check declarations into it")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var trimmedNewSet: String { newSet.trimmingCharacters(in: .whitespaces) }

    private func addSet() {
        let s = trimmedNewSet
        guard !s.isEmpty, !matrix.sets.contains(s) else { return }
        extraSets.append(s)
        newSet = ""
    }

    // MARK: - Empty states

    private var empty: some View {
        ContentUnavailableHint(
            icon: "square.grid.3x3",
            title: "No declarations yet",
            message: "Add declarations on the Library tab. They'll show here so you can assign them to sets.")
    }

    private var noSets: some View {
        ContentUnavailableHint(
            icon: "square.grid.3x3",
            title: "No sets yet",
            message: "Type a set name above and click Add Set, then check declarations into it. A set is the group of declarations an enrolled device receives.")
    }

    // MARK: - Grid

    private var grid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "hand.tap").font(.caption2)
                Text("Click a set name to preview what a Mac in it receives.").font(.caption2)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            ScrollView([.vertical, .horizontal]) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("Declaration")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    ForEach(matrix.sets, id: \.self) { set in
                        Button {
                            previewTarget = PreviewTarget(id: set)
                        } label: {
                            VStack(spacing: 1) {
                                Text(set).font(.caption.weight(.semibold)).foregroundStyle(.tint).lineLimit(1)
                                Text("\(matrix.count(for: set))").font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(minWidth: 70).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help("See what a Mac in “\(set)” receives")
                    }
                }
                Divider().gridCellColumns(matrix.sets.count + 1)
                ForEach(matrix.rows) { row in
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title).font(.callout)
                            Text(row.identifier).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .frame(minWidth: 240, alignment: .leading)
                        ForEach(matrix.sets, id: \.self) { set in
                            cell(row: row, set: set)
                        }
                    }
                }
            }
            .padding(12)
            }
        }
    }

    private func cell(row: DDMSetsMatrix.Row, set: String) -> some View {
        let on = row.isMember(of: set)
        return Button {
            library.setMembership(row.id, set: set, isMember: !on)
        } label: {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.35))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 70)
        .help(on ? "In “\(set)” — click to remove" : "Not in “\(set)” — click to add")
        .accessibilityLabel("\(row.title), set \(set)")
        .accessibilityValue(on ? "in set" : "not in set")
        .accessibilityAddTraits(on ? .isSelected : [])
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
