import Foundation

/// Apple platforms a profile template targets — drives the catalog's
/// platform-filter toggles.
enum ProfilePlatform: String, CaseIterable, Identifiable {
    case macOS = "macOS", iOS = "iOS", tvOS = "tvOS"
    var id: String { rawValue }
}
