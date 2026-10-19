import Foundation
import Observation

/// Per-serial cache of MunkiReport inventory pulls. Owned by the app,
/// shared with the dashboard, the right-side inspector pane, and the
/// standalone sheet. Selecting the same host twice in a row hits the cache
/// and renders instantly.
///
/// The cache is persisted to JSON under Application Support and rehydrated
/// at launch, so reopening the app shows the last-known inventory (FileVault,
/// SIP, Gatekeeper, apps, …) immediately instead of a blank table while it
/// re-fetches. Each serial is still refreshed once per app session so the
/// shown data can't go permanently stale.
///
/// Errors are recorded per-serial so the UI can surface a meaningful
/// "MR fetch failed for this host" without losing other cached entries.
@Observable
@MainActor
final class MunkiReportInventoryStore {
    /// `serial → inventory` cache. Rehydrated from disk at launch, kept in
    /// sync to disk on every successful fetch.
    var bySerial: [String: MRHostInventory] = [:]
    /// `serial → when it was last successfully fetched`. Persisted alongside
    /// the data so the UI can show "checked Xm ago" and flag stale entries
    /// (e.g. a Mac that was wiped but whose old inventory is still cached).
    var fetchedAt: [String: Date] = [:]
    /// Which serial we're actively fetching right now (used by the UI to
    /// show a spinner only for the row in flight).
    var loadingSerial: String?
    /// `serial → error` so a per-host failure surfaces in the inspector
    /// without globally blanking everything.
    var errorBySerial: [String: String] = [:]

    /// Serials already refreshed from the server this app session. A
    /// rehydrated disk entry still triggers one background refresh on first
    /// use this launch, but repeated host selection after that hits the
    /// cache without re-fetching.
    @ObservationIgnored private var freshThisSession: Set<String> = []

    init() {
        bySerial = Self.loadCache()
        fetchedAt = Self.loadTimes()
    }

    /// When `serial` was last fetched, if ever — for the "checked Xm ago" line.
    func lastFetched(_ serial: String?) -> Date? {
        guard let s = serial?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return fetchedAt[s]
    }

    /// Kick off a fetch for `serial` unless it's already been refreshed this
    /// session (or is in flight). Cheap to call repeatedly — safe from
    /// `.onChange`/`.task`. A rehydrated entry is shown immediately and
    /// refreshed in the background the first time it's needed this launch.
    func loadIfNeeded(serial: String, settings: SettingsStore) {
        guard !serial.isEmpty else { return }
        guard !freshThisSession.contains(serial), loadingSerial != serial else { return }
        guard settings.isMunkiReportAPIConfigured else { return }
        Task { await fetch(serial: serial, settings: settings) }
    }

    /// Force re-fetch — invalidates the cache entry and pulls again.
    /// Triggered by the inspector's refresh button.
    func refresh(serial: String, settings: SettingsStore) {
        guard !serial.isEmpty else { return }
        bySerial.removeValue(forKey: serial)
        fetchedAt.removeValue(forKey: serial)
        freshThisSession.remove(serial)
        errorBySerial.removeValue(forKey: serial)
        Task { await fetch(serial: serial, settings: settings) }
    }

    private func fetch(serial: String, settings: SettingsStore) async {
        loadingSerial = serial
        defer { if loadingSerial == serial { loadingSerial = nil } }
        do {
            let client = MunkiReportClient()
            let inv = try await client.fetchHost(serial: serial, settings: settings)
            bySerial[serial] = inv
            fetchedAt[serial] = Date()
            freshThisSession.insert(serial)
            errorBySerial.removeValue(forKey: serial)
            persist()
        } catch {
            errorBySerial[serial] = error.localizedDescription
        }
    }

    // MARK: - Disk cache

    private static func appSupportFile(_ name: String) -> URL {
        let base = URL.applicationSupportDirectory
        return base.appendingPathComponent("EdictMDM", isDirectory: true)
            .appendingPathComponent(name)
    }
    private static var cacheURL: URL { appSupportFile("munkireport-inventory.json") }
    private static var timesURL: URL { appSupportFile("munkireport-inventory-times.json") }

    private static func loadCache() -> [String: MRHostInventory] {
        guard let data = try? Data(contentsOf: cacheURL),
              let map = try? JSONDecoder().decode([String: MRHostInventory].self, from: data)
        else { return [:] }
        return map
    }

    private static func loadTimes() -> [String: Date] {
        guard let data = try? Data(contentsOf: timesURL),
              let map = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        return map
    }

    private func persist() {
        let url = Self.cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(bySerial) {
            try? data.write(to: url, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(fetchedAt) {
            try? data.write(to: Self.timesURL, options: .atomic)
        }
    }
}
