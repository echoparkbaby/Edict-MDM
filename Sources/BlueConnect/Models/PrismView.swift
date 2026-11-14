import Foundation

/// A saved fleet-analytics view — the Prism layer. Captures "show me the
/// fleet (or a smart group), broken down by <attribute>". Persisted in
/// settings so an operator can flip between named views like
/// "Sonoma Macs" or "FileVault status, finance group".
struct PrismView: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Smart-group scope; nil = every enrolled device.
    var groupID: UUID?
    var attribute: Attribute
    var search: String? = nil
    var hiddenColumns: String? = nil
    var sortKey: String? = nil
    var sortAscending: Bool? = nil

    /// What to break the fleet down by.
    enum Attribute: String, Codable, CaseIterable, Identifiable {
        case osVersion = "macOS version"
        case model = "Model"
        case fileVault = "FileVault"
        case compliance = "Compliance"
        case enrollment = "Enrollment"
        case blueSky = "BlueSky link"
        case profileCount = "Profiles deployed"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .osVersion: return "apple.logo"
            case .model: return "laptopcomputer"
            case .fileVault: return "lock.shield"
            case .compliance: return "checkmark.seal"
            case .enrollment: return "shield.lefthalf.filled"
            case .blueSky: return "link"
            case .profileCount: return "doc.on.doc"
            }
        }
    }
}
