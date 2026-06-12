import Foundation

/// Generates the enrollment `.mobileconfig` from Edict's own settings —
/// the same profile that used to be hand-built by a script on the
/// server. Optionally CMS-signs it with a Developer ID identity from the
/// login keychain so it installs as "Verified" instead of "Unsigned".
enum EnrollmentProfileExporter {

    enum ExportError: LocalizedError {
        case missing(String)
        case signing(String)
        var errorDescription: String? {
            switch self {
            case .missing(let what): return "Can't build the profile: \(what)."
            case .signing(let msg):  return "Signing failed: \(msg)"
            }
        }
    }

    struct Inputs {
        let publicURL: String       // https://mdm.example.com
        let challenge: String
        let topic: String           // com.apple.mgmt.External.<uuid>
        let profileIdentifier: String
    }

    /// Build the unsigned profile XML. UUIDs are derived deterministically
    /// per-export so the SCEP payload and the MDM payload's
    /// IdentityCertificateUUID always match.
    static func makeProfile(_ i: Inputs) throws -> Data {
        let base = i.publicURL.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        guard !base.isEmpty else { throw ExportError.missing("public MDM URL is empty") }
        guard !i.challenge.isEmpty else { throw ExportError.missing("SCEP challenge is empty") }
        guard !i.topic.isEmpty else { throw ExportError.missing("push topic unavailable (is the server reachable?)") }
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base

        let scepUUID = UUID().uuidString
        let mdmUUID = UUID().uuidString
        let topUUID = UUID().uuidString

        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>PayloadContent</key>
        \t<array>
        \t\t<dict>
        \t\t\t<key>PayloadContent</key>
        \t\t\t<dict>
        \t\t\t\t<key>Key Type</key>
        \t\t\t\t<string>RSA</string>
        \t\t\t\t<key>Challenge</key>
        \t\t\t\t<string>\(esc(i.challenge))</string>
        \t\t\t\t<key>Key Usage</key>
        \t\t\t\t<integer>5</integer>
        \t\t\t\t<key>Keysize</key>
        \t\t\t\t<integer>2048</integer>
        \t\t\t\t<key>URL</key>
        \t\t\t\t<string>\(esc(root))/scep</string>
        \t\t\t</dict>
        \t\t\t<key>PayloadDisplayName</key>
        \t\t\t<string>Edict MDM SCEP</string>
        \t\t\t<key>PayloadIdentifier</key>
        \t\t\t<string>\(esc(i.profileIdentifier)).scep</string>
        \t\t\t<key>PayloadType</key>
        \t\t\t<string>com.apple.security.scep</string>
        \t\t\t<key>PayloadUUID</key>
        \t\t\t<string>\(scepUUID)</string>
        \t\t\t<key>PayloadVersion</key>
        \t\t\t<integer>1</integer>
        \t\t</dict>
        \t\t<dict>
        \t\t\t<key>AccessRights</key>
        \t\t\t<integer>8191</integer>
        \t\t\t<key>CheckOutWhenRemoved</key>
        \t\t\t<true/>
        \t\t\t<key>IdentityCertificateUUID</key>
        \t\t\t<string>\(scepUUID)</string>
        \t\t\t<key>PayloadDisplayName</key>
        \t\t\t<string>Edict MDM</string>
        \t\t\t<key>PayloadIdentifier</key>
        \t\t\t<string>\(esc(i.profileIdentifier)).mdm</string>
        \t\t\t<key>PayloadType</key>
        \t\t\t<string>com.apple.mdm</string>
        \t\t\t<key>PayloadUUID</key>
        \t\t\t<string>\(mdmUUID)</string>
        \t\t\t<key>PayloadVersion</key>
        \t\t\t<integer>1</integer>
        \t\t\t<key>ServerCapabilities</key>
        \t\t\t<array>
        \t\t\t\t<string>com.apple.mdm.per-user-connections</string>
        \t\t\t\t<string>com.apple.mdm.bootstraptoken</string>
        \t\t\t\t<string>com.apple.mdm.token</string>
        \t\t\t</array>
        \t\t\t<key>ServerURL</key>
        \t\t\t<string>\(esc(root))/mdm</string>
        \t\t\t<key>SignMessage</key>
        \t\t\t<true/>
        \t\t\t<key>Topic</key>
        \t\t\t<string>\(esc(i.topic))</string>
        \t\t</dict>
        \t</array>
        \t<key>PayloadDisplayName</key>
        \t<string>Edict MDM Enrollment</string>
        \t<key>PayloadIdentifier</key>
        \t<string>\(esc(i.profileIdentifier))</string>
        \t<key>PayloadType</key>
        \t<string>Configuration</string>
        \t<key>PayloadUUID</key>
        \t<string>\(topUUID)</string>
        \t<key>PayloadVersion</key>
        \t<integer>1</integer>
        </dict>
        </plist>
        """
        return Data(xml.utf8)
    }

    /// First "Developer ID Application" identity in the login keychain,
    /// if any — used to sign the profile so it installs as Verified.
    static func developerIDIdentity() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-identity", "-v", "-p", "codesigning"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Lines look like:  1) ABC123 "Developer ID Application: Name (TEAMID)"
        for line in out.split(separator: "\n") {
            if line.contains("Developer ID Application"),
               let open = line.firstIndex(of: "\""),
               let close = line.lastIndex(of: "\""), open < close {
                return String(line[line.index(after: open)..<close])
            }
        }
        return nil
    }

    /// CMS-sign `profile` with `identity` via `/usr/bin/security cms -S`.
    /// Returns the signed `.mobileconfig` bytes.
    static func sign(_ profile: Data, identity: String) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
        let inURL = tmp.appendingPathComponent("edict-\(UUID().uuidString).mobileconfig")
        let outURL = tmp.appendingPathComponent("edict-\(UUID().uuidString)-signed.mobileconfig")
        defer { try? FileManager.default.removeItem(at: inURL)
                try? FileManager.default.removeItem(at: outURL) }
        try profile.write(to: inURL)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["cms", "-S", "-N", identity, "-i", inURL.path, "-o", outURL.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "exit \(p.terminationStatus)"
            throw ExportError.signing(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try Data(contentsOf: outURL)
    }
}
