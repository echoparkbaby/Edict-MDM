import Foundation
import Testing
@testable import BlueConnectAdmin

@Suite("MDM evidence and command outcomes")
struct MDMWorkflowTests {
    private let tracked = [DeploymentLog.Entry(identifier: "example.policy", name: "Policy", epoch: 1)]

    private func reply(_ status: String, profiles: [[String: String]]? = nil) throws -> CommandResult {
        var plist: [String: Any] = ["Status": status]
        if let profiles { plist["ProfileList"] = profiles }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return CommandResult(status: status, result: String(decoding: data, as: UTF8.self))
    }

    @Test func partialServerFailuresAreNotSuccessfulEnqueues() {
        let rejected = Data(#"{"status":{"A":{"command_error":{"error":"not enrolled"}}}}"#.utf8)
        #expect(throws: (any Error).self) { try NanoMDMService.enqueueWarning(rejected) }
        let accepted = Data(#"{"status":{"A":{"push_error":{"error":"APNs unavailable"}}},"command_uuid":"id"}"#.utf8)
        #expect((try? NanoMDMService.enqueueWarning(accepted)) != nil)
        let success = Data(#"{"status":{"A":{"push_result":"push-id"}},"command_uuid":"id"}"#.utf8)
        #expect((try? NanoMDMService.enqueueWarning(success)) == nil)
    }

    @Test func noBaselineDoesNotProduceAPass() {
        let facts = SmartGroup.DeviceFacts(osVersion: nil, fileVaultOn: nil, model: nil,
                                          matchedBlueSky: false, enrolled: true)
        #expect(SmartGroup.compliant(facts, requireFileVault: false, minOS: "") == nil)
    }

    @Test func checkedOutDeviceDoesNotPassBaseline() {
        let facts = SmartGroup.DeviceFacts(osVersion: "26", fileVaultOn: true, model: nil,
                                          matchedBlueSky: false, enrolled: false)
        #expect(SmartGroup.compliant(facts, requireFileVault: true, minOS: "15") == false)
    }

    @Test func missingOrDeferredDriftResponsesAreNotVerified() throws {
        #expect(MDMDriftAssessment.evaluate(nil, tracked: tracked).outcome == .waiting)
        #expect(MDMDriftAssessment.evaluate(try reply("NotNow"), tracked: tracked).outcome == .waiting)
        #expect(MDMDriftAssessment.evaluate(try reply("Error"), tracked: tracked).outcome == .failed)
        #expect(MDMDriftAssessment.evaluate(try reply("Acknowledged"), tracked: tracked).outcome == .failed)
    }

    @Test func onlyAcknowledgedProfileListCanEstablishDrift() throws {
        let missing = MDMDriftAssessment.evaluate(try reply("Acknowledged", profiles: []), tracked: tracked)
        #expect(missing.outcome == .verified)
        #expect(missing.missing.map(\.identifier) == ["example.policy"])
        let present = MDMDriftAssessment.evaluate(try reply("Acknowledged", profiles: [["PayloadIdentifier": "example.policy"]]), tracked: tracked)
        #expect(present.outcome == .verified)
        #expect(present.missing.isEmpty)
        #expect(MDMDriftAssessment.evaluate(nil, tracked: []).outcome == .untracked)
    }

    @Test func partialSnapshotsPreserveKnownFalseAndPriorValues() {
        let prior = MDMStatusSnapshot(os: "15.7", fileVault: false, model: "Mac", updateState: "failed",
                                      pendingOS: "26.1", updateFailure: "Insufficient space")
        let next = MDMStatusSnapshot(os: "26.1")
        let merged = prior.merging(next)
        #expect(merged.os == "26.1")
        #expect(merged.fileVault == false)
        #expect(merged.model == "Mac")
        #expect(merged.updateFailure == "Insufficient space")
        let completed = merged.merging(.init(updateState: "none"))
        #expect(completed.updateFailure == nil)
        #expect(completed.pendingOS == nil)
        #expect(prior.merging(MDMStatusSnapshot()).checkedAt == prior.checkedAt)
    }

    @Test func invalidFileVaultValuesNeverBecomeFalse() {
        let invalid: [String: Any] = ["StatusItems": ["diskmanagement": ["filevault": ["enabled": "diskmanagement.filevault.enabled"]]]]
        #expect(KMFDDMService.snapshot(report: invalid, items: []).fileVault == nil)
        let disabled: [String: Any] = ["StatusItems": ["diskmanagement": ["filevault": ["enabled": false]]]]
        #expect(KMFDDMService.snapshot(report: disabled, items: []).fileVault == false)
    }

    @Test func unavailableEvidenceOverridesAFormerPass() {
        let d = MDMEnrollment(id: "A", type: "Device", enabled: 1)
        var facts = DashboardFacts(osVersions: ["A": "26"], fileVault: ["A": "true"], models: [:],
                                   hosts: [], deviceLabels: [:], requireFileVault: true, minOS: "15",
                                   driftMissing: [:], deploymentCounts: [:])
        #expect(facts.compliant(for: d) == true)
        facts.unavailableDeviceIDs = ["A"]
        #expect(facts.compliant(for: d) == nil)
        #expect(facts.matchesQuery(d, "unknown"))
    }

    @Test func olderSavedViewsRemainReadable() throws {
        let data = Data(#"{"id":"9E7734FE-F968-4A1E-9BE0-1FA1D6CDDA23","name":"Existing","attribute":"macOS version"}"#.utf8)
        let view = try JSONDecoder().decode(PrismView.self, from: data)
        #expect(view.name == "Existing")
        #expect(view.search == nil)
    }

    @Test @MainActor func securityCacheRetainsOtherControls() {
        let store = MDMFleetIndex(cacheURL: nil)
        store.recordSecurity(MDMSecurityFacts(securityInfo: ["SystemIntegrityProtectionEnabled": true]), for: "A")
        #expect(store.security["A"]?.sipEnabled == true)
        #expect(store.security["A"]?.firewallEnabled == nil)
        #expect(store.securityAt["A"] != nil)
        store.recordSecurity(MDMSecurityFacts(securityInfo: ["FDE_Enabled": false]), for: "A")
        #expect(store.security["A"]?.sipEnabled == true)
        #expect(store.security["A"]?.fileVaultEnabled == false)
    }

    @Test @MainActor func commandMetadataTransitionsThroughDeviceResults() throws {
        let store = MDMCommandStore(fileURL: nil)
        let command = NanoMDMService.commandWithUUID([("RequestType", "ProfileList")])
        store.record(server: "test", target: "A", plist: command.1)
        #expect(store.entries.first?.state == .queued)
        store.apply(try reply("NotNow"), to: command.0, server: "test")
        #expect(store.entries.first?.state == .deferred)
        store.apply(try reply("Acknowledged", profiles: []), to: command.0, server: "test")
        #expect(store.entries.first?.state == .acknowledged)
    }

    @Test @MainActor func aBulkReplyDoesNotConfirmEveryDevice() throws {
        let store = MDMCommandStore(fileURL: nil)
        let command = NanoMDMService.commandWithUUID([("RequestType", "ProfileList")])
        store.record(server: "test", target: "A,B", plist: command.1)
        store.apply(try reply("Acknowledged", profiles: []), to: command.0, server: "test")
        #expect(store.entries.first?.state == .unverified)
    }

    @Test @MainActor func commandResultsCannotCrossServers() throws {
        let store = MDMCommandStore(fileURL: nil)
        let command = NanoMDMService.commandWithUUID([("RequestType", "ProfileList")])
        store.record(server: "one", target: "A", plist: command.1)
        store.apply(try reply("Acknowledged", profiles: []), to: command.0, server: "two")
        #expect(store.entries.first?.state == .queued)
    }
}
