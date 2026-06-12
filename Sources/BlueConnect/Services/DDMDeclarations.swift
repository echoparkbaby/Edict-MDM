import Foundation

/// Builders for the Apple declarations Edict writes on the operator's
/// behalf, so nobody hand-edits JSON for the common cases. Every
/// configuration ships with a paired activation (`<id>.activation`)
/// because a configuration only takes effect when an activation
/// references it — the pairing matches the pattern proven against the
/// live stack.
enum DDMDeclarations {

    /// `com.apple.configuration.softwareupdate.enforcement.specific` —
    /// the declarative "this macOS version must be installed by this
    /// deadline" enforcement (macOS 14+). The OS nags, downloads, and
    /// force-installs by the deadline on its own.
    ///
    /// `deadline` is rendered as local wall-clock time without a zone —
    /// per Apple, the device interprets it in its own local time.
    static func updateEnforcement(identifier: String,
                                  targetVersion: String,
                                  deadline: Date,
                                  detailsURL: String?) -> Data {
        var payload: [String: Any] = [
            "TargetOSVersion": targetVersion,
            "TargetLocalDateTime": localDateTime.string(from: deadline),
        ]
        if let url = detailsURL, !url.isEmpty {
            payload["DetailsURL"] = url
        }
        return declaration(type: "com.apple.configuration.softwareupdate.enforcement.specific",
                           identifier: identifier,
                           payload: payload)
    }

    /// `com.apple.configuration.management.status-subscriptions` — asks
    /// devices to continuously report the listed status items. This is
    /// what feeds the device-detail pane: OS version/build, model,
    /// serial, and FileVault state, kept current by the device itself.
    /// Conservative, macOS-supported item set.
    static func statusSubscriptions(identifier: String) -> Data {
        let items = [
            "device.identifier.serial-number",
            "device.identifier.udid",
            "device.model.family",
            "device.model.identifier",
            "device.model.marketing-name",
            "device.operating-system.family",
            "device.operating-system.version",
            "device.operating-system.build-version",
            "device.operating-system.marketing-name",
            "diskmanagement.filevault.enabled",
        ]
        return declaration(type: "com.apple.configuration.management.status-subscriptions",
                           identifier: identifier,
                           payload: ["StatusItems": items.map { ["Name": $0] }])
    }

    /// `com.apple.activation.simple` referencing one or more configurations.
    static func activation(identifier: String, configurationIDs: [String]) -> Data {
        declaration(type: "com.apple.activation.simple",
                    identifier: identifier,
                    payload: ["StandardConfigurations": configurationIDs])
    }

    /// Conventional identifier for the activation paired with a config.
    static func activationID(for configID: String) -> String { configID + ".activation" }

    private static func declaration(type: String, identifier: String,
                                    payload: [String: Any]) -> Data {
        let obj: [String: Any] = [
            "Type": type,
            "Identifier": identifier,
            "Payload": payload,
        ]
        // Keys sorted for stable output — KMFDDM hashes content into the
        // ServerToken, so identical input should byte-match.
        return (try? JSONSerialization.data(withJSONObject: obj,
                                            options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    private static let localDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

extension KMFDDMService {
    /// Upload a configuration with its paired activation and put both in
    /// `set` — the full "make this live for everyone in the set" gesture.
    /// Order matters: both declarations exist before the set additions
    /// fire the device notifications.
    func deploy(configJSON: Data, configID: String, toSet set: String) async throws {
        let actID = DDMDeclarations.activationID(for: configID)
        try await putDeclaration(configJSON)
        try await putDeclaration(DDMDeclarations.activation(identifier: actID,
                                                            configurationIDs: [configID]))
        try await addDeclaration(configID, toSet: set)
        try await addDeclaration(actID, toSet: set)
    }

    /// The inverse of deploy(): pull the configuration and its paired
    /// activation out of every set they're in (devices get notified and
    /// drop them), then delete both declarations. Activation goes first
    /// so no device ever sees an activation referencing a deleted config.
    func retire(configID: String) async throws {
        let actID = DDMDeclarations.activationID(for: configID)
        for id in [actID, configID] {
            let sets = (try? await setsForDeclaration(id: id)) ?? []
            for set in sets {
                try await removeDeclaration(id, fromSet: set)
            }
            do {
                try await deleteDeclaration(id: id)
            } catch MDMError.http(404, _) {
                // already gone — retire is idempotent
            }
        }
    }
}
