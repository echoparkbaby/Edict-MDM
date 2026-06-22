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

    @Test func diskManagementBuilderAndSummary() throws {
        let data = DDMDeclarations.diskManagement(identifier: "com.x.disk",
                                                  externalStorage: "ReadOnly",
                                                  networkStorage: "Disallowed")
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["Type"] as? String == "com.apple.configuration.diskmanagement.settings")
        let payload = try #require(obj["Payload"] as? [String: Any])
        let rest = try #require(payload["Restrictions"] as? [String: Any])
        #expect(rest["ExternalStorage"] as? String == "ReadOnly")
        #expect(rest["NetworkStorage"] as? String == "Disallowed")
        let summary = DDMDeclarationSummary.make(type: obj["Type"] as! String, payload: payload)
        #expect(summary.title == "Drive restrictions")
        #expect(summary.rows.contains { $0.label == "External drives" && $0.value == "Read-only" })
        #expect(summary.rows.contains { $0.label == "Network shares" && $0.value == "Blocked" })
    }

    @Test func softwareUpdateSettingsOmitsZeroDeferrals() throws {
        let data = DDMDeclarations.softwareUpdateSettings(
            identifier: "com.x.suos",
            download: "AlwaysOn", installOS: "Allowed", installSecurity: "AlwaysOn",
            deferMajorDays: 14, deferMinorDays: 0, deferSystemDays: 0,
            notifications: true)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(obj["Payload"] as? [String: Any])
        let actions = try #require(payload["AutomaticActions"] as? [String: Any])
        #expect(actions["Download"] as? String == "AlwaysOn")
        #expect(actions["InstallSecurityUpdate"] as? String == "AlwaysOn")
        let deferrals = try #require(payload["Deferrals"] as? [String: Any])
        #expect(deferrals["MajorPeriodInDays"] as? Int == 14)
        #expect(deferrals["MinorPeriodInDays"] == nil)     // 0 → omitted
        #expect(deferrals["SystemPeriodInDays"] == nil)
        // Only macOS-available keys are emitted — none of the n/a ones leak in.
        #expect(payload["AllowStandardUserOSUpdates"] == nil)
        #expect(payload["RecommendedCadence"] == nil)
        #expect(payload["RapidSecurityResponse"] == nil)
        let summary = DDMDeclarationSummary.make(type: obj["Type"] as! String, payload: payload)
        #expect(summary.title == "Update settings")
        #expect(summary.rows.contains { $0.label == "Download updates" && $0.value == "Always on" })
        #expect(summary.rows.contains { $0.label == "Defer" && $0.value == "Major 14d" })
    }

    @Test func softwareUpdateSettingsNoDeferralsHasNoDeferralsKey() throws {
        let data = DDMDeclarations.softwareUpdateSettings(
            identifier: "com.x.suos",
            download: "Allowed", installOS: "Allowed", installSecurity: "Allowed",
            deferMajorDays: 0, deferMinorDays: 0, deferSystemDays: 0,
            notifications: false)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(obj["Payload"] as? [String: Any])
        #expect(payload["Deferrals"] == nil)
        #expect(payload["Notifications"] as? Bool == false)
    }

    @Test func setsMatrixFlagsUnactivatedConfigsPerSet() throws {
        let config = DDMLibraryItem(json: decl(type: "com.apple.configuration.foo", id: "com.x.cfg"), sets: ["default", "staging"])
        let activation = DDMLibraryItem(
            json: DDMDeclarations.activation(identifier: "com.x.cfg.activation", configurationIDs: ["com.x.cfg"]),
            sets: ["default"])     // activates the config only in "default"
        let m = DDMSetsMatrix.make(from: [config, activation])
        let cfgRow = try #require(m.rows.first { $0.identifier == "com.x.cfg" })
        #expect(cfgRow.isUnactivated(in: "staging"))    // no activation in staging
        #expect(!cfgRow.isUnactivated(in: "default"))   // activated in default
        #expect(m.unactivatedCount == 1)
        let actRow = try #require(m.rows.first { $0.identifier == "com.x.cfg.activation" })
        #expect(actRow.unactivatedSets.isEmpty)         // activations are never flagged
    }

    @Test func activatingCreatesActivationAndClearsFlag() throws {
        let config = DDMLibraryItem(json: decl(type: "com.apple.configuration.foo", id: "com.x.cfg"), sets: ["staging"])
        #expect(DDMSetsMatrix.make(from: [config]).unactivatedCount == 1)

        let fixed = DDMLibraryItem.activating(configID: "com.x.cfg", in: "staging", within: [config])
        // A new activation exists, referencing the config, in the set.
        let act = try #require(fixed.first { $0.identifier == "com.x.cfg.activation" })
        #expect(act.sets == ["staging"])
        #expect((act.payload["StandardConfigurations"] as? [String]) == ["com.x.cfg"])
        #expect(DDMSetsMatrix.make(from: fixed).unactivatedCount == 0)
    }

    @Test func activatingReusesExistingActivationAddsSet() throws {
        let config = DDMLibraryItem(json: decl(type: "com.apple.configuration.foo", id: "com.x.cfg"), sets: ["default", "staging"])
        let activation = DDMLibraryItem(
            json: DDMDeclarations.activation(identifier: "com.x.cfg.activation", configurationIDs: ["com.x.cfg"]),
            sets: ["default"])
        let fixed = DDMLibraryItem.activating(configID: "com.x.cfg", in: "staging", within: [config, activation])
        // Same activation, no duplicate — just gained the new set.
        let acts = fixed.filter { $0.identifier == "com.x.cfg.activation" }
        #expect(acts.count == 1)
        #expect(acts[0].sets == ["default", "staging"])
    }

    @Test func activatingNeverNarrowsExistingReferences() throws {
        // An activation that happens to reference two configs must keep both.
        let activation = DDMLibraryItem(
            json: DDMDeclarations.activation(identifier: "com.x.cfg.activation", configurationIDs: ["com.x.cfg", "com.x.other"]),
            sets: ["default"])
        let fixed = DDMLibraryItem.activating(configID: "com.x.cfg", in: "staging", within: [activation])
        let act = try #require(fixed.first { $0.identifier == "com.x.cfg.activation" })
        #expect(Set(act.payload["StandardConfigurations"] as? [String] ?? []) == ["com.x.cfg", "com.x.other"])
        #expect(act.sets == ["default", "staging"])
    }

    @Test func passcodeSettingsEmitsOnlyMeaningfulKeys() throws {
        let data = DDMDeclarations.passcodeSettings(
            identifier: "com.x.pass",
            requirePasscode: true, minimumLength: 10,
            requireAlphanumeric: true, requireComplex: false,
            minimumComplexChars: 0,          // omitted (0)
            maxInactivityMinutes: 5,
            maxFailedAttempts: 1,            // below 2 → omitted
            maxAgeInDays: 0,                 // omitted (never)
            reuseLimit: 6, changeAtNextAuth: true)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["Type"] as? String == "com.apple.configuration.passcode.settings")
        let p = try #require(obj["Payload"] as? [String: Any])
        #expect(p["RequirePasscode"] as? Bool == true)
        #expect(p["MinimumLength"] as? Int == 10)
        #expect(p["RequireAlphanumericPasscode"] as? Bool == true)
        #expect(p["MaximumInactivityInMinutes"] as? Int == 5)
        #expect(p["PasscodeReuseLimit"] as? Int == 6)
        #expect(p["ChangeAtNextAuth"] as? Bool == true)
        // Omitted: complex, min-complex-chars, sub-2 failed attempts, never-expire.
        #expect(p["RequireComplexPasscode"] == nil)
        #expect(p["MinimumComplexCharacters"] == nil)
        #expect(p["MaximumFailedAttempts"] == nil)
        #expect(p["MaximumPasscodeAgeInDays"] == nil)

        let summary = DDMDeclarationSummary.make(type: obj["Type"] as! String, payload: p)
        #expect(summary.title == "Passcode policy")
        #expect(summary.rows.contains { $0.label == "Minimum length" && $0.value == "10" })
        #expect(summary.rows.contains { $0.label == "Login password" && $0.value == "Required" })
    }

    @Test func passcodeSettingsFailedAttemptsInRangeEmitted() throws {
        let data = DDMDeclarations.passcodeSettings(
            identifier: "com.x.pass",
            requirePasscode: true, minimumLength: 0,
            requireAlphanumeric: false, requireComplex: true,
            minimumComplexChars: 2, maxInactivityMinutes: 0,
            maxFailedAttempts: 5, maxAgeInDays: 90,
            reuseLimit: 0, changeAtNextAuth: false)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let p = try #require(obj["Payload"] as? [String: Any])
        #expect(p["MaximumFailedAttempts"] as? Int == 5)
        #expect(p["MinimumComplexCharacters"] as? Int == 2)
        #expect(p["MaximumPasscodeAgeInDays"] as? Int == 90)
        #expect(p["MinimumLength"] == nil)               // 0 → omitted
        #expect(p["PasscodeReuseLimit"] == nil)          // 0 → omitted
    }

    @Test func updateEnforcementFormatsDeadlineAndOmitsEmptyURL() throws {
        var comps = DateComponents()
        (comps.year, comps.month, comps.day) = (2026, 7, 1)
        (comps.hour, comps.minute, comps.second) = (9, 30, 0)
        let date = try #require(Calendar(identifier: .gregorian).date(from: comps))
        let data = DDMDeclarations.updateEnforcement(identifier: "com.x.u", targetVersion: "15.5", deadline: date, detailsURL: "")
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let p = try #require(obj["Payload"] as? [String: Any])
        #expect(p["TargetOSVersion"] as? String == "15.5")
        // Local wall-clock, no zone (both Calendar + formatter use the same default tz).
        #expect(p["TargetLocalDateTime"] as? String == "2026-07-01T09:30:00")
        #expect(p["DetailsURL"] == nil)   // empty URL omitted
    }

    @Test func activationBuilderAndIdConvention() throws {
        #expect(DDMDeclarations.activationID(for: "com.x.cfg") == "com.x.cfg.activation")
        let data = DDMDeclarations.activation(identifier: "com.x.cfg.activation", configurationIDs: ["com.x.cfg"])
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["Type"] as? String == "com.apple.activation.simple")
        #expect(((obj["Payload"] as? [String: Any])?["StandardConfigurations"] as? [String]) == ["com.x.cfg"])
    }

    @Test func summaryLegacyUnknownAndEmptyRows() {
        let legacy = DDMDeclarationSummary.make(type: "com.apple.configuration.legacy",
                                                payload: ["ProfileURL": "https://x/y.mobileconfig"])
        #expect(legacy.title == "Legacy profile")
        #expect(legacy.rows.first?.value == "https://x/y.mobileconfig")

        // Unknown type falls back to its kind segment, no rows.
        let unknown = DDMDeclarationSummary.make(type: "com.apple.management.organization-info", payload: [:])
        #expect(unknown.title == "Management")
        #expect(unknown.rows.isEmpty)

        // Status subscriptions with no items → no "Reports" row.
        let emptyStatus = DDMDeclarationSummary.make(
            type: "com.apple.configuration.management.status-subscriptions",
            payload: ["StatusItems": [[String: Any]]()])
        #expect(emptyStatus.title == "Status reporting")
        #expect(emptyStatus.rows.isEmpty)

        // Activation referencing nothing → no "Turns on" row.
        let emptyAct = DDMDeclarationSummary.make(type: "com.apple.activation.simple",
                                                  payload: ["StandardConfigurations": [String]()])
        #expect(emptyAct.title == "Activation")
        #expect(emptyAct.rows.isEmpty)
    }

    @Test func prettyJSONSortsKeys() throws {
        let item = DDMLibraryItem(json: Data(#"{"Payload":{},"Identifier":"com.x.a","Type":"com.apple.activation.simple"}"#.utf8))
        let pretty = item.prettyJSON
        let iIdentifier = try #require(pretty.range(of: "Identifier")).lowerBound
        let iType = try #require(pretty.range(of: "Type")).lowerBound
        #expect(iIdentifier < iType)   // sortedKeys: Identifier < Payload < Type
    }

    @Test func setsMatrixRowsSortedByTitle() {
        let items = [
            DDMLibraryItem(json: decl(type: "com.apple.activation.simple", id: "z"), sets: []),                              // "Activation"
            DDMLibraryItem(json: decl(type: "com.apple.configuration.management.status-subscriptions", id: "a"), sets: []),  // "Status reporting"
        ]
        let m = DDMSetsMatrix.make(from: items)
        #expect(m.rows.map(\.title) == ["Activation", "Status reporting"])
    }

    @Test func setContentsFlagsUnactivatedConfigs() {
        // A config with its activation in the set, a config without one, and
        // an item in a different set that must be excluded.
        let activated = DDMLibraryItem(json: decl(type: "com.apple.configuration.softwareupdate.enforcement.specific", id: "com.x.update"), sets: ["default"])
        let activation = DDMLibraryItem(
            json: DDMDeclarations.activation(identifier: "com.x.update.activation", configurationIDs: ["com.x.update"]),
            sets: ["default"])
        let orphanConfig = DDMLibraryItem(json: decl(type: "com.apple.configuration.diskmanagement.settings", id: "com.x.disk"), sets: ["default"])
        let elsewhere = DDMLibraryItem(json: decl(type: "com.apple.configuration.foo", id: "com.x.other"), sets: ["security"])

        let c = DDMSetContents.make(set: "default", items: [activated, activation, orphanConfig, elsewhere])
        #expect(c.set == "default")
        #expect(c.configs.count == 2)                 // two configs, activation + elsewhere excluded
        #expect(c.activationCount == 1)
        #expect(c.configs.contains { $0.identifier == "com.x.update" && $0.isActivated })
        #expect(c.unactivated.map(\.identifier) == ["com.x.disk"])
    }

    @Test func setContentsEmptyForUnknownSet() {
        let item = DDMLibraryItem(json: decl(type: "com.apple.configuration.foo", id: "com.x.a"), sets: ["default"])
        let c = DDMSetContents.make(set: "nope", items: [item])
        #expect(c.configs.isEmpty)
        #expect(c.activationCount == 0)
        #expect(c.unactivated.isEmpty)
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
