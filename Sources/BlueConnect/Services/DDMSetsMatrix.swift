import Foundation

/// A declarations × sets membership matrix for the library's Sets grid —
/// the "blast radius" view. Pure + testable: which declaration belongs to
/// which KMFDDM set, the per-set declaration count, and which declarations
/// belong to no set (so Sync uploads them but no device ever receives them).
struct DDMSetsMatrix {
    struct Row: Identifiable, Hashable {
        /// The library item's id — used to toggle its membership.
        let id: UUID
        /// Plain-English summary title (falls back to the kind).
        let title: String
        let identifier: String
        let kind: String
        let sets: Set<String>
        func isMember(of set: String) -> Bool { sets.contains(set) }
    }

    /// Column order — every set name referenced by the library plus any
    /// caller-supplied extras (a set being created in the grid), de-duped
    /// and sorted.
    let sets: [String]
    /// One row per declaration, sorted by title then identifier.
    let rows: [Row]

    /// How many declarations are in a given set.
    func count(for set: String) -> Int {
        rows.reduce(0) { $0 + ($1.sets.contains(set) ? 1 : 0) }
    }

    /// Declarations in no set at all — dead weight until assigned: Sync
    /// pushes them to KMFDDM but no enrolled device receives them.
    var orphans: [Row] { rows.filter { $0.sets.isEmpty } }

    static func make(from items: [DDMLibraryItem], extraSets: [String] = []) -> DDMSetsMatrix {
        let cols = Set(items.flatMap(\.sets)).union(extraSets)
        let rows = items.map { item in
            Row(id: item.id,
                title: item.summary.title,
                identifier: item.identifier,
                kind: item.kind,
                sets: Set(item.sets))
        }
        .sorted { ($0.title, $0.identifier) < ($1.title, $1.identifier) }
        return DDMSetsMatrix(sets: cols.sorted(), rows: rows)
    }
}
