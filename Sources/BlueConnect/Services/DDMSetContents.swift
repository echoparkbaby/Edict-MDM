import Foundation

/// What an enrolled Mac associated with a KMFDDM set actually receives —
/// the plain-English rollup behind the Sets grid's per-set preview. Pure +
/// testable. It also doubles as a correctness check: a configuration whose
/// activation isn't in the same set is flagged, because a configuration only
/// takes effect once an activation references it.
struct DDMSetContents {
    struct ConfigEntry: Identifiable {
        var id: String { identifier }
        let identifier: String
        let summary: DDMDeclarationSummary
        /// True when an activation in this set lists this configuration in
        /// its StandardConfigurations.
        let isActivated: Bool
    }

    let set: String
    /// The configurations a device receives, sorted by plain-English title.
    let configs: [ConfigEntry]
    /// Activation declarations in the set (plumbing — not shown as items).
    let activationCount: Int
    /// Anything else in the set (assets, management, …).
    let otherCount: Int

    /// Configurations with no activation in the set — they won't take effect.
    var unactivated: [ConfigEntry] { configs.filter { !$0.isActivated } }

    static func make(set: String, items: [DDMLibraryItem]) -> DDMSetContents {
        let inSet = items.filter { $0.sets.contains(set) }

        // Every configuration id referenced by an activation in this set.
        var activatedIDs = Set<String>()
        var activationCount = 0
        for item in inSet where item.kind == "activation" {
            activationCount += 1
            if let refs = item.payload["StandardConfigurations"] as? [String] {
                activatedIDs.formUnion(refs)
            }
        }

        let configs = inSet
            .filter { $0.kind == "configuration" }
            .map { item in
                ConfigEntry(identifier: item.identifier,
                            summary: item.summary,
                            isActivated: activatedIDs.contains(item.identifier))
            }
            .sorted { ($0.summary.title, $0.identifier) < ($1.summary.title, $1.identifier) }

        let other = inSet.filter { $0.kind != "configuration" && $0.kind != "activation" }.count

        return DDMSetContents(set: set, configs: configs,
                              activationCount: activationCount, otherCount: other)
    }
}
