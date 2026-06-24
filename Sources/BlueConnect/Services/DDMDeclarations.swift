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

    /// The conservative, macOS-supported status items the device-detail
    /// pane and dashboard rely on — the default when the operator doesn't
    /// pick a custom set.
    static let defaultStatusItems = [
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

    /// `com.apple.configuration.management.status-subscriptions` — asks
    /// devices to continuously report the listed status items. This is
    /// what feeds the device-detail pane: OS version/build, model,
    /// serial, and FileVault state, kept current by the device itself.
    static func statusSubscriptions(identifier: String,
                                    itemNames: [String] = defaultStatusItems) -> Data {
        declaration(type: "com.apple.configuration.management.status-subscriptions",
                    identifier: identifier,
                    payload: ["StatusItems": itemNames.map { ["Name": $0] }])
    }

    /// `com.apple.configuration.diskmanagement.settings` (macOS 15+,
    /// supervised) — restrict external (USB/SD/Thunderbolt) and network
    /// storage. Each value is `Allowed`, `ReadOnly`, or `Disallowed`;
    /// `ReadOnly` refuses to mount read-write volumes rather than
    /// converting them. Schema: apple/device-management.
    static func diskManagement(identifier: String,
                               externalStorage: String,
                               networkStorage: String) -> Data {
        declaration(type: "com.apple.configuration.diskmanagement.settings",
                    identifier: identifier,
                    payload: ["Restrictions": [
                        "ExternalStorage": externalStorage,
                        "NetworkStorage": networkStorage,
                    ]])
    }

    /// `com.apple.configuration.softwareupdate.settings` (macOS 15+) —
    /// automatic-update behavior, deferral windows, and notifications.
    /// Only the keys Apple marks macOS-available are emitted; a deferral of
    /// 0 omits that key (no deferral). The `AutomaticActions` values are
    /// `Allowed` (user decides), `AlwaysOn`, or `AlwaysOff`.
    static func softwareUpdateSettings(identifier: String,
                                       download: String,
                                       installOS: String,
                                       installSecurity: String,
                                       deferMajorDays: Int,
                                       deferMinorDays: Int,
                                       deferSystemDays: Int,
                                       notifications: Bool) -> Data {
        var payload: [String: Any] = [
            "AutomaticActions": [
                "Download": download,
                "InstallOSUpdates": installOS,
                "InstallSecurityUpdate": installSecurity,
            ],
            "Notifications": notifications,
        ]
        var deferrals: [String: Any] = [:]
        if deferMajorDays > 0 { deferrals["MajorPeriodInDays"] = deferMajorDays }
        if deferMinorDays > 0 { deferrals["MinorPeriodInDays"] = deferMinorDays }
        if deferSystemDays > 0 { deferrals["SystemPeriodInDays"] = deferSystemDays }
        if !deferrals.isEmpty { payload["Deferrals"] = deferrals }
        return declaration(type: "com.apple.configuration.softwareupdate.settings",
                           identifier: identifier,
                           payload: payload)
    }

    /// `com.apple.configuration.passcode.settings` (macOS 13+) — login
    /// password rules. Every key is macOS-supported per
    /// apple/device-management; only meaningful values are emitted (0 / false
    /// means "don't set"), and `MaximumFailedAttempts` is only emitted in its
    /// valid 2–11 range. An empty policy emits an empty payload.
    static func passcodeSettings(identifier: String,
                                 requirePasscode: Bool,
                                 minimumLength: Int,
                                 requireAlphanumeric: Bool,
                                 requireComplex: Bool,
                                 minimumComplexChars: Int,
                                 maxInactivityMinutes: Int,
                                 maxFailedAttempts: Int,
                                 maxAgeInDays: Int,
                                 reuseLimit: Int,
                                 changeAtNextAuth: Bool) -> Data {
        var p: [String: Any] = [:]
        if requirePasscode { p["RequirePasscode"] = true }
        if minimumLength > 0 { p["MinimumLength"] = minimumLength }
        if requireAlphanumeric { p["RequireAlphanumericPasscode"] = true }
        if requireComplex { p["RequireComplexPasscode"] = true }
        if minimumComplexChars > 0 { p["MinimumComplexCharacters"] = minimumComplexChars }
        if maxInactivityMinutes > 0 { p["MaximumInactivityInMinutes"] = maxInactivityMinutes }
        if maxFailedAttempts >= 2 { p["MaximumFailedAttempts"] = maxFailedAttempts }
        if maxAgeInDays > 0 { p["MaximumPasscodeAgeInDays"] = maxAgeInDays }
        if reuseLimit >= 1 { p["PasscodeReuseLimit"] = reuseLimit }
        if changeAtNextAuth { p["ChangeAtNextAuth"] = true }
        return declaration(type: "com.apple.configuration.passcode.settings",
                           identifier: identifier, payload: p)
    }

    /// `com.apple.configuration.screensharing.host.settings` (macOS 14+,
    /// supervised/local) — controls macOS Screen Sharing on the host: file
    /// copy in/out, virtual-display count, and high-performance connections.
    /// On-brand for a remote-support fleet. Only set values are emitted;
    /// `MaximumVirtualDisplays` is 0–2, `PortBase` 1024–65535. Schema:
    /// apple/device-management.
    static func screenSharing(identifier: String,
                              maxVirtualDisplays: Int?,
                              portBase: Int,
                              preventCopyFromHost: Bool,
                              preventCopyToHost: Bool,
                              preventHighPerformance: Bool) -> Data {
        var p: [String: Any] = [:]
        if let m = maxVirtualDisplays, (0...2).contains(m) { p["MaximumVirtualDisplays"] = m }
        if (1024...65535).contains(portBase) { p["PortBase"] = portBase }
        if preventCopyFromHost { p["PreventCopyFilesFromHost"] = true }
        if preventCopyToHost { p["PreventCopyFilesToHost"] = true }
        if preventHighPerformance { p["PreventHighPerformanceConnections"] = true }
        return declaration(type: "com.apple.configuration.screensharing.host.settings",
                           identifier: identifier, payload: p)
    }

    /// `com.apple.asset.credential.certificate` (macOS 14+) — the asset that
    /// holds a certificate the device DOWNLOADS from `dataURL` (an https URL;
    /// `application/pem` or `application/pkcs1`). The cert is NOT embedded —
    /// you host the file and reference its URL. Paired with a
    /// `security.certificate` configuration that points at this asset.
    static func certificateAsset(identifier: String, dataURL: String,
                                 contentType: String?, sha256: String?, mdmAuth: Bool) -> Data {
        var reference: [String: Any] = ["DataURL": dataURL]
        if let ct = contentType, !ct.isEmpty { reference["ContentType"] = ct }
        if let h = sha256, !h.isEmpty { reference["Hash-SHA-256"] = h }
        var payload: [String: Any] = ["Reference": reference]
        if mdmAuth { payload["Authentication"] = ["Type": "MDM"] }
        return declaration(type: "com.apple.asset.credential.certificate",
                           identifier: identifier, payload: payload)
    }

    /// `com.apple.configuration.security.certificate` (macOS 14+) — installs
    /// the certificate held by the referenced credential asset.
    static func certificateConfig(identifier: String, assetReference: String) -> Data {
        declaration(type: "com.apple.configuration.security.certificate",
                    identifier: identifier,
                    payload: ["CredentialAssetReference": assetReference])
    }

    /// `com.apple.activation.simple` referencing one or more configurations,
    /// with an optional NSPredicate-format `Predicate` that gates activation:
    /// the configuration installs only on devices where the predicate is true
    /// (or absent). Predicates reference the device's reported status items.
    static func activation(identifier: String, configurationIDs: [String],
                           predicate: String? = nil) -> Data {
        var payload: [String: Any] = ["StandardConfigurations": configurationIDs]
        if let p = predicate?.trimmingCharacters(in: .whitespaces), !p.isEmpty {
            payload["Predicate"] = p
        }
        return declaration(type: "com.apple.activation.simple",
                           identifier: identifier, payload: payload)
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
