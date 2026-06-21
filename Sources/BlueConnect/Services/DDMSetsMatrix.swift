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
        /// Member-sets in which this configuration has no activation, so it
        /// won't take effect there. Always empty for activations/assets/etc.
        let unactivatedSets: Set<String>
        func isMember(of set: String) -> Bool { sets.contains(set) }
        /// True when this row is in `set` but won't take effect there.
        func isUnactivated(in set: String) -> Bool { unactivatedSets.contains(set) }
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

    /// Total (configuration, set) memberships that won't take effect — a
    /// configuration checked into a set with no activation referencing it
    /// there. Drives the grid's warning count.
    var unactivatedCount: Int { rows.reduce(0) { $0 + $1.unactivatedSets.count } }

    static func make(from items: [DDMLibraryItem], extraSets: [String] = []) -> DDMSetsMatrix {
        let cols = Set(items.flatMap(\.sets)).union(extraSets)

        // set name → configuration ids activated there (an activation in the
        // set lists them in its StandardConfigurations).
        var activatedBySet: [String: Set<String>] = [:]
        for item in items where item.kind == "activation" {
            guard let refs = item.payload["StandardConfigurations"] as? [String] else { continue }
            for set in item.sets { activatedBySet[set, default: []].formUnion(refs) }
        }

        let rows = items.map { item -> Row in
            let memberSets = Set(item.sets)
            var unactivated = Set<String>()
            if item.kind == "configuration" {
                for set in memberSets where !(activatedBySet[set]?.contains(item.identifier) ?? false) {
                    unactivated.insert(set)
                }
            }
            return Row(id: item.id,
                       title: item.summary.title,
                       identifier: item.identifier,
                       kind: item.kind,
                       sets: memberSets,
                       unactivatedSets: unactivated)
        }
        .sorted { ($0.title, $0.identifier) < ($1.title, $1.identifier) }
        return DDMSetsMatrix(sets: cols.sorted(), rows: rows)
    }
}
