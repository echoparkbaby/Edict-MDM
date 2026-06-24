import Foundation

/// One authored DDM declaration in the local library — the raw declaration
/// bytes (`Type` / `Identifier` / `Payload`) plus the KMFDDM set names it
/// belongs to. The library is the "build it in Edict" side; Sync pushes it
/// to KMFDDM and Export writes it to a ddm_examples / syncdir-style folder.
struct DDMLibraryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var json: Data
    var sets: [String] = []

    private var object: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
    }
    var identifier: String { (object?["Identifier"] as? String) ?? "—" }
    var type: String { (object?["Type"] as? String) ?? "—" }
    var payload: [String: Any] { (object?["Payload"] as? [String: Any]) ?? [:] }
    /// configuration / activation / asset / management / declaration.
    var kind: String { Self.kind(forType: type) }
    /// For activations: the configurations it turns on, and its gating predicate.
    var standardConfigurations: [String] { (payload["StandardConfigurations"] as? [String]) ?? [] }
    var predicate: String? { (payload["Predicate"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    /// Plain-English read of this declaration for the UI.
    var summary: DDMDeclarationSummary { DDMDeclarationSummary.make(type: type, payload: payload) }

    var prettyJSON: String {
        guard let obj = object,
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { return String(data: json, encoding: .utf8) ?? "" }
        return s
    }

    // MARK: - Pure helpers (testable)

    /// True only if the bytes parse as a declaration (non-empty Type + Identifier).
    static func isValidDeclaration(_ data: Data) -> Bool {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return (o["Type"] as? String)?.isEmpty == false && (o["Identifier"] as? String)?.isEmpty == false
    }

    /// The kind segment of an Apple declaration type, e.g.
    /// "com.apple.configuration.foo" → "configuration".
    static func kind(forType type: String) -> String {
        let parts = type.split(separator: ".")
        return parts.count >= 3 ? String(parts[2]) : "declaration"
    }

    /// ddm_examples / syncdir subfolder for a declaration of this type.
    static func subfolder(forType type: String) -> String {
        switch kind(forType: type) {
        case "configuration": return "configurations"
        case "activation":    return "activations"
        case "asset":         return "assets"
        case "management":    return "management"
        default:              return "declarations"
        }
    }

    /// Filesystem-safe filename for a declaration identifier.
    static func safeFilename(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "/", with: "_") + ".json"
    }

    /// Returns `items` with `configID` activated in `set`: ensures a
    /// `<configID>.activation` exists referencing the configuration and is a
    /// member of the set, so the configuration takes effect there. Pure (no
    /// persistence) so it's testable. Never narrows an existing activation's
    /// references — it only adds the config and the set membership.
    static func activating(configID: String, in set: String,
                           within items: [DDMLibraryItem]) -> [DDMLibraryItem] {
        var result = items
        let actID = DDMDeclarations.activationID(for: configID)
        if let idx = result.firstIndex(where: { $0.identifier == actID }) {
            var refs = (result[idx].payload["StandardConfigurations"] as? [String]) ?? []
            if !refs.contains(configID) {
                refs.append(configID)
                result[idx].json = DDMDeclarations.activation(identifier: actID, configurationIDs: refs)
            }
            if !result[idx].sets.contains(set) {
                result[idx].sets = (result[idx].sets + [set]).sorted()
            }
        } else {
            result.append(DDMLibraryItem(
                json: DDMDeclarations.activation(identifier: actID, configurationIDs: [configID]),
                sets: [set]))
        }
        return result
    }
}
