import Testing
import Foundation
@testable import BlueConnectAdmin

/// The `DDMLibraryStore` orchestration — add/replace/merge, membership,
/// the Activate fixes, and persistence round-trip — exercised against a
/// temp file so it never touches the real user library. `@MainActor`
/// because the store is main-actor isolated.
@MainActor
@Suite("DDM library store")
struct DDMLibraryStoreTests {

    private func decl(_ type: String, _ id: String) -> Data {
        Data(#"{"Type":"\#(type)","Identifier":"\#(id)","Payload":{}}"#.utf8)
    }
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ddmstore-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("lib.json")
    }

    @Test func addReplacesByIdentifierAndMergesSets() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DDMLibraryStore(fileURL: url)
        #expect(store.add(decl("com.apple.configuration.foo", "com.x.a"), sets: ["default"]))
        #expect(store.items.count == 1)
        // Same identifier → replaced in place, sets merged (no duplicate row).
        #expect(store.add(decl("com.apple.configuration.foo", "com.x.a"), sets: ["security"]))
        #expect(store.items.count == 1)
        #expect(store.items[0].sets == ["default", "security"])
    }

    @Test func addRejectsInvalid() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DDMLibraryStore(fileURL: url)
        #expect(store.add(Data(#"{"foo":1}"#.utf8)) == false)
        #expect(store.items.isEmpty)
    }

    @Test func removeAndSetNames() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DDMLibraryStore(fileURL: url)
        store.add(decl("com.apple.configuration.foo", "com.x.a"), sets: ["b"])
        store.add(decl("com.apple.configuration.bar", "com.x.b"), sets: ["a"])
        #expect(store.setNames == ["a", "b"])
        let id = try #require(store.items.first?.id)
        store.remove(id)
        #expect(store.items.count == 1)
    }

    @Test func membershipReplaceAndToggle() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DDMLibraryStore(fileURL: url)
        store.add(decl("com.apple.configuration.foo", "com.x.a"))
        let id = try #require(store.items.first?.id)
        store.setMembership(id, sets: ["a", "b"])
        #expect(store.items[0].sets == ["a", "b"])
        store.setMembership(id, set: "b", isMember: false)
        #expect(store.items[0].sets == ["a"])
        store.setMembership(id, set: "c", isMember: true)
        #expect(store.items[0].sets == ["a", "c"])
    }

    @Test func activateThroughStoreClearsFlag() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DDMLibraryStore(fileURL: url)
        store.add(decl("com.apple.configuration.foo", "com.x.cfg"), sets: ["staging"])
        #expect(DDMSetsMatrix.make(from: store.items).unactivatedCount == 1)
        store.activate(configID: "com.x.cfg", in: "staging")
        #expect(DDMSetsMatrix.make(from: store.items).unactivatedCount == 0)
        #expect(store.items.contains { $0.identifier == "com.x.cfg.activation" })
    }

    @Test func activateAllThroughStore() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DDMLibraryStore(fileURL: url)
        store.add(decl("com.apple.configuration.foo", "com.x.a"), sets: ["s1"])
        store.add(decl("com.apple.configuration.bar", "com.x.b"), sets: ["s1", "s2"])
        let fixed = store.activateAllUnactivated()
        #expect(fixed == 3)   // a→s1, b→s1, b→s2
        #expect(DDMSetsMatrix.make(from: store.items).unactivatedCount == 0)
    }

    /// A set named with a path separator must not create nested folders on
    /// export — the "/" is neutralized so the membership file stays inside
    /// the chosen sets/ directory (path-traversal guard).
    @Test func exportSanitizesSetNamesWithSlashes() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DDMLibraryStore(fileURL: url)
        store.add(decl("com.apple.configuration.foo", "com.x.a"), sets: ["a/b"])

        let exportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ddmexport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: exportDir) }
        try store.export(to: exportDir)

        let setsDir = exportDir.appendingPathComponent("sets", isDirectory: true)
        // The sanitized flat file exists…
        #expect(FileManager.default.fileExists(atPath: setsDir.appendingPathComponent("set.a_b.txt").path))
        // …and no "set.a" subdirectory was carved out by an unescaped slash.
        var isDir: ObjCBool = false
        let carved = FileManager.default.fileExists(atPath: setsDir.appendingPathComponent("set.a").path, isDirectory: &isDir)
        #expect(!(carved && isDir.boolValue))
    }

    @Test func persistenceRoundTrips() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        DDMLibraryStore(fileURL: url).add(decl("com.apple.configuration.foo", "com.x.a"), sets: ["default"])
        // A fresh store on the same file rehydrates what the first one wrote.
        let reopened = DDMLibraryStore(fileURL: url)
        #expect(reopened.items.count == 1)
        #expect(reopened.items.first?.identifier == "com.x.a")
        #expect(reopened.items.first?.sets == ["default"])
    }
}
