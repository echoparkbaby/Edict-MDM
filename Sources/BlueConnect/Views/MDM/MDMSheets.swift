import SwiftUI

// Reusable MDM sheets, extracted from the retired standalone Devices view
// so the merged fleet table / dashboard / inspector can all present them.

/// Create or edit a smart group's rules. A Mac is a member when it
/// matches every rule (AND).
struct SmartGroupEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var group: SmartGroup
    let onSave: (SmartGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Smart Group").font(.headline)
            TextField("Group name", text: $group.name).textFieldStyle(.roundedBorder)
            Text("A Mac is a member when it matches every rule below.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(spacing: 6) {
                ForEach($group.rules) { $rule in
                    HStack(spacing: 6) {
                        Picker("", selection: $rule.field) {
                            ForEach(SmartGroupRule.Field.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        if rule.field.needsValue {
                            TextField(rule.field == .modelContains ? "MacBook" : "15.5",
                                      text: $rule.value)
                                .textFieldStyle(.roundedBorder).frame(width: 110)
                        }
                        Spacer()
                        Button {
                            group.rules.removeAll { $0.id == rule.id }
                        } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button {
                group.rules.append(SmartGroupRule(field: .fileVaultOff))
            } label: { Label("Add Rule", systemImage: "plus") }
            .buttonStyle(.link)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(group); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(group.name.trimmingCharacters(in: .whitespaces).isEmpty || group.rules.isEmpty)
            }
        }
        .padding(20).frame(width: 480)
    }
}

/// PIN + optional message for DeviceLock. The PIN is what unlocks the
/// Mac afterward — losing it means a trip to recovery, so it's front
/// and center in the confirmation.
struct LockDeviceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let deviceName: String
    let onLock: (String, String?) async -> Void

    @State private var pin = ""
    @State private var message = ""
    @State private var working = false

    private var pinValid: Bool {
        pin.count == 6 && pin.allSatisfy(\.isNumber)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lock “\(deviceName)”").font(.headline)
            Text("The Mac reboots into a lock screen and is unusable until this 6-digit PIN is entered. Write the PIN down — without it, unlocking requires Apple support or recovery.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("6-digit PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            TextField("Message shown on the lock screen (optional)", text: $message)
                .textFieldStyle(.roundedBorder)
            HStack {
                if !pin.isEmpty && !pinValid {
                    Label("PIN must be exactly 6 digits", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    working = true
                    Task {
                        await onLock(pin, message.isEmpty ? nil : message)
                        working = false
                        dismiss()
                    }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Lock Mac") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!pinValid || working)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// Remote wipe with a typed-name confirmation — the one action in the
/// app with no undo, so it gets the strongest guard.
struct EraseDeviceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let deviceName: String
    let onErase: (String) async -> Void

    @State private var pin = ""
    @State private var confirmText = ""
    @State private var working = false

    private var pinValid: Bool {
        pin.count == 6 && pin.allSatisfy(\.isNumber)
    }
    private var confirmed: Bool {
        confirmText == deviceName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Erase “\(deviceName)”", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.red)
            Text("This wipes the Mac completely the moment it receives the push. Every file on it is destroyed. There is no undo and no cancel once sent. The PIN unlocks Intel/T2 Macs after the wipe.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("6-digit PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            TextField("Type the device name to confirm: \(deviceName)", text: $confirmText)
                .textFieldStyle(.roundedBorder)
            HStack {
                if !pin.isEmpty && !pinValid {
                    Label("PIN must be exactly 6 digits", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    working = true
                    Task {
                        await onErase(pin)
                        working = false
                        dismiss()
                    }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Erase This Mac") }
                }
                .disabled(!pinValid || !confirmed || working)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
