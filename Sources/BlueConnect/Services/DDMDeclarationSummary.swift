import Foundation

/// A plain-English read of a DDM declaration for the library — so an
/// operator sees "Status reporting · reports macOS version, FileVault" or
/// "Activation · turns on X", not a wall of reverse-DNS JSON. Pure +
/// testable; unknown types fall back to the kind + raw type.
struct DDMDeclarationSummary {
    var title: String
    var blurb: String
    var rows: [Row]

    struct Row: Identifiable, Hashable {
        var id: String { label + value }
        let label: String
        let value: String
    }

    static func make(type: String, payload: [String: Any]) -> DDMDeclarationSummary {
        func r(_ l: String, _ v: String) -> Row { Row(label: l, value: v) }
        switch type {
        case "com.apple.configuration.management.status-subscriptions":
            let items = (payload["StatusItems"] as? [[String: Any]])?.compactMap { $0["Name"] as? String } ?? []
            let names = items.map(statusItemLabel).joined(separator: ", ")
            return .init(title: "Status reporting",
                         blurb: "Asks each Mac to keep reporting these facts to the MDM.",
                         rows: names.isEmpty ? [] : [r("Reports", names)])

        case "com.apple.configuration.softwareupdate.enforcement.specific":
            var rows: [Row] = []
            if let v = payload["TargetOSVersion"] as? String { rows.append(r("Target version", v)) }
            if let d = payload["TargetLocalDateTime"] as? String { rows.append(r("Install by", d)) }
            if let u = payload["DetailsURL"] as? String, !u.isEmpty { rows.append(r("Details link", u)) }
            return .init(title: "Enforce macOS update",
                         blurb: "Requires a macOS version by a deadline; the Mac installs it on its own.",
                         rows: rows)

        case "com.apple.activation.simple":
            let configs = (payload["StandardConfigurations"] as? [String]) ?? []
            var rows: [Row] = configs.isEmpty ? [] : [r("Turns on", configs.joined(separator: ", "))]
            if let pred = payload["Predicate"] as? String, !pred.isEmpty { rows.append(r("Only when", pred)) }
            return .init(title: "Activation",
                         blurb: "Plumbing — turns the referenced configuration(s) on, optionally only on devices matching a condition.",
                         rows: rows)

        case "com.apple.configuration.diskmanagement.settings":
            var rows: [Row] = []
            if let rest = payload["Restrictions"] as? [String: Any] {
                if let e = rest["ExternalStorage"] as? String { rows.append(r("External drives", storageLabel(e))) }
                if let n = rest["NetworkStorage"] as? String { rows.append(r("Network shares", storageLabel(n))) }
            }
            return .init(title: "Drive restrictions",
                         blurb: "Controls whether Macs can use USB drives and network shares (macOS 15+).",
                         rows: rows)

        case "com.apple.configuration.softwareupdate.settings":
            var rows: [Row] = []
            if let a = payload["AutomaticActions"] as? [String: Any] {
                if let d = a["Download"] as? String { rows.append(r("Download updates", actionLabel(d))) }
                if let o = a["InstallOSUpdates"] as? String { rows.append(r("Install macOS updates", actionLabel(o))) }
                if let s = a["InstallSecurityUpdate"] as? String { rows.append(r("Install security updates", actionLabel(s))) }
            }
            if let d = payload["Deferrals"] as? [String: Any] {
                let parts = [("Major", "MajorPeriodInDays"), ("Minor", "MinorPeriodInDays"), ("Other", "SystemPeriodInDays")]
                    .compactMap { label, key in (d[key] as? Int).map { "\(label) \($0)d" } }
                if !parts.isEmpty { rows.append(r("Defer", parts.joined(separator: ", "))) }
            }
            if let n = payload["Notifications"] as? Bool { rows.append(r("Notifications", n ? "On" : "Off")) }
            return .init(title: "Update settings",
                         blurb: "How Macs download, install, and defer software updates (macOS 15+).",
                         rows: rows)

        case "com.apple.configuration.screensharing.host.settings":
            var rows: [Row] = []
            if let m = payload["MaximumVirtualDisplays"] as? Int { rows.append(r("Virtual displays", "\(m)")) }
            if let p = payload["PortBase"] as? Int { rows.append(r("Port base", "\(p)")) }
            if payload["PreventCopyFilesFromHost"] as? Bool == true { rows.append(r("Copy from this Mac", "Blocked")) }
            if payload["PreventCopyFilesToHost"] as? Bool == true { rows.append(r("Copy to this Mac", "Blocked")) }
            if payload["PreventHighPerformanceConnections"] as? Bool == true { rows.append(r("High-performance", "Blocked")) }
            return .init(title: "Screen sharing",
                         blurb: "Controls macOS Screen Sharing on the host — file copy, displays, performance (macOS 14+).",
                         rows: rows)

        case "com.apple.configuration.passcode.settings":
            var rows: [Row] = []
            if payload["RequirePasscode"] as? Bool == true { rows.append(r("Login password", "Required")) }
            if let n = payload["MinimumLength"] as? Int { rows.append(r("Minimum length", "\(n)")) }
            if payload["RequireAlphanumericPasscode"] as? Bool == true { rows.append(r("Letters & numbers", "Required")) }
            if payload["RequireComplexPasscode"] as? Bool == true { rows.append(r("Complex password", "Required")) }
            if let n = payload["MinimumComplexCharacters"] as? Int { rows.append(r("Special characters", "\(n)")) }
            if let n = payload["MaximumInactivityInMinutes"] as? Int { rows.append(r("Auto-lock", "\(n) min")) }
            if let n = payload["MaximumFailedAttempts"] as? Int { rows.append(r("Lock after", "\(n) tries")) }
            if let n = payload["MaximumPasscodeAgeInDays"] as? Int { rows.append(r("Expires every", "\(n) days")) }
            if let n = payload["PasscodeReuseLimit"] as? Int { rows.append(r("No reuse of last", "\(n)")) }
            if payload["ChangeAtNextAuth"] as? Bool == true { rows.append(r("Change at next login", "Yes")) }
            return .init(title: "Passcode policy",
                         blurb: "Login-password rules each Mac enforces (macOS 13+).",
                         rows: rows)

        case "com.apple.configuration.security.certificate":
            return .init(title: "Certificate",
                         blurb: "Installs a certificate the Mac downloads from a credential asset (macOS 14+).",
                         rows: [r("From asset", (payload["CredentialAssetReference"] as? String) ?? "—")])

        case "com.apple.asset.credential.certificate":
            let ref = payload["Reference"] as? [String: Any]
            var rows: [Row] = []
            if let url = ref?["DataURL"] as? String { rows.append(r("Download URL", url)) }
            if let ct = ref?["ContentType"] as? String { rows.append(r("Format", ct)) }
            if (payload["Authentication"] as? [String: Any])?["Type"] as? String == "MDM" {
                rows.append(r("Auth", "MDM identity"))
            }
            return .init(title: "Certificate file",
                         blurb: "The certificate the device downloads (PEM/PKCS1, hosted over HTTPS). Referenced by a certificate configuration.",
                         rows: rows)

        case "com.apple.configuration.legacy":
            return .init(title: "Legacy profile",
                         blurb: "Installs a configuration profile the Mac downloads from a URL.",
                         rows: [r("Profile URL", (payload["ProfileURL"] as? String) ?? "—")])

        default:
            return .init(title: kindTitle(type), blurb: type, rows: [])
        }
    }

    private static func kindTitle(_ type: String) -> String {
        DDMLibraryItem.kind(forType: type).capitalized
    }

    /// Disk-management access enum → plain English.
    static func storageLabel(_ value: String) -> String {
        switch value {
        case "Allowed":    return "Allow read & write"
        case "ReadOnly":   return "Read-only"
        case "Disallowed": return "Blocked"
        default:           return value
        }
    }

    /// Software-update AutomaticActions enum → plain English.
    static func actionLabel(_ value: String) -> String {
        switch value {
        case "Allowed":   return "User decides"
        case "AlwaysOn":  return "Always on"
        case "AlwaysOff": return "Always off"
        default:          return value
        }
    }

    /// Friendly label for a DDM status-item name; prettifies the reverse-DNS
    /// path for anything not in the known set.
    static func statusItemLabel(_ name: String) -> String {
        if let known = labels[name] { return known }
        let words = name.replacingOccurrences(of: "-", with: " ").split(separator: ".").joined(separator: " ")
        guard let first = words.first else { return name }
        return first.uppercased() + words.dropFirst()
    }

    private static let labels: [String: String] = [
        "device.identifier.serial-number":      "Serial number",
        "device.identifier.udid":               "UDID",
        "device.model.family":                  "Model family",
        "device.model.identifier":              "Model identifier",
        "device.model.marketing-name":          "Model name",
        "device.operating-system.family":       "OS family",
        "device.operating-system.version":      "macOS version",
        "device.operating-system.build-version":"macOS build",
        "device.operating-system.marketing-name":"macOS name",
        "device.operating-system.supplemental.build-version":"macOS RSR build",
        "device.model.number":                  "Model number",
        "device.power.battery-health":          "Battery health",
        "diskmanagement.filevault.enabled":     "FileVault enabled",
        "passcode.is-present":                  "Has a passcode",
        "passcode.is-compliant":                "Passcode compliant",
        "softwareupdate.pending-version":       "Pending OS version",
        "softwareupdate.install-state":         "Update state",
        "softwareupdate.failure-reason":        "Update failure",
    ]
}
