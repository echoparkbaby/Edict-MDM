import Testing
import Foundation
@testable import BlueConnectAdmin

/// The pure "which devices are new enough to auto-onboard" filter — real,
/// enabled Macs that enrolled at/after the cutoff and aren't already
/// onboarded. Built from decoded enrollment JSON since MDMEnrollment has
/// only a Decodable init.
@Suite("Onboarding device filter")
struct OnboardingServiceTests {

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private let cutoff = OnboardingServiceTests.iso.date(from: "2026-06-22T00:00:00Z")!.timeIntervalSince1970

    private func enr(_ id: String, type: String = "Device", enabled: Int = 1, created: String?) throws -> MDMEnrollment {
        var dict: [String: Any] = ["id": id, "type": type, "enabled": enabled]
        if let created { dict["created_at"] = created }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(MDMEnrollment.self, from: data)
    }

    @Test func includesOnlyNewEnabledUnonboardedDevices() throws {
        let list = [
            try enr("after",   created: "2026-06-22T12:00:00Z"),  // ✓ enrolled after cutoff
            try enr("before",  created: "2026-06-21T12:00:00Z"),  // ✗ enrolled before
            try enr("user",    type: "User", created: "2026-06-22T12:00:00Z"), // ✗ not a device
            try enr("disabled", enabled: 0, created: "2026-06-22T12:00:00Z"),  // ✗ checked out
            try enr("done",    created: "2026-06-22T12:00:00Z"),  // ✗ already onboarded
            try enr("nodate",  created: nil),                     // ✗ unknown enrollment time
        ]
        let result = OnboardingService.devicesToOnboard(list, enabledAt: cutoff, onboarded: ["done"])
        #expect(result.map(\.id) == ["after"])
    }

    @Test func cutoffIsInclusive() throws {
        let exactly = try enr("exact", created: "2026-06-22T00:00:00Z")  // == cutoff
        let result = OnboardingService.devicesToOnboard([exactly], enabledAt: cutoff, onboarded: [])
        #expect(result.map(\.id) == ["exact"])
    }

    @Test func emptyWhenAllOnboarded() throws {
        let list = [try enr("a", created: "2026-06-22T12:00:00Z"),
                    try enr("b", created: "2026-06-22T13:00:00Z")]
        #expect(OnboardingService.devicesToOnboard(list, enabledAt: cutoff, onboarded: ["a", "b"]).isEmpty)
    }

    // MARK: - Group baseline (smart-group policy)

    private func group(_ name: String, rule: SmartGroupRule.Field, value: String = "",
                       sets: [String] = [], profiles: [UUID] = []) -> SmartGroup {
        SmartGroup(name: name, rules: [SmartGroupRule(field: rule, value: value)],
                   onboardProfileIDs: profiles, onboardSets: sets)
    }

    @Test func groupBaselineUnionsMatchingGroups() {
        let pA = UUID(), pB = UUID()
        let groups = [
            group("FileVault on", rule: .fileVaultOn, sets: ["security"], profiles: [pA]),
            group("Sonoma+", rule: .osAtLeast, value: "14", sets: ["base"], profiles: [pB]),
            group("Old", rule: .osBelow, value: "13", sets: ["legacy"]),   // won't match
            group("No baseline", rule: .enrolled),                         // matches but empty
        ]
        let facts = SmartGroup.DeviceFacts(osVersion: "15.5", fileVaultOn: true, model: "MacBookPro",
                                           matchedBlueSky: true, enrolled: true)
        let bl = OnboardingService.groupBaseline(for: facts, in: groups, requireFileVault: false, minOS: "")
        #expect(Set(bl.sets) == ["security", "base"])      // union of the two matching groups, not "legacy"
        #expect(Set(bl.profiles) == [pA, pB])
    }

    @Test func groupBaselineEmptyWhenNoMatchOrNoBaseline() {
        let groups = [group("FV off", rule: .fileVaultOff, sets: ["x"])]
        let facts = SmartGroup.DeviceFacts(osVersion: "15.5", fileVaultOn: true, model: nil,
                                           matchedBlueSky: false, enrolled: true)
        let bl = OnboardingService.groupBaseline(for: facts, in: groups, requireFileVault: false, minOS: "")
        #expect(bl.sets.isEmpty && bl.profiles.isEmpty)
    }
}
