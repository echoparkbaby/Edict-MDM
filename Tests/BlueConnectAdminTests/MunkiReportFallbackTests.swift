import Foundation
import Testing
@testable import BlueConnectAdmin

/// A Mac too old for DDM status (pre-macOS 13) gets its dashboard facts
/// from MunkiReport; MDM-reported values are never overwritten.
struct MunkiReportFallbackTests {
    private func facts(os: [String: String] = [:]) -> DashboardFacts {
        DashboardFacts(osVersions: os, fileVault: [:], models: [:], hosts: [], deviceLabels: [:],
                       requireFileVault: false, minOS: "", driftMissing: [:], deploymentCounts: [:])
    }
    private let pine = #"{"serial":"X","machine":{"machine_model":"Macmini7,1","machine_desc":"Mac mini (Late 2014)","os_version":120706},"filevault":{"filevault_status":"0"},"disk_report":{"encrypted":0}}"#

    @Test func fillsGapsAndKeepsMDMValues() throws {
        let inv = try JSONDecoder().decode(MRHostInventory.self, from: Data(pine.utf8))
        var empty = facts()
        empty.fillGaps("a", from: inv)
        #expect(empty.osVersions["a"] == "12.7.6")
        #expect(empty.models["a"] == "Mac mini (Late 2014)")
        #expect(empty.fileVault["a"] == "false")

        var reported = facts(os: ["a": "27.2"])
        reported.fillGaps("a", from: inv)
        #expect(reported.osVersions["a"] == "27.2")
        #expect(empty.sourceNote("a", "os") == "via MunkiReport")
        #expect(reported.sourceNote("a", "os") == "")
    }
}
