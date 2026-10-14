import Foundation

/// Unwraps CMS-signed .mobileconfig data. Synchronous subprocess — call from
/// a detached task, never the main actor.
enum CMSProfile {
    /// The inner plist bytes: plain profiles pass through unchanged; signed
    /// ones (DER, leading 0x30) are stripped via `security cms -D`. nil if
    /// decoding a signed profile fails.
    static func plistData(_ data: Data) -> Data? {
        guard data.first == 0x30 else { return data }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("edict-\(UUID().uuidString).mobileconfig")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? data.write(to: tmp)) != nil else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["cms", "-D", "-i", tmp.path]
        guard let d = try? p.runCapturing().out, !d.isEmpty else { return nil }
        return d
    }
}
