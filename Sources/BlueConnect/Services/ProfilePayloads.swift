import Foundation

/// Builders for the configuration profiles (.mobileconfig) Edict deploys
/// via the MDM InstallProfile command — so common policy is a form, not
/// hand-edited XML. Each returns the profile as serialized plist bytes.
enum ProfilePayloads {

    enum WiFiSecurity: String, CaseIterable, Identifiable {
        case wpa2 = "WPA2", wpa3 = "WPA3", none = "None"
        var id: String { rawValue }
        /// EncryptionType value Apple's Wi-Fi payload expects.
        var encryptionType: String { self == .none ? "None" : "WPA2" }
        var needsPassword: Bool { self != .none }
    }

    /// `com.apple.wifi.managed` — auto-join Wi-Fi network.
    static func wifi(ssid: String, password: String,
                     hidden: Bool, security: WiFiSecurity) -> Data {
        var payload: [String: Any] = base("com.apple.wifi.managed",
                                           displayName: "Wi-Fi (\(ssid))")
        payload["SSID_STR"] = ssid
        payload["HIDDEN_NETWORK"] = hidden
        payload["AutoJoin"] = true
        payload["EncryptionType"] = security.encryptionType
        if security.needsPassword, !password.isEmpty {
            payload["Password"] = password
        }
        return profile(displayName: "Wi-Fi: \(ssid)",
                       identifier: "xyz.hellocomputer.edict.wifi",
                       payloads: [payload])
    }

    /// `com.apple.mobiledevice.passwordpolicy` — login password policy.
    static func passcode(minLength: Int, requireAlphanumeric: Bool,
                         maxInactivityMinutes: Int?) -> Data {
        var payload: [String: Any] = base("com.apple.mobiledevice.passwordpolicy",
                                           displayName: "Password Policy")
        payload["minLength"] = minLength
        payload["requireAlphanumeric"] = requireAlphanumeric
        payload["allowSimple"] = !requireAlphanumeric
        if let m = maxInactivityMinutes, m > 0 {
            payload["maxInactivity"] = m
        }
        return profile(displayName: "Password Policy",
                       identifier: "xyz.hellocomputer.edict.passcode",
                       payloads: [payload])
    }

    /// Validate + normalize a pasted profile. Accepts a full mobileconfig
    /// (returns it as-is) — used for the "Custom" template. Throws if it
    /// isn't a configuration-profile plist.
    static func custom(xml: String) throws -> Data {
        guard let data = xml.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw Invalid.notPlist }
        guard (obj["PayloadType"] as? String) == "Configuration",
              obj["PayloadContent"] != nil
        else { throw Invalid.notProfile }
        return data
    }

    enum Invalid: LocalizedError {
        case notPlist, notProfile
        var errorDescription: String? {
            switch self {
            case .notPlist:   return "That isn't valid plist XML."
            case .notProfile: return "Not a configuration profile (needs PayloadType=Configuration and PayloadContent)."
            }
        }
    }

    /// The PayloadIdentifier a built profile will carry — for RemoveProfile.
    static func identifier(forBuiltIn kind: String) -> String {
        "xyz.hellocomputer.edict.\(kind)"
    }

    // MARK: - Builders

    private static func base(_ type: String, displayName: String) -> [String: Any] {
        [
            "PayloadType": type,
            "PayloadVersion": 1,
            "PayloadIdentifier": "xyz.hellocomputer.edict.\(type).\(UUID().uuidString)",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": displayName,
        ]
    }

    private static func profile(displayName: String, identifier: String,
                                payloads: [[String: Any]]) -> Data {
        let dict: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier,
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": displayName,
            "PayloadScope": "System",
            "PayloadContent": payloads,
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: dict,
                                                    format: .xml, options: 0)) ?? Data()
    }
}
