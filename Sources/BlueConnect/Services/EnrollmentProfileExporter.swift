import CryptoKit
import Foundation
import Security

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
        var displayName: String = "Edict MDM Enrollment"
        var organization: String = ""
        var profileDescription: String = ""
        /// Consent text shown to the user at install time (optional).
        var consentText: String = ""
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
        // Must be a real HTTPS URL — an http:// or malformed URL would ship
        // the SCEP challenge in the clear or simply fail to enroll on the Mac.
        guard let comps = URLComponents(string: base),
              comps.scheme?.lowercased() == "https",
              let h = comps.host, !h.isEmpty,
              comps.query == nil, comps.fragment == nil else {
            throw ExportError.missing("public MDM URL must be a plain https:// URL (no query/fragment). Got: \(base)")
        }
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base

        let scepUUID = UUID().uuidString
        let mdmUUID = UUID().uuidString
        let topUUID = UUID().uuidString

        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }

        // Optional top-level personalization keys.
        var extras = ""
        if !i.organization.isEmpty {
            extras += "\n\t<key>PayloadOrganization</key>\n\t<string>\(esc(i.organization))</string>"
        }
        if !i.profileDescription.isEmpty {
            extras += "\n\t<key>PayloadDescription</key>\n\t<string>\(esc(i.profileDescription))</string>"
        }
        if !i.consentText.isEmpty {
            extras += "\n\t<key>ConsentText</key>\n\t<dict>\n\t\t<key>default</key>\n\t\t<string>\(esc(i.consentText))</string>\n\t</dict>"
        }
        let displayName = i.displayName.isEmpty ? "Edict MDM Enrollment" : i.displayName

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
        \t<string>\(esc(displayName))</string>
        \t<key>PayloadIdentifier</key>
        \t<string>\(esc(i.profileIdentifier))</string>
        \t<key>PayloadType</key>
        \t<string>Configuration</string>
        \t<key>PayloadUUID</key>
        \t<string>\(topUUID)</string>
        \t<key>PayloadVersion</key>
        \t<integer>1</integer>\(extras)
        </dict>
        </plist>
        """
        return Data(xml.utf8)
    }

    /// A keychain signing identity, pinned by its certificate's SHA-1 so a
    /// duplicate/expired cert with the same name can't be picked instead.
    /// Interpolates as its display name.
    struct SigningIdentity: CustomStringConvertible, Sendable {
        let sha1: String   // uppercase hex, as `security find-identity` prints it
        let name: String
        var description: String { name }
    }

    /// First "Developer ID Application" identity in the login keychain,
    /// if any — used to sign the profile so it installs as Verified.
    ///
    /// Runs off the main actor: `security find-identity` spawns a
    /// subprocess and `waitUntilExit()` would otherwise stall the UI (this
    /// is called from the Enrollment view's `.task`, i.e. on every appear).
    static func developerIDIdentity() async -> SigningIdentity? {
        await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["find-identity", "-v", "-p", "codesigning"]
            guard let (outData, _) = try? p.runCapturing() else { return nil }
            let out = String(data: outData, encoding: .utf8) ?? ""
            // Lines look like:  1) ABC123 "Developer ID Application: Name (TEAMID)"
            for line in out.split(separator: "\n") {
                if line.contains("Developer ID Application"),
                   let open = line.firstIndex(of: "\""),
                   let close = line.lastIndex(of: "\""), open < close,
                   let hash = line[..<open].split(separator: " ").last, hash.count == 40 {
                    return SigningIdentity(sha1: String(hash).uppercased(),
                                           name: String(line[line.index(after: open)..<close]))
                }
            }
            return nil
        }.value
    }

    /// CMS-sign `profile` with the keychain identity whose certificate
    /// SHA-1 matches `identity.sha1`. Signs in-process (CMSEncodeContent)
    /// rather than `security cms -N <name>`, which fails as "ambiguous"
    /// when two certs share a name and can silently pick the wrong one.
    /// Returns the signed `.mobileconfig` bytes. Runs off the main actor.
    static func sign(_ profile: Data, identity: SigningIdentity) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let query: [String: Any] = [kSecClass as String: kSecClassIdentity,
                                        kSecReturnRef as String: true,
                                        kSecMatchLimit as String: kSecMatchLimitAll]
            var items: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
                  let all = items as? [SecIdentity] else {
                throw ExportError.signing("no signing identities in the keychain")
            }
            let match = all.first { id in
                var cert: SecCertificate?
                guard SecIdentityCopyCertificate(id, &cert) == errSecSuccess, let cert else { return false }
                let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(cert) as Data)
                return digest.map { String(format: "%02X", $0) }.joined() == identity.sha1
            }
            guard let match else {
                throw ExportError.signing("“\(identity.name)” (\(identity.sha1.prefix(8))…) not found in the keychain")
            }
            var out: CFData?
            let status = profile.withUnsafeBytes { buf in
                CMSEncodeContent(match, nil, nil, false, [], buf.baseAddress!, buf.count, &out)
            }
            guard status == errSecSuccess, let out else {
                let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                throw ExportError.signing(msg)
            }
            return out as Data
        }.value
    }
}
