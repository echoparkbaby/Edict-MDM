import Foundation
import Observation

/// The local DDM declaration library — declarations you author/import in
/// Edict before pushing them to KMFDDM. Persisted to JSON under Application
/// Support and rehydrated at launch (same pattern as the saved profiles).
///
/// `sync` reconciles the whole library to KMFDDM (the native equivalent of
/// kmfddm's `syncdir.py`); `export` writes it to a ddm_examples / syncdir
/// folder layout for git versioning and round-tripping.
@Observable
@MainActor
final class DDMLibraryStore {
    private(set) var items: [DDMLibraryItem] = []

    /// Where the library persists. Defaults to Application Support; tests pass
    /// a temp file so they never touch the real user library.
    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        items = Self.load(from: self.fileURL)
    }

    /// Add (or replace by Identifier) a declaration. Returns false if the
    /// bytes aren't a valid declaration.
    @discardableResult
    func add(_ json: Data, sets: [String] = []) -> Bool {
        guard DDMLibraryItem.isValidDeclaration(json),
              let id = (try? JSONSerialization.jsonObject(with: json) as? [String: Any])?["Identifier"] as? String
        else { return false }
        if let idx = items.firstIndex(where: { $0.identifier == id }) {
            items[idx].json = json
            if !sets.isEmpty { items[idx].sets = Array(Set(items[idx].sets + sets)).sorted() }
        } else {
            items.append(DDMLibraryItem(json: json, sets: sets.sorted()))
        }
        persist()
        return true
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id }; persist() }

    func setMembership(_ id: UUID, sets: [String]) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].sets = sets.sorted()
        persist()
    }

    /// Toggle one declaration's membership in a single set — the Sets grid's
    /// per-cell edit.
    func setMembership(_ id: UUID, set: String, isMember: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        var s = Set(items[idx].sets)
        if isMember { s.insert(set) } else { s.remove(set) }
        items[idx].sets = s.sorted()
        persist()
    }

    /// Every distinct set name referenced by the library.
    var setNames: [String] { Array(Set(items.flatMap(\.sets))).sorted() }

    /// Set (or clear, with nil/empty) the gating Predicate on an activation —
    /// the configuration it turns on then only activates where the predicate
    /// is true. No-op on non-activation items.
    func setActivationPredicate(_ id: UUID, predicate: String?) {
        guard let idx = items.firstIndex(where: { $0.id == id }), items[idx].kind == "activation" else { return }
        items[idx].json = DDMDeclarations.activation(identifier: items[idx].identifier,
                                                     configurationIDs: items[idx].standardConfigurations,
                                                     predicate: predicate)
        persist()
    }

    /// Make `configID` take effect in `set` by ensuring its activation is in
    /// the set (the grid's per-cell "Activate here" fix).
    func activate(configID: String, in set: String) {
        items = DDMLibraryItem.activating(configID: configID, in: set, within: items)
        persist()
    }

    /// Fix every configuration that's checked into a set with no activation
    /// there — the grid's "Activate all" button. Returns how many (config,
    /// set) pairs were activated.
    @discardableResult
    func activateAllUnactivated() -> Int {
        let pairs = DDMSetsMatrix.make(from: items).rows.flatMap { row in
            row.unactivatedSets.map { (row.identifier, $0) }
        }
        for (configID, set) in pairs {
            items = DDMLibraryItem.activating(configID: configID, in: set, within: items)
        }
        if !pairs.isEmpty { persist() }
        return pairs.count
    }

    // MARK: - Sync + export

    /// Push every declaration to KMFDDM, then reconcile set membership. PUT
    /// all first so a configuration exists before its activation / set add
    /// fires the device notifications. With `prune`, also delete server
    /// declarations that aren't in the library (true mirror) — destructive,
    /// so the UI confirms first. Returns counts.
    @discardableResult
    func sync(settings: SettingsStore, prune: Bool = false) async throws -> (declarations: Int, setAdds: Int, pruned: Int) {
        let kmf = KMFDDMService(settings: settings)
        for item in items { try await kmf.putDeclaration(item.json) }
        var adds = 0
        for item in items {
            for set in item.sets {
                try await kmf.addDeclaration(item.identifier, toSet: set)
                adds += 1
            }
        }
        var pruned = 0
        if prune {
            let extras = try await pruneCandidates(settings: settings)
            // Pull every extra out of its sets first (devices drop them, and
            // no activation outlives the config it referenced), then delete.
            for id in extras {
                for set in (try? await kmf.setsForDeclaration(id: id)) ?? [] {
                    try? await kmf.removeDeclaration(id, fromSet: set)
                }
            }
            for id in extras { try? await kmf.deleteDeclaration(id: id) }
            pruned = extras.count
        }
        return (items.count, adds, pruned)
    }

    /// Declarations on the KMFDDM server that aren't in the library — what a
    /// mirror sync would delete. Computed for the confirmation preview.
    func pruneCandidates(settings: SettingsStore) async throws -> [String] {
        let serverIDs = try await KMFDDMService(settings: settings).listDeclarations()
        let libraryIDs = Set(items.map(\.identifier))
        return serverIDs.filter { !libraryIDs.contains($0) }.sorted()
    }

    /// Pull every declaration currently on the KMFDDM server into the
    /// library, preserving its set membership — to adopt an existing setup
    /// or edit what's already deployed. Returns how many were imported.
    @discardableResult
    func importFromServer(settings: SettingsStore) async throws -> Int {
        let kmf = KMFDDMService(settings: settings)
        let ids = try await kmf.listDeclarations()
        var n = 0
        for id in ids {
            guard let data = try? await kmf.declaration(id: id) else { continue }
            let sets = (try? await kmf.setsForDeclaration(id: id)) ?? []
            if add(data, sets: sets) { n += 1 }
        }
        return n
    }

    /// Write the library as a ddm_examples / syncdir folder.
    func export(to dir: URL) throws { try Self.write(items, to: dir) }

    /// Pure folder writer (testable without touching the persisted library):
    /// declarations into type subfolders (configurations/, activations/, …)
    /// and set membership as `sets/set.<name>.txt` (one identifier per line).
    nonisolated static func write(_ items: [DDMLibraryItem], to dir: URL) throws {
        let fm = FileManager.default
        var setMembers: [String: [String]] = [:]
        for item in items {
            let sub = dir.appendingPathComponent(DDMLibraryItem.subfolder(forType: item.type), isDirectory: true)
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            try item.json.write(to: sub.appendingPathComponent(DDMLibraryItem.safeFilename(item.identifier)))
            for set in item.sets { setMembers[set, default: []].append(item.identifier) }
        }
        if !setMembers.isEmpty {
            let setsDir = dir.appendingPathComponent("sets", isDirectory: true)
            try fm.createDirectory(at: setsDir, withIntermediateDirectories: true)
            for (set, members) in setMembers {
                let body = members.sorted().joined(separator: "\n") + "\n"
                // Neutralize path separators in the (user-named) set — an
                // unsanitized "/" or "../" would let appendingPathComponent
                // write the membership file outside the chosen export folder.
                let safeSet = set.replacingOccurrences(of: "/", with: "_")
                try Data(body.utf8).write(to: setsDir.appendingPathComponent("set.\(safeSet).txt"))
            }
        }
    }

    // MARK: - Persistence

    private static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EdictMDM", isDirectory: true)
            .appendingPathComponent("ddm-library.json")
    }
    private static func load(from url: URL) -> [DDMLibraryItem] {
        guard let d = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([DDMLibraryItem].self, from: d) else { return [] }
        return arr
    }
    private func persist() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: fileURL, options: .atomic) }
    }
}
