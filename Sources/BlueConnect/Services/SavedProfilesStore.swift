import Foundation

/// File-backed store for the saved/favorited configuration profiles. JSON
/// at `~/Library/Application Support/EdictMDM/saved-profiles.json` so the
/// (potentially large, base64) profile blobs stay out of UserDefaults.
enum SavedProfilesStore {
    static let dirName = "EdictMDM"

    static var fileURL: URL {
        let base = URL.applicationSupportDirectory
        return base.appendingPathComponent(dirName, isDirectory: true)
            .appendingPathComponent("saved-profiles.json")
    }

    static func load() -> [SavedProfile] {
        guard let raw = try? Data(contentsOf: fileURL) else { return [] }
        // Decrypt; fall back to legacy plaintext (re-encrypted on next save).
        let json = ProfileVault.open(raw) ?? raw
        return (try? JSONDecoder().decode([SavedProfile].self, from: json)) ?? []
    }

    static func save(_ list: [SavedProfile]) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list),
           let sealed = ProfileVault.seal(data) {
            try? sealed.write(to: fileURL, options: .atomic)
        }
    }

    /// Read a profile's display name + payload-type summary, handling both
    /// plain-XML and CMS-signed profiles (the latter via `security cms -D`).
    static func describe(_ data: Data, fallbackName: String) async -> (name: String, summary: String) {
        await Task.detached(priority: .userInitiated) {
            // Signed profiles decode via `security cms -D` (a subprocess) —
            // keep it off the main actor so importing signed .mobileconfigs
            // doesn't stall the UI once per file.
            let plistData = CMSProfile.plistData(data) ?? data
            guard let obj = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
            else { return (fallbackName, data.first == 0x30 ? "signed" : "") }
            let name = (obj["PayloadDisplayName"] as? String) ?? fallbackName
            var types: [String] = []
            if let content = obj["PayloadContent"] as? [[String: Any]] {
                types = content.compactMap { friendlyType($0["PayloadType"] as? String) }
            }
            let summary = Array(NSOrderedSet(array: types)).compactMap { $0 as? String }.prefix(4).joined(separator: ", ")
            return (name, summary)
        }.value
    }

    /// Map a payload type to a short human label for the summary.
    private static func friendlyType(_ t: String?) -> String? {
        guard let t else { return nil }
        let map: [String: String] = [
            "com.apple.TCC.configuration-profile-policy": "Privacy (TCC)",
            "com.apple.notificationsettings": "Notifications",
            "ManagedInstalls": "Munki",
            "com.googlecode.munki.ManagedInstalls": "Munki",
            "com.apple.MCX.FileVault2": "FileVault",
            "com.apple.security.firewall": "Firewall",
            "com.apple.SoftwareUpdate": "Software Update",
            "com.apple.wifi.managed": "Wi-Fi",
            "com.apple.dock": "Dock",
            "com.apple.finder": "Finder",
        ]
        if let f = map[t] { return f }
        // Trailing component of the bundle-style type as a fallback.
        return t.split(separator: ".").last.map(String.init)
    }
}
