import SwiftUI

/// Form for the services.configuration-files declaration — manage a system
/// service's config files (sshd, sudo, pam, …) declaratively. Like the
/// certificate template, Apple downloads the files (a zip) from a URL you host;
/// they aren't embedded. Builds the data ASSET (the zip URL + required hash) +
/// the CONFIGURATION that references it (+ activation). macOS 14+, supervised.
struct ServiceConfigFilesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (_ asset: Data, _ config: Data, _ configID: String, _ set: String) -> Void

    struct Service: Identifiable { var id: String { type }; let type: String; let label: String }
    static let services: [Service] = [
        .init(type: "com.apple.sshd", label: "SSH — /etc/ssh"),
        .init(type: "com.apple.sudo", label: "sudo — /etc/sudoers"),
        .init(type: "com.apple.pam", label: "PAM — /etc/pam.d"),
        .init(type: "com.apple.cups", label: "CUPS printing — /etc/cups"),
        .init(type: "com.apple.apache.httpd", label: "Apache — /etc/apache2"),
        .init(type: "com.apple.bash", label: "bash — /etc/profile"),
        .init(type: "com.apple.zsh", label: "zsh — /etc/zsh*"),
        .init(type: "com.apple.cryptoTokenKit", label: "Smartcard login"),
        .init(type: "com.apple.authorization", label: "Authorization — /Library/Security"),
    ]

    @State private var serviceType = "com.apple.sshd"
    @State private var dataURL = ""
    @State private var sha256 = ""
    @State private var mdmAuth = false
    @State private var setName = "default"

    private var slug: String { serviceType.split(separator: ".").last.map(String.init) ?? "svc" }
    private var configID: String { "com.hellocomputer.edict.svccfg.\(slug)" }
    private var assetID: String { configID + ".asset" }
    private var urlValid: Bool {
        let u = dataURL.trimmingCharacters(in: .whitespaces).lowercased()
        return u.hasPrefix("https://") && u.count > "https://".count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manage Service Config Files").font(.headline)
            Text("Replace a system service's configuration files (e.g. sshd_config, sudoers) declaratively. Zip the files, host the zip at an HTTPS URL devices can reach, then point Edict at it — Apple downloads and applies it. Requires macOS 14+ on a supervised Mac.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Picker("Service", selection: $serviceType) {
                    ForEach(Self.services) { Text($0.label).tag($0.type) }
                }
                TextField("Zip URL", text: $dataURL,
                          prompt: Text(verbatim: "https://config.example.com/sshd.zip"))
                    .help("HTTPS URL of a .zip containing the service's config files.")
                TextField("SHA-256 of the zip", text: $sha256,
                          prompt: Text(verbatim: "required — your tooling/host computes it"))
                    .font(.callout.monospaced())
                    .help("Required by Apple for data assets. Provide the SHA-256 your hosting/tooling reports for the exact zip; verify the encoding it expects.")
                Toggle("URL requires MDM authentication", isOn: $mdmAuth)
                TextField("Set", text: $setName)
            }
            .formStyle(.grouped)

            if urlValid {
                Text("Creates data asset “\(assetID)” + config “\(configID)” (+ activation) in set “\(setName)”.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to Library") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!urlValid || sha256.trimmingCharacters(in: .whitespaces).isEmpty
                              || setName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func commit() {
        let asset = DDMDeclarations.dataAsset(
            identifier: assetID,
            dataURL: dataURL.trimmingCharacters(in: .whitespaces),
            contentType: "application/zip",
            sha256: sha256.trimmingCharacters(in: .whitespaces), mdmAuth: mdmAuth)
        let config = DDMDeclarations.serviceConfigFiles(
            identifier: configID, serviceType: serviceType, dataAssetReference: assetID)
        onAdd(asset, config, configID, setName.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}
