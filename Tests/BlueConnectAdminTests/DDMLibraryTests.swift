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

    @Test func summaryStatusSubscriptionsReadsItemNames() {
        let payload: [String: Any] = ["StatusItems": [
            ["Name": "device.operating-system.version"],
            ["Name": "diskmanagement.filevault.enabled"],
        ]]
        let s = DDMDeclarationSummary.make(type: "com.apple.configuration.management.status-subscriptions", payload: payload)
        #expect(s.title == "Status reporting")
        #expect(s.rows.count == 1)
        #expect(s.rows.first?.label == "Reports")
        #expect(s.rows.first?.value == "macOS version, FileVault enabled")
    }

    @Test func summaryEnforcementAndActivation() {
        let enforce = DDMDeclarationSummary.make(
            type: "com.apple.configuration.softwareupdate.enforcement.specific",
            payload: ["TargetOSVersion": "15.5", "TargetLocalDateTime": "2026-07-01T12:00:00"])
        #expect(enforce.title == "Enforce macOS update")
        #expect(enforce.rows.contains { $0.label == "Target version" && $0.value == "15.5" })
        #expect(enforce.rows.contains { $0.label == "Install by" && $0.value == "2026-07-01T12:00:00" })

        let act = DDMDeclarationSummary.make(
            type: "com.apple.activation.simple",
            payload: ["StandardConfigurations": ["com.x.config"]])
        #expect(act.title == "Activation")
        #expect(act.rows.first?.value == "com.x.config")
    }

    @Test func summaryUnknownTypeFallsBackAndLabelsPrettify() {
        let unknown = DDMDeclarationSummary.make(type: "com.apple.configuration.exotic.thing", payload: [:])
        #expect(unknown.title == "Configuration")
        #expect(unknown.rows.isEmpty)
        #expect(DDMDeclarationSummary.statusItemLabel("foo.bar-baz") == "Foo bar baz")
        #expect(DDMDeclarationSummary.statusItemLabel("device.operating-system.version") == "macOS version")
    }

    @Test func setsMatrixCountsAndOrphans() throws {
        let items = [
            DDMLibraryItem(json: decl(type: "com.apple.activation.simple", id: "com.x.act"), sets: ["default", "security"]),
            DDMLibraryItem(json: decl(type: "com.apple.configuration.management.status-subscriptions", id: "com.x.status"), sets: ["default"]),
            DDMLibraryItem(json: decl(type: "com.apple.configuration.foo", id: "com.x.orphan"), sets: []),
        ]
        let m = DDMSetsMatrix.make(from: items, extraSets: ["staging"])
        #expect(m.sets == ["default", "security", "staging"])   // sorted, includes empty extra column
        #expect(m.count(for: "default") == 2)
        #expect(m.count(for: "security") == 1)
        #expect(m.count(for: "staging") == 0)
        #expect(m.orphans.map(\.identifier) == ["com.x.orphan"])
        let act = try #require(m.rows.first { $0.identifier == "com.x.act" })
        #expect(act.isMember(of: "security"))
        #expect(!act.isMember(of: "staging"))
    }

    @Test func statusSubscriptionsHonorsChosenFacts() throws {
        let chosen = ["device.operating-system.version", "diskmanagement.filevault.enabled"]
        let data = DDMDeclarations.statusSubscriptions(identifier: "com.x.status", itemNames: chosen)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["Type"] as? String == "com.apple.configuration.management.status-subscriptions")
        let items = try #require((obj["Payload"] as? [String: Any])?["StatusItems"] as? [[String: Any]])
        #expect(items.compactMap { $0["Name"] as? String } == chosen)
        // The summary reads it back into the plain-English labels the form shows.
        let summary = DDMDeclarationSummary.make(
            type: "com.apple.configuration.management.status-subscriptions",
            payload: (obj["Payload"] as? [String: Any]) ?? [:])
        #expect(summary.rows.first?.value == "macOS version, FileVault enabled")
    }

    @Test func setsMatrixRowsSortedByTitle() {
        let items = [
            DDMLibraryItem(json: decl(type: "com.apple.activation.simple", id: "z"), sets: []),                              // "Activation"
            DDMLibraryItem(json: decl(type: "com.apple.configuration.management.status-subscriptions", id: "a"), sets: []),  // "Status reporting"
        ]
        let m = DDMSetsMatrix.make(from: items)
        #expect(m.rows.map(\.title) == ["Activation", "Status reporting"])
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
