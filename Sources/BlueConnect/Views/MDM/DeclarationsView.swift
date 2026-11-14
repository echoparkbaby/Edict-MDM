import SwiftUI

/// Edict MDM declarations browser — the center pane when the sidebar's
/// Device Management → Declarations row is selected.
///
/// Master-detail: declaration identifiers from KMFDDM on the left;
/// the selected declaration's JSON, its set memberships, and actions
/// (touch / add to set / remove from set / delete) on the right.
/// Adding a declaration to a set that an enrollment is associated with
/// pushes it to those devices immediately — KMFDDM fires the
/// DeclarativeManagement command on every association/content change.
struct DeclarationsView: View {
    var serverOnly = false
    @EnvironmentObject private var settings: SettingsStore
    @Environment(ActivityLog.self) private var activity

    @State private var declarations: [String] = []
    @State private var selectedID: String?
    @State private var loading = false
    @State private var loadError: String?

    // Detail state for the selected declaration
    @State private var detailJSON: String = ""
    @State private var detailSets: [String] = []
    @State private var detailLoading = false
    @State private var detailError: String?

    // Action feedback + sheets
    @State private var actionError: String?
    @State private var actionNotice: String?
    @State private var showingNewSheet = false
    @State private var showingEnforceSheet = false
    @State private var confirmingDelete = false
    @State private var addSetName = "default"

    private enum Mode: String { case library = "Library", sets = "Sets", server = "Server (KMFDDM)" }
    @State private var mode: Mode = .library

    var body: some View {
        Group {
            if !settings.mdmEnabled || !settings.mdmConfigured {
                notConfigured
            } else {
                VStack(spacing: 0) {
                    if !serverOnly {
                    Picker("", selection: $mode) {
                        Text("Library").tag(Mode.library)
                        Text("Sets").tag(Mode.sets)
                        Text("Server (KMFDDM)").tag(Mode.server)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    Divider()
                    }
                    switch serverOnly ? Mode.server : mode {
                    case .library: DeclarationLibraryPane()
                    case .sets:    SetsGridPane()
                    case .server:  browser
                    }
                }
            }
        }
        .task { await refresh() }
        .sheet(isPresented: $showingNewSheet) {
            NewDeclarationSheet { json in
                await put(json: json)
            }
        }
        .sheet(isPresented: $showingEnforceSheet) {
            UpdateEnforcementSheet { config, configID, set in
                try await KMFDDMService(settings: settings).deploy(configJSON: config, configID: configID, toSet: set)
                activity.record(.category, title: "Enforced update", detail: "\(configID), set “\(set)”")
                flash("Update enforcement deployed")
                await refresh()
            }
        }
        .alert("Delete Declaration?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let id = selectedID { Task { await delete(id: id) } }
            }
        } message: {
            Text("Delete “\(selectedID ?? "")” from the KMFDDM store? Devices keep their last-synced state until the next declaration change reaches them.")
        }
    }

    // MARK: - Empty / unconfigured

    private var notConfigured: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.badge.gearshape")
                .font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Device Management isn't configured")
                .font(.headline)
            Text("Set the NanoMDM and KMFDDM server URLs and API keys in Settings → Device Management, then come back here.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Browser

    private var browser: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                list
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                detail
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Declarations").font(.headline)
            if loading { ProgressView().controlSize(.small) }
            Text("\(declarations.count)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let notice = actionNotice {
                Text(notice).font(.caption).foregroundStyle(.green)
                    .transition(.opacity)
            }
            if let err = actionError {
                Text(err).font(.caption).foregroundStyle(.orange)
                    .lineLimit(1).truncationMode(.tail)
                    .help(err)
            }
            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Re-fetch the declaration list from KMFDDM")
            Button {
                showingEnforceSheet = true
            } label: {
                Label("Enforce Update…", systemImage: "arrow.down.circle.dotted")
            }
            .help("Require a macOS version by a deadline — devices in the set handle the install themselves")
            Button {
                showingNewSheet = true
            } label: {
                Label("New Declaration", systemImage: "plus")
            }
            .help("Upload a new declaration (JSON) to KMFDDM")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var list: some View {
        Group {
            if let err = loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { Task { await refresh() } }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if declarations.isEmpty && !loading {
                VStack(spacing: 8) {
                    Text("No declarations yet")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Click New Declaration to upload your first one.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(declarations, id: \.self, selection: $selectedID) { id in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(shortName(id)).lineLimit(1)
                        if shortName(id) != id {
                            Text(id).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .tag(id)
                }
                .listStyle(.inset)
                // .task(id:) cancels the previous load on reselect, so a slow
                // response can't overwrite the newer selection's detail.
                .task(id: selectedID) {
                    detailJSON = ""; detailSets = []; detailError = nil
                    if let id = selectedID { await loadDetail(id: id) }
                }
            }
        }
    }

    /// Last reverse-DNS segment, e.g. "com.example.test" → "test".
    private func shortName(_ id: String) -> String {
        id.split(separator: ".").last.map(String.init) ?? id
    }

    // MARK: - Detail

    private var detail: some View {
        Group {
            if selectedID == nil {
                Text("Select a declaration")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if detailLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = detailError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                detailLoaded
            }
        }
    }

    @ViewBuilder
    private var detailLoaded: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailActions
            Divider()
            ScrollView {
                Text(detailJSON)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    private var detailActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    if let id = selectedID { Task { await touch(id: id) } }
                } label: {
                    Label("Touch", systemImage: "hand.tap")
                }
                .help("Bump the ServerToken so enrolled devices re-evaluate this declaration")

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Remove this declaration from KMFDDM")

                Spacer()
            }

            HStack(spacing: 6) {
                Text("Sets:").font(.caption).foregroundStyle(.secondary)
                if detailSets.isEmpty {
                    Text("none").font(.caption).foregroundStyle(.secondary).italic()
                } else {
                    ForEach(detailSets, id: \.self) { set in
                        HStack(spacing: 3) {
                            Text(set).font(.caption)
                            Button("Remove from \(set)", systemImage: "xmark.circle.fill") {
                                if let id = selectedID {
                                    Task { await removeFromSet(id: id, set: set) }
                                }
                            }
                            .labelStyle(.iconOnly)
                            .font(.caption2).foregroundStyle(.secondary)
                            .buttonStyle(.plain)
                            .help("Remove from “\(set)” — affected devices are notified")
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                Spacer()
                TextField("set name", text: $addSetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                Button {
                    if let id = selectedID {
                        let set = addSetName.trimmingCharacters(in: .whitespaces)
                        if !set.isEmpty { Task { await addToSet(id: id, set: set) } }
                    }
                } label: {
                    Label("Add to Set", systemImage: "plus.circle")
                }
                .disabled(addSetName.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Add this declaration to a set — devices associated with the set receive it immediately")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - Data

    @MainActor
    private func refresh() async {
        guard settings.mdmEnabled, settings.mdmConfigured else { return }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            declarations = try await KMFDDMService(settings: settings)
                .listDeclarations()
                .sorted()
            if let sel = selectedID, !declarations.contains(sel) {
                selectedID = nil
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func loadDetail(id: String) async {
        detailLoading = true
        detailError = nil
        // A cancelled (superseded) load leaves state to the newer one.
        defer { if !Task.isCancelled { detailLoading = false } }
        let svc = KMFDDMService(settings: settings)
        do {
            let raw = try await svc.declaration(id: id)
            let sets = try await svc.setsForDeclaration(id: id).sorted()
            guard !Task.isCancelled else { return }
            detailJSON = Self.prettyJSON(raw)
            detailSets = sets
        } catch {
            guard !Task.isCancelled else { return }
            detailError = error.localizedDescription
        }
    }

    // MARK: - Actions

    @MainActor
    private func put(json: Data) async {
        do {
            try await KMFDDMService(settings: settings).putDeclaration(json)
            flash("Declaration saved")
            await refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }

    @MainActor
    private func touch(id: String) async {
        do {
            try await KMFDDMService(settings: settings).touchDeclaration(id: id)
            flash("Touched — devices will re-sync")
            await loadDetail(id: id)
        } catch {
            actionError = error.localizedDescription
        }
    }

    @MainActor
    private func delete(id: String) async {
        do {
            try await KMFDDMService(settings: settings).deleteDeclaration(id: id)
            selectedID = nil
            flash("Deleted \(shortName(id))")
            await refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }

    @MainActor
    private func addToSet(id: String, set: String) async {
        do {
            try await KMFDDMService(settings: settings).addDeclaration(id, toSet: set)
            flash("Added to “\(set)”")
            await loadDetail(id: id)
        } catch {
            actionError = error.localizedDescription
        }
    }

    @MainActor
    private func removeFromSet(id: String, set: String) async {
        do {
            try await KMFDDMService(settings: settings).removeDeclaration(id, fromSet: set)
            flash("Removed from “\(set)”")
            await loadDetail(id: id)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Show a transient success note in the header (replaces any error).
    @MainActor
    private func flash(_ message: String) {
        actionError = nil
        actionNotice = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if actionNotice == message { actionNotice = nil }
        }
    }

    private static func prettyJSON(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return String(data: pretty, encoding: .utf8) ?? ""
    }
}

// MARK: - New Declaration sheet

/// Paste-a-JSON editor for uploading a declaration. Validates that the
/// body parses as JSON and carries the required Type/Identifier keys
/// before enabling Upload — KMFDDM rejects malformed declarations with
/// an HTTP error either way, but catching it client-side gives a
/// friendlier message.
struct NewDeclarationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onUpload: (Data) async -> Void

    @State private var jsonText: String = """
    {
        "Type": "com.apple.configuration.management.test",
        "Identifier": "com.example.test",
        "Payload": {
            "Echo": "hello"
        }
    }
    """
    @State private var uploading = false

    private var validationError: String? {
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "Not valid JSON" }
        guard let type = obj["Type"] as? String, !type.isEmpty
        else { return "Missing \"Type\"" }
        guard let id = obj["Identifier"] as? String, !id.isEmpty
        else { return "Missing \"Identifier\"" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Declaration").font(.headline)
            Text("Paste the declaration JSON. Type and Identifier are required; KMFDDM assigns the ServerToken. Uploading an existing Identifier replaces its content and notifies affected devices.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $jsonText)
                .font(.body.monospaced())
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
            HStack {
                if let err = validationError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    guard let data = jsonText.data(using: .utf8) else { return }
                    uploading = true
                    Task {
                        await onUpload(data)
                        uploading = false
                        dismiss()
                    }
                } label: {
                    if uploading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Upload")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validationError != nil || uploading)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
