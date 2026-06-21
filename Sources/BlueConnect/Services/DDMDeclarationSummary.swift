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
