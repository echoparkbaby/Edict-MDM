import Foundation

/// Records which profiles Edict has deployed to which device, so the
/// device detail can compare against what's actually installed
/// (drift detection). File-backed JSON next to the saved profiles.
enum DeploymentLog {
    struct Entry: Codable, Hashable {
        var identifier: String   // PayloadIdentifier
        var name: String
        var epoch: Double
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(SavedProfilesStore.dirName, isDirectory: true)
            .appendingPathComponent("deployments.json")
    }

    /// deviceID -> deployed profiles.
    static func load() -> [String: [Entry]] {
        guard let data = try? Data(contentsOf: fileURL),
              let map = try? JSONDecoder().decode([String: [Entry]].self, from: data)
        else { return [:] }
        return map
    }

    private static func save(_ map: [String: [Entry]]) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: fileURL) }
    }

    /// Record a deploy of `profileData` to `deviceIDs`, keyed by the
    /// profile's PayloadIdentifier (so re-deploys replace the entry).
    static func record(profileData: Data, name: String, to deviceIDs: [String], nowEpoch: Double) {
        guard let id = payloadIdentifier(profileData) else { return }
        var map = load()
        for d in deviceIDs {
            var list = map[d] ?? []
            list.removeAll { $0.identifier == id }
            list.append(Entry(identifier: id, name: name, epoch: nowEpoch))
            map[d] = list
        }
        save(map)
    }

    static func entries(for deviceID: String) -> [Entry] {
        load()[deviceID] ?? []
    }

    static func forget(deviceID: String, identifier: String) {
        var map = load()
        map[deviceID]?.removeAll { $0.identifier == identifier }
        save(map)
    }

    /// Top-level PayloadIdentifier of a profile (signed or plain).
    static func payloadIdentifier(_ data: Data) -> String? {
        let plistData: Data
        if data.first == 0x30 {
            // signed — strip via security cms -D
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("edict-\(UUID().uuidString).mobileconfig")
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard (try? data.write(to: tmp)) != nil else { return nil }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["cms", "-D", "-i", tmp.path]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            p.waitUntilExit()
            plistData = out.fileHandleForReading.readDataToEndOfFile()
        } else {
            plistData = data
        }
        guard let obj = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        else { return nil }
        return obj["PayloadIdentifier"] as? String
    }
}
