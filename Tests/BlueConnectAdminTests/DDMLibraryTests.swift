import Testing
import Foundation
@testable import BlueConnectAdmin

/// The DDM library's pure pieces: how a declaration's type maps to a kind /
/// ddm_examples subfolder, declaration validation, and the folder export
/// format (declarations under type subfolders + `sets/set.<name>.txt`).
/// Uses the static folder writer + a temp dir so it never touches the
/// persisted user library.
@Suite("DDM library")
struct DDMLibraryTests {

    private func decl(type: String, id: String) -> Data {
        Data(#"{"Type":"\#(type)","Identifier":"\#(id)","Payload":{}}"#.utf8)
    }

    @Test func typeMappingAndValidation() {
        #expect(DDMLibraryItem.kind(forType: "com.apple.configuration.softwareupdate.enforcement.specific") == "configuration")
        #expect(DDMLibraryItem.subfolder(forType: "com.apple.configuration.foo") == "configurations")
        #expect(DDMLibraryItem.subfolder(forType: "com.apple.activation.simple") == "activations")
        #expect(DDMLibraryItem.subfolder(forType: "com.apple.asset.data") == "assets")
        #expect(DDMLibraryItem.subfolder(forType: "com.apple.management.foo") == "management")
        #expect(DDMLibraryItem.subfolder(forType: "weird") == "declarations")
        #expect(DDMLibraryItem.safeFilename("com.x/y") == "com.x_y.json")
        #expect(DDMLibraryItem.isValidDeclaration(decl(type: "com.apple.activation.simple", id: "a")))
        #expect(DDMLibraryItem.isValidDeclaration(Data(#"{"foo":1}"#.utf8)) == false)
    }

    @Test func itemParsesTypeAndIdentifier() {
        let item = DDMLibraryItem(json: decl(type: "com.apple.activation.simple", id: "com.x.act"))
        #expect(item.type == "com.apple.activation.simple")
        #expect(item.identifier == "com.x.act")
        #expect(item.kind == "activation")
    }

    @Test func exportWritesTypeFoldersAndSetFiles() throws {
        let items = [
            DDMLibraryItem(json: decl(type: "com.apple.configuration.foo", id: "com.x.config"), sets: ["default"]),
            DDMLibraryItem(json: decl(type: "com.apple.activation.simple", id: "com.x.config.activation"), sets: ["default"]),
        ]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ddmtest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try DDMLibraryStore.write(items, to: dir)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("configurations/com.x.config.json").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("activations/com.x.config.activation.json").path))
        let setBody = try String(contentsOf: dir.appendingPathComponent("sets/set.default.txt"), encoding: .utf8)
        #expect(setBody.contains("com.x.config"))
        #expect(setBody.contains("com.x.config.activation"))
    }
}
