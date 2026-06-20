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

    init() { items = Self.load() }

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

    /// Every distinct set name referenced by the library.
    var setNames: [String] { Array(Set(items.flatMap(\.sets))).sorted() }

    // MARK: - Sync + export

    /// Push every declaration to KMFDDM, then reconcile set membership. PUT
    /// all first so a configuration exists before its activation / set add
    /// fires the device notifications. Returns (declarations, set additions).
    @discardableResult
    func sync(settings: SettingsStore) async throws -> (declarations: Int, setAdds: Int) {
        let kmf = KMFDDMService(settings: settings)
        for item in items { try await kmf.putDeclaration(item.json) }
        var adds = 0
        for item in items {
            for set in item.sets {
                try await kmf.addDeclaration(item.identifier, toSet: set)
                adds += 1
            }
        }
        return (items.count, adds)
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
                try Data(body.utf8).write(to: setsDir.appendingPathComponent("set.\(set).txt"))
            }
        }
    }

    // MARK: - Persistence

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EdictMDM", isDirectory: true)
            .appendingPathComponent("ddm-library.json")
    }
    private static func load() -> [DDMLibraryItem] {
        guard let d = try? Data(contentsOf: fileURL),
              let arr = try? JSONDecoder().decode([DDMLibraryItem].self, from: d) else { return [] }
        return arr
    }
    private func persist() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: url) }
    }
}
