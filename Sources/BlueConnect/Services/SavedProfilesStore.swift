import Foundation

/// File-backed store for the saved/favorited configuration profiles. JSON
/// at `~/Library/Application Support/EdictMDM/saved-profiles.json` so the
/// (potentially large, base64) profile blobs stay out of UserDefaults.
enum SavedProfilesStore {
    static let dirName = "EdictMDM"

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(dirName, isDirectory: true)
            .appendingPathComponent("saved-profiles.json")
    }

    static func load() -> [SavedProfile] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([SavedProfile].self, from: data)
        else { return [] }
        return list
    }

    static func save(_ list: [SavedProfile]) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Read a profile's display name + payload-type summary, handling both
    /// plain-XML and CMS-signed profiles (the latter via `security cms -D`).
    static func describe(_ data: Data, fallbackName: String) -> (name: String, summary: String) {
        let plistData = data.first == 0x30 ? (decodeSigned(data) ?? data) : data
        guard let obj = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        else { return (fallbackName, data.first == 0x30 ? "signed" : "") }
        let name = (obj["PayloadDisplayName"] as? String) ?? fallbackName
        var types: [String] = []
        if let content = obj["PayloadContent"] as? [[String: Any]] {
            types = content.compactMap { friendlyType($0["PayloadType"] as? String) }
        }
        let summary = Array(NSOrderedSet(array: types)).compactMap { $0 as? String }.prefix(4).joined(separator: ", ")
        return (name, summary)
    }

    /// Strip a CMS signature to recover the inner plist via /usr/bin/security.
    private static func decodeSigned(_ data: Data) -> Data? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("edict-\(UUID().uuidString).mobileconfig")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? data.write(to: tmp)) != nil else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["cms", "-D", "-i", tmp.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        return d.isEmpty ? nil : d
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
