import Foundation
import SwiftUI

/// The bridge that lets the BlueSky hosts table double as the MDM fleet
/// view. It loads MDM enrollments + their reported facts once, indexes
/// them by serial number so any BSC host row can show its MDM status
/// (enrolled? OS? FileVault? compliant?), and synthesizes rows for Macs
/// that are MDM-enrolled but absent from BlueSky. Kept separate from the
/// MDM tab views so the merge is additive — the table reads this overlay
/// and is otherwise unchanged.
@MainActor
@Observable
final class MDMFleetIndex {
    struct Entry: Hashable {
        var enrollmentID: String
        var enrolled: Bool
        var os: String?
        var fileVault: Bool?
        var model: String?
        var compliant: Bool?
        var lastSeen: Date?
    }

    /// Serial (uppercased) → MDM facts.
    private(set) var bySerial: [String: Entry] = [:]
    /// Synthetic rows for enrolled Macs with no matching BlueSky host.
    private(set) var mdmOnly: [BlueSkyHost] = []
    private(set) var loading = false
    /// Bumped on every successful refresh so the table can re-derive its
    /// row list (the synthetic rows) — @Observable handles the columns.
    private(set) var version = 0

    func entry(forSerial serial: String?) -> Entry? {
        guard let s = serial?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return bySerial[s.uppercased()]
    }

    /// Reload from the MDM servers. `bscSerials` (uppercased) is the set
    /// of serials already shown by BlueSky, so we only synthesize rows for
    /// the genuinely MDM-only Macs.
    func refresh(settings: SettingsStore, bscSerials: Set<String>) async {
        guard settings.mdmEnabled, settings.mdmConfigured,
              !settings.mdmDevicesAPIBaseURL.trimmingCharacters(in: .whitespaces).isEmpty else {
            if !bySerial.isEmpty || !mdmOnly.isEmpty { bySerial = [:]; mdmOnly = []; version += 1 }
            return
        }
        loading = true
        defer { loading = false }
        guard let enrollments = try? await EnrollmentsAPI(settings: settings).list() else { return }
        let devices = enrollments.filter(\.isDevice)
        let svc = KMFDDMService(settings: settings)
        var map: [String: Entry] = [:]
        var only: [BlueSkyHost] = []
        for d in devices {
            let f = await svc.deviceFacts(enrollmentID: d.id)
            let compliant = SmartGroup.compliant(
                SmartGroup.DeviceFacts(osVersion: f.os, fileVaultOn: f.fileVault,
                                       model: f.model, matchedBlueSky: false, enrolled: d.isEnabled),
                requireFileVault: settings.mdmRequireFileVault, minOS: settings.mdmMinOSVersion)
            let entry = Entry(enrollmentID: d.id, enrolled: d.isEnabled, os: f.os,
                              fileVault: f.fileVault, model: f.model,
                              compliant: compliant, lastSeen: d.lastSeenDate)
            let serial = d.serialNumber?.trimmingCharacters(in: .whitespaces)
            if let serial, !serial.isEmpty {
                map[serial.uppercased()] = entry
                if !bscSerials.contains(serial.uppercased()) {
                    only.append(.mdmOnly(enrollment: d, label: name(for: d, settings: settings)))
                }
            } else {
                only.append(.mdmOnly(enrollment: d, label: name(for: d, settings: settings)))
            }
        }
        bySerial = map
        mdmOnly = only
        version += 1
    }

    /// Friendly label for a synthetic row: operator label, then cached
    /// device name, then serial, then a short id.
    private func name(for enr: MDMEnrollment, settings: SettingsStore) -> String {
        let stored = settings.mdmDevices.first { $0.id == enr.id }
        if let l = stored?.label, !l.isEmpty { return l }
        if let a = stored?.autoName, !a.isEmpty { return a }
        return enr.serialNumber ?? String(enr.id.prefix(8))
    }
}
