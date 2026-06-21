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
            return .init(title: "Activation",
                         blurb: "Plumbing — turns the referenced configuration(s) on. You rarely edit this directly.",
                         rows: configs.isEmpty ? [] : [r("Turns on", configs.joined(separator: ", "))])

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
        "diskmanagement.filevault.enabled":     "FileVault enabled",
    ]
}
