import SwiftUI

/// Form for the DDM passcode policy — login-password rules each Mac enforces,
/// no JSON. Every field maps to a macOS-supported key in
/// `com.apple.configuration.passcode.settings`; only the values you set are
/// emitted. Builds the configuration + its paired activation into a set.
struct PasscodeSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (_ config: Data, _ configID: String, _ set: String) -> Void

    @State private var requirePasscode = true
    @State private var minimumLength = 8
    @State private var requireAlphanumeric = false
    @State private var requireComplex = false
    @State private var minimumComplexChars = 0
    @State private var maxInactivity = 5          // minutes, 0–15; 0 = off
    @State private var lockAfterFailures = false
    @State private var maxFailedAttempts = 5      // 2–11
    @State private var maxAgeInDays = 0           // 0 = never; common values via picker
    @State private var reuseLimit = 0             // 0 = off, else 1–50
    @State private var changeAtNextAuth = false
    @State private var setName = "default"

    private let configID = "com.hellocomputer.edict.passcode-policy"
    private let ageOptions = [0, 30, 60, 90, 180, 365]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Passcode Policy").font(.headline)
            Text("Login-password rules each Mac enforces. Only the options you set are applied. Requires macOS 13 or newer.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Section("Require") {
                    Toggle("Require a login password", isOn: $requirePasscode)
                    Toggle("Require letters & numbers", isOn: $requireAlphanumeric)
                    Toggle("Require a complex password", isOn: $requireComplex)
                }
                Section("Strength") {
                    Stepper(minimumLength == 0 ? "Minimum length: none" : "Minimum length: \(minimumLength)",
                            value: $minimumLength, in: 0...16)
                    Stepper("Special characters: \(minimumComplexChars)",
                            value: $minimumComplexChars, in: 0...4)
                }
                Section("Lockout & expiry") {
                    Stepper(maxInactivity == 0 ? "Auto-lock: off" : "Auto-lock after \(maxInactivity) min",
                            value: $maxInactivity, in: 0...15)
                    Toggle("Lock after failed attempts", isOn: $lockAfterFailures)
                    if lockAfterFailures {
                        Stepper("Lock after \(maxFailedAttempts) tries", value: $maxFailedAttempts, in: 2...11)
                    }
                    Picker("Expire password", selection: $maxAgeInDays) {
                        ForEach(ageOptions, id: \.self) { d in
                            Text(d == 0 ? "Never" : "Every \(d) days").tag(d)
                        }
                    }
                    Stepper(reuseLimit == 0 ? "Prevent reuse: off" : "No reuse of last \(reuseLimit)",
                            value: $reuseLimit, in: 0...50)
                }
                Section {
                    Toggle("Force change at next login", isOn: $changeAtNextAuth)
                    TextField("Set", text: $setName)
                        .help("Which KMFDDM set receives this. Every Mac associated with the set enforces it.")
                }
            }
            .formStyle(.grouped)
            .frame(height: 400)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to Library") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(setName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func commit() {
        let config = DDMDeclarations.passcodeSettings(
            identifier: configID,
            requirePasscode: requirePasscode,
            minimumLength: minimumLength,
            requireAlphanumeric: requireAlphanumeric,
            requireComplex: requireComplex,
            minimumComplexChars: minimumComplexChars,
            maxInactivityMinutes: maxInactivity,
            maxFailedAttempts: lockAfterFailures ? maxFailedAttempts : 0,
            maxAgeInDays: maxAgeInDays,
            reuseLimit: reuseLimit,
            changeAtNextAuth: changeAtNextAuth)
        onAdd(config, configID, setName.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}
