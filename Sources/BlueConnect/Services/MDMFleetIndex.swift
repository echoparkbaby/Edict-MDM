import Foundation
import SwiftUI

/// One app-owned inventory shared by fleet, security, policies and inspector.
/// Failed reads retain last-known facts and expose a per-device error.
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
        var loggedInUser: String?
    }

    private(set) var enrollments: [MDMEnrollment] = []
    private(set) var snapshots: [String: MDMStatusSnapshot] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var security: [String: MDMSecurityFacts] = [:]
    private(set) var securityAt: [String: Date] = [:]
    private(set) var names: [String: String] = [:]
    private(set) var bySerial: [String: Entry] = [:]
    private(set) var mdmOnly: [BlueSkyHost] = []
    private(set) var loading = false
    private(set) var loadError: String?
    private(set) var refreshedAt: Date?
    private(set) var pushCert: PushCertInfo?
    private(set) var version = 0
    var deviceQuery = ""
    var activityPendingOnly = false
    var selectedGroupID: UUID?
    var drift: [String: MDMDriftAssessment] = [:]
    @ObservationIgnored private var refreshGen = 0
    @ObservationIgnored private var serverIdentity = ""
    @ObservationIgnored private var lastBSCSerials: Set<String> = []
    @ObservationIgnored private let cacheURL: URL?

    struct Cache: Codable {
        var server: String
        var snapshots: [String: MDMStatusSnapshot]
        var security: [String: MDMSecurityFacts]
        var securityAt: [String: Date]
        var names: [String: String]
    }

    init(cacheURL: URL? = URL.applicationSupportDirectory.appendingPathComponent("EdictMDM/fleet-evidence.json")) {
        self.cacheURL = cacheURL
    }

    var devices: [MDMEnrollment] { enrollments.filter(\.isDevice) }

    func entry(forSerial serial: String?) -> Entry? {
        guard let s = serial?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        guard var entry = bySerial[s.uppercased()] else { return nil }
        if loadError != nil || errors[entry.enrollmentID] != nil { entry.compliant = nil }
        return entry
    }

    func entry(for host: BlueSkyHost) -> Entry? {
        if let e = entry(forSerial: host.serialnum) { return e }
        guard host.isMDMOnly, let d = devices.first(where: { -abs(BlueSkyHost.stableHash($0.id)) == host.id }) else { return nil }
        let f = snapshots[d.id]
        return Entry(enrollmentID: d.id, enrolled: d.isEnabled, os: f?.os, fileVault: f?.fileVault,
                     model: f?.model, compliant: nil, lastSeen: d.lastSeenDate, loggedInUser: d.loggedInUser)
    }

    func recordSecurity(_ facts: MDMSecurityFacts, for id: String, at date: Date = Date()) {
        security[id] = security[id].map { $0.merging(facts) } ?? facts
        securityAt[id] = date
        version += 1
        persist()
    }

    func recordName(_ name: String, for id: String) {
        names[id] = name
        version += 1
        persist()
    }

    /// Injectable reads make partial failure and out-of-order refreshes testable.
    func refresh(settings: SettingsStore, bscSerials: Set<String>,
                 list: (() async throws -> [MDMEnrollment])? = nil,
                 status: ((String) async throws -> MDMStatusSnapshot)? = nil) async {
        guard settings.mdmEnabled, settings.mdmConfigured,
              !settings.mdmDevicesAPIBaseURL.trimmingCharacters(in: .whitespaces).isEmpty else {
            refreshGen += 1
            enrollments = []; bySerial = [:]; mdmOnly = []; snapshots = [:]
            errors = [:]; security = [:]; securityAt = [:]; names = [:]
            loadError = nil; refreshedAt = nil; pushCert = nil; loading = false
            version += 1
            return
        }
        let identity = settings.mdmDevicesAPIBaseURL + "|" + settings.kmfddmBaseURL
        if identity != serverIdentity {
            serverIdentity = identity
            snapshots = [:]; security = [:]; securityAt = [:]; names = [:]
            enrollments = []; bySerial = [:]; mdmOnly = []; errors = [:]; drift = [:]
            refreshedAt = nil; pushCert = nil
            if let cacheURL, let data = try? Data(contentsOf: cacheURL),
               let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.server == identity {
                snapshots = cache.snapshots; security = cache.security
                securityAt = cache.securityAt; names = cache.names
            }
        }
        refreshGen += 1
        let gen = refreshGen
        loading = true; loadError = nil
        defer { if gen == refreshGen { loading = false } }
        let api = EnrollmentsAPI(settings: settings)
        let kmf = KMFDDMService(settings: settings)
        do {
            let rows: [MDMEnrollment]
            if let list { rows = try await list() } else { rows = try await api.list() }
            guard gen == refreshGen, !Task.isCancelled else { return }
            enrollments = rows
            var next = snapshots
            var failures: [String: String] = [:]
            // Bounded batches avoid serial fleet latency and unbounded fan-out.
            let devices = rows.filter(\.isDevice)
            for offset in stride(from: 0, to: devices.count, by: 6) {
                let batch = Array(devices[offset..<min(offset + 6, devices.count)])
                let results = await withTaskGroup(of: (String, Result<MDMStatusSnapshot, Error>).self) { group in
                    for device in batch {
                        group.addTask {
                            do {
                                let value: MDMStatusSnapshot
                                if let status { value = try await status(device.id) }
                                else { value = try await kmf.checkedStatus(enrollmentID: device.id) }
                                return (device.id, .success(value))
                            } catch { return (device.id, .failure(error)) }
                        }
                    }
                    var results: [(String, Result<MDMStatusSnapshot, Error>)] = []
                    for await result in group { results.append(result) }
                    return results
                }
                guard gen == refreshGen, !Task.isCancelled else { return }
                for (id, result) in results {
                    switch result {
                    case .success(let value):
                        if !value.hasData, next[id]?.hasData == true {
                            failures[id] = "No current status values returned; displaying last-known evidence."
                        }
                        next[id] = next[id].map { $0.merging(value) } ?? value
                    case .failure(let error): failures[id] = error.localizedDescription
                    }
                }
            }
            let ids = Set(devices.map(\.id))
            snapshots = next.filter { ids.contains($0.key) }
            security = security.filter { ids.contains($0.key) }
            securityAt = securityAt.filter { ids.contains($0.key) }
            names = names.filter { ids.contains($0.key) }
            drift = drift.filter { ids.contains($0.key) }
            errors = failures
            rebuildIndex(settings: settings, bscSerials: bscSerials)
            refreshedAt = Date()
            version += 1
            persist()
            if list == nil {
                let cert = try? await api.pushCert()
                if gen == refreshGen { pushCert = cert }
            }
        } catch {
            if gen == refreshGen { loadError = error.localizedDescription; version += 1 }
        }
    }

    func rebuildIndex(settings: SettingsStore, bscSerials: Set<String>) {
        lastBSCSerials = bscSerials
        var map: [String: Entry] = [:]
        var only: [BlueSkyHost] = []
        for d in devices {
            let f = snapshots[d.id]
            let compliance = SmartGroup.compliant(
                .init(osVersion: f?.os, fileVaultOn: f?.fileVault, model: f?.model,
                      matchedBlueSky: false, enrolled: d.isEnabled),
                requireFileVault: settings.mdmRequireFileVault, minOS: settings.mdmMinOSVersion)
            let fresh = errors[d.id] == nil && d.lastSeenDate.map { Date().timeIntervalSince($0) < 7 * 86400 } == true
            let entry = Entry(enrollmentID: d.id, enrolled: d.isEnabled, os: f?.os, fileVault: f?.fileVault,
                              model: f?.model, compliant: fresh ? compliance : nil, lastSeen: d.lastSeenDate,
                              loggedInUser: d.loggedInUser)
            let serial = d.serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if let serial, !serial.isEmpty { map[serial] = entry }
            let linked = serial.map { !$0.isEmpty && bscSerials.contains($0) } ?? false
            if !linked {
                let stored = settings.mdmDevices.first { $0.id == d.id }
                let name = stored?.label.nilIfBlank ?? names[d.id] ?? stored?.autoName?.nilIfBlank ?? d.serialNumber ?? String(d.id.prefix(8))
                only.append(.mdmOnly(enrollment: d, label: name))
            }
        }
        bySerial = map; mdmOnly = only
    }

    func refreshDevice(_ id: String, settings: SettingsStore) async {
        let identity = serverIdentity
        do {
            let value = try await KMFDDMService(settings: settings).checkedStatus(enrollmentID: id)
            guard identity == serverIdentity else { return }
            if !value.hasData, snapshots[id]?.hasData == true {
                errors[id] = "No current status values returned; displaying last-known evidence."
            } else { errors.removeValue(forKey: id) }
            snapshots[id] = snapshots[id].map { $0.merging(value) } ?? value
            rebuildIndex(settings: settings, bscSerials: lastBSCSerials)
            version += 1
            persist()
        } catch {
            guard identity == serverIdentity else { return }
            errors[id] = error.localizedDescription
            version += 1
        }
    }

    private func persist() {
        guard let cacheURL else { return }
        let cache = Cache(server: serverIdentity, snapshots: snapshots, security: security, securityAt: securityAt, names: names)
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        } catch { Log.warn("MDM", "Couldn't save fleet evidence: \(error.localizedDescription)") }
    }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
