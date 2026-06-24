import SwiftUI

/// Form for deploying a certificate to Macs declaratively — the first user of
/// the DDM asset model. Apple's DDM does NOT embed the cert; it downloads it
/// from an HTTPS URL you host. This builds the credential ASSET (the URL) + a
/// security.certificate CONFIGURATION that references it (+ its activation),
/// all into a set. Requires macOS 14+.
struct CertificateSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// (asset, config, configID, set) — the pane adds the asset, then the
    /// config + its paired activation.
    let onAdd: (_ asset: Data, _ config: Data, _ configID: String, _ set: String) -> Void

    enum CertFormat: String, CaseIterable, Identifiable {
        case pem = "application/pem"
        case pkcs1 = "application/pkcs1"
        var id: String { rawValue }
        var label: String { self == .pem ? "PEM (.pem)" : "DER / PKCS1 (.cer)" }
    }

    @State private var name = "Corporate Root CA"
    @State private var dataURL = ""
    @State private var format: CertFormat = .pem
    @State private var mdmAuth = false
    @State private var setName = "default"

    private var slug: String {
        var out = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "cert" : out
    }
    private var configID: String { "com.hellocomputer.edict.cert.\(slug)" }
    private var assetID: String { configID + ".asset" }
    private var urlValid: Bool {
        let u = dataURL.trimmingCharacters(in: .whitespaces).lowercased()
        return u.hasPrefix("https://") && u.count > "https://".count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install a Certificate").font(.headline)
            Text("Deploy a certificate to Macs via DDM. Apple downloads the cert from a URL you host — it isn't embedded in the declaration. Host your .pem (or DER) where devices can reach it over HTTPS, then paste that URL below. Requires macOS 14 or newer.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Name", text: $name)
                TextField("Certificate URL", text: $dataURL,
                          prompt: Text(verbatim: "https://certs.example.com/root-ca.pem"))
                    .help("Must be HTTPS. This is where the Mac downloads the certificate.")
                Picker("Format", selection: $format) {
                    ForEach(CertFormat.allCases) { Text($0.label).tag($0) }
                }
                Toggle("URL requires MDM authentication", isOn: $mdmAuth)
                    .help("On if the hosting URL needs the device's MDM identity to fetch; off for a public/anonymous URL.")
                TextField("Set", text: $setName)
                    .help("Which KMFDDM set receives the asset + config. Every Mac in the set installs the cert.")
            }
            .formStyle(.grouped)

            if urlValid {
                Text("Creates asset “\(assetID)” + certificate config “\(configID)” (+ activation) in set “\(setName)”.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to Library") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!urlValid || setName.trimmingCharacters(in: .whitespaces).isEmpty
                              || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func commit() {
        let asset = DDMDeclarations.certificateAsset(
            identifier: assetID,
            dataURL: dataURL.trimmingCharacters(in: .whitespaces),
            contentType: format.rawValue, sha256: nil, mdmAuth: mdmAuth)
        let config = DDMDeclarations.certificateConfig(identifier: configID, assetReference: assetID)
        onAdd(asset, config, configID, setName.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}
