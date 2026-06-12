import Foundation

/// A managed Mac that Edict knows about. The enrollment ID is what
/// NanoMDM keys everything on — for a macOS device enrollment it's the
/// hardware UUID (System Information → Hardware UUID), and it shows up
/// in NanoMDM's logs as `id=` on every checkin. NanoMDM has no
/// list-enrollments API, so these are registered manually and persisted
/// locally in @AppStorage.
struct MDMDevice: Codable, Identifiable, Hashable {
    /// The NanoMDM enrollment ID (device UDID / hardware UUID).
    var id: String
    /// Operator-friendly name, e.g. "juniper".
    var label: String
}
