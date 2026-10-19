import Foundation

/// Records which profiles Edict has deployed to which device, so the
/// device detail can compare against what's actually installed
/// (drift detection). File-backed JSON next to the saved profiles.
enum DeploymentLog {
    struct Entry: Codable, Hashable {
        var identifier: String   // PayloadIdentifier
        var name: String
        var epoch: Double
        /// The deployed bytes, so drift remediation can re-push exactly.
        var dataBase64: String = ""
        var data: Data { Data(base64Encoded: dataBase64) ?? Data() }
    }

    private static var fileURL: URL {
        let base = URL.applicationSupportDirectory
        return base.appendingPathComponent(SavedProfilesStore.dirName, isDirectory: true)
            .appendingPathComponent("deployments.json")
    }

    /// deviceID -> deployed profiles.
    static func load() -> [String: [Entry]] {
        guard let raw = try? Data(contentsOf: fileURL) else { return [:] }
        // Decrypt; fall back to legacy plaintext (re-encrypted on next save).
        let json = ProfileVault.open(raw) ?? raw
        return (try? JSONDecoder().decode([String: [Entry]].self, from: json)) ?? [:]
    }

    private static func save(_ map: [String: [Entry]]) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(map),
           let sealed = ProfileVault.seal(data) { try? sealed.write(to: fileURL, options: .atomic) }
    }

    // Serializes the read-modify-write so concurrent record/forget calls
    // (a manual deploy racing a fleet-refresh onboarding pass) don't
    // last-writer-wins away each other's entries. ponytail: reads
    // (load/entries) stay lock-free — atomic writes mean a reader always
    // sees a complete old-or-new file, never a partial one.
    private static let ioQueue = DispatchQueue(label: "xyz.hellocomputer.edict.deploymentlog")

    /// Record a deploy of `profileData` to `deviceIDs`, keyed by the
    /// profile's PayloadIdentifier (so re-deploys replace the entry).
    static func record(profileData: Data, name: String, to deviceIDs: [String], nowEpoch: Double) async {
        guard let id = await payloadIdentifier(profileData) else { return }
        let b64 = profileData.base64EncodedString()
        ioQueue.sync {
            var map = load()
            for d in deviceIDs {
                var list = map[d] ?? []
                list.removeAll { $0.identifier == id }
                list.append(Entry(identifier: id, name: name, epoch: nowEpoch, dataBase64: b64))
                map[d] = list
            }
            save(map)
        }
    }

    static func entries(for deviceID: String) -> [Entry] {
        load()[deviceID] ?? []
    }

    static func forget(deviceID: String, identifier: String) {
        ioQueue.sync {
            var map = load()
            map[deviceID]?.removeAll { $0.identifier == identifier }
            save(map)
        }
    }

    /// Top-level PayloadIdentifier of a profile (signed or plain). Signed
    /// profiles are stripped via `security cms -D` on a detached task so the
    /// subprocess never blocks the main actor (this runs on the deploy and
    /// fleet-refresh paths).
    static func payloadIdentifier(_ data: Data) async -> String? {
        guard let plistData = await Task.detached(priority: .userInitiated, operation: { CMSProfile.plistData(data) }).value
        else { return nil }
        guard let obj = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        else { return nil }
        return obj["PayloadIdentifier"] as? String
    }
}
