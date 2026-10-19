import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The local DDM declaration library — author/import declarations here, then
/// Sync pushes the whole set to KMFDDM (the native `syncdir` equivalent) or
/// Export writes a ddm_examples / syncdir folder for git.
struct DeclarationLibraryPane: View {
    @Environment(DDMLibraryStore.self) private var library
    @EnvironmentObject private var settings: SettingsStore

    @State private var selectedID: UUID?
    @State private var syncing = false
    @State private var notice: String?
    @State private var errorText: String?
    @State private var showNewSheet = false
    @State private var showEnforce = false
    @State private var showGallery = false
    @State private var showStatusForm = false
    @State private var showDiskForm = false
    @State private var showSoftwareUpdateForm = false
    @State private var showPasscodeForm = false
    @State private var showScreenSharingForm = false
    @State private var showCertificateForm = false
    @State private var showServiceConfigForm = false
    @State private var pendingChoice: AddChoice?
    @State private var pulling = false
    @State private var setsField = ""
    @State private var predicateBuffer = ""
    @State private var mirrorCandidates: [String] = []
    @State private var showMirrorConfirm = false
    @State private var showJSON = false

    private var selected: DDMLibraryItem? { library.items.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if library.items.isEmpty {
                empty
            } else {
                HSplitView {
                    list.frame(minWidth: 260, idealWidth: 320, maxWidth: 460)
                    detail.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .sheet(isPresented: $showNewSheet) {
            NewDeclarationSheet { json in
                if library.add(json) { flash("Added to library") }
                else { errorText = "That isn't a valid declaration (needs Type + Identifier)." }
            }
        }
        .sheet(isPresented: $showEnforce) {
            UpdateEnforcementSheet(commitLabel: "Add to Library") { config, configID, set in
                addConfig(config, configID: configID, set: set, label: "update enforcement")
            }
        }
        .sheet(isPresented: $showGallery, onDismiss: handlePendingChoice) {
            AddDeclarationGallery { choice in pendingChoice = choice }
        }
        .sheet(isPresented: $showStatusForm) {
            StatusReportingSheet { config, configID, set in
                addConfig(config, configID: configID, set: set, label: "status reporting")
            }
        }
        .sheet(isPresented: $showDiskForm) {
            DiskRestrictionsSheet { config, configID, set in
                addConfig(config, configID: configID, set: set, label: "drive restrictions")
            }
        }
        .sheet(isPresented: $showSoftwareUpdateForm) {
            SoftwareUpdateSettingsSheet { config, configID, set in
                addConfig(config, configID: configID, set: set, label: "update settings")
            }
        }
        .sheet(isPresented: $showPasscodeForm) {
            PasscodeSettingsSheet { config, configID, set in
                addConfig(config, configID: configID, set: set, label: "passcode policy")
            }
        }
        .sheet(isPresented: $showScreenSharingForm) {
            ScreenSharingSheet { config, configID, set in
                addConfig(config, configID: configID, set: set, label: "screen sharing")
            }
        }
        .sheet(isPresented: $showCertificateForm) {
            CertificateSheet { asset, config, configID, set in
                library.add(asset, sets: [set])
                addConfig(config, configID: configID, set: set, label: "certificate")
            }
        }
        .sheet(isPresented: $showServiceConfigForm) {
            ServiceConfigFilesSheet { asset, config, configID, set in
                library.add(asset, sets: [set])
                addConfig(config, configID: configID, set: set, label: "service config files")
            }
        }
        .onChange(of: selectedID) { _, _ in
            setsField = selected?.sets.joined(separator: ", ") ?? ""
            predicateBuffer = selected?.predicate ?? ""
            showJSON = false
        }
        .alert("Mirror to KMFDDM?", isPresented: $showMirrorConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Mirror & delete \(mirrorCandidates.count)", role: .destructive) { Task { await sync(prune: true) } }
        } message: {
            Text("Pushes your library, and DELETES \(mirrorCandidates.count) declaration(s) on KMFDDM that aren't in the library:\n\n"
                 + mirrorCandidates.prefix(12).joined(separator: "\n")
                 + (mirrorCandidates.count > 12 ? "\n… (+\(mirrorCandidates.count - 12) more)" : ""))
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Declaration Library").font(.headline)
            Text("\(library.items.count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let notice { Text(notice).font(.caption).foregroundStyle(.green).transition(.opacity) }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.orange).lineLimit(1).truncationMode(.tail).help(errorText)
            }
            Button("Add Declaration", systemImage: "plus") { showGallery = true }
                .disabled(pulling)
                .help("Pick a template — enforce an update, status reporting, or import")
            if syncing { ProgressView().controlSize(.small) }
            Menu {
                Button("Sync — add + update") { Task { await sync(prune: false) } }
                Button("Mirror — also delete server extras…", role: .destructive) { Task { await prepareMirror() } }
            } label: {
                Label("Sync to KMFDDM", systemImage: "arrow.up.circle")
            }
            .fixedSize()
            .disabled(syncing || library.items.isEmpty)
            .help("Push the library to KMFDDM. Mirror also deletes server declarations that aren't in your library.")
            Button("Export folder…", systemImage: "folder") { exportFolder() }
                .disabled(library.items.isEmpty)
                .help("Write a ddm_examples / syncdir folder (configurations/, activations/, sets/) for git")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.badge.gearshape").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("No declarations yet").font(.headline)
            Text("Pick a template — enforce a macOS update or status reporting — without touching JSON. Then Sync to push to KMFDDM, or Export a folder to version in git.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            Button("Add Declaration", systemImage: "plus") { showGallery = true }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List + detail

    private var list: some View {
        List(library.items, selection: $selectedID) { item in
            let f = item.fields  // one JSON parse per row
            VStack(alignment: .leading, spacing: 2) {
                Text(f.summary.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(f.identifier).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(f.kind).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                    if !item.sets.isEmpty {
                        Text(item.sets.joined(separator: ", ")).font(.caption2).foregroundStyle(.tint).lineLimit(1)
                    }
                }
            }
            .tag(item.id)
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var detail: some View {
        if let item = selected {
            let f = item.fields
            let summary = f.summary
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(summary.title).font(.title3.weight(.semibold))
                            Text(f.identifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button(role: .destructive) { library.remove(item.id); selectedID = nil } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .help("Remove from the local library (does not touch KMFDDM)")
                    }

                    Text(summary.blurb).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !summary.rows.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(summary.rows) { row in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(row.label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                        .frame(width: 110, alignment: .leading)
                                    Text(row.value).font(.callout).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(.rect(cornerRadius: 8))
                    }

                    if f.kind == "activation" {
                        predicateEditor(item)
                    }

                    HStack(spacing: 6) {
                        Text("Sets").font(.caption).foregroundStyle(.secondary)
                        TextField("default, security", text: $setsField).textFieldStyle(.roundedBorder)
                        Button("Save") { saveSets(item) }.disabled(setsField == item.sets.joined(separator: ", "))
                    }
                    .help("Comma-separated KMFDDM set names this declaration belongs to")

                    DisclosureGroup(isExpanded: $showJSON) {
                        Text(item.prettyJSON)
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .background(Color(NSColor.textBackgroundColor))
                            .clipShape(.rect(cornerRadius: 6))
                            .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 0.5) }
                    } label: {
                        Text("Raw JSON").font(.callout.weight(.medium))
                    }
                }
                .padding(12)
            }
        } else {
            Text("Select a declaration").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private func saveSets(_ item: DDMLibraryItem) {
        let sets = setsField.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        library.setMembership(item.id, sets: sets)
    }

    /// Predicate (condition) editor for an activation — gates the configuration
    /// it turns on so it only activates on matching devices.
    @ViewBuilder
    private func predicateEditor(_ item: DDMLibraryItem) -> some View {
        let current = item.predicate ?? ""
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Condition (predicate)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if item.predicate != nil {
                    Button("Clear") {
                        predicateBuffer = ""
                        library.setActivationPredicate(item.id, predicate: nil)
                    }
                }
                Button("Save") { library.setActivationPredicate(item.id, predicate: predicateBuffer) }
                    .disabled(predicateBuffer == current)
            }
            TextField("leave blank to always activate", text: $predicateBuffer)
                .textFieldStyle(.roundedBorder).font(.callout.monospaced())
            Text("An NSPredicate-format string. The configuration activates only on devices where it's true — gate by the device's reported status items (OS version, model, FileVault, …). Blank = always activate. See Apple's Predicate Programming guide for the exact syntax.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.06)))
    }

    /// After the gallery sheet closes, open the form (or run the action) for
    /// the chosen template. Deferred to the gallery's onDismiss so the next
    /// sheet presents cleanly after the gallery is fully gone.
    private func handlePendingChoice() {
        guard let choice = pendingChoice else { return }
        pendingChoice = nil
        switch choice {
        case .enforceUpdate:          showEnforce = true
        case .softwareUpdateSettings: showSoftwareUpdateForm = true
        case .statusReporting:        showStatusForm = true
        case .passcodePolicy:         showPasscodeForm = true
        case .screenSharing:          showScreenSharingForm = true
        case .certificate:            showCertificateForm = true
        case .serviceConfigFiles:     showServiceConfigForm = true
        case .diskRestrictions:       showDiskForm = true
        case .pasteJSON:              showNewSheet = true
        case .importFiles:            importFiles()
        case .pullFromServer:         Task { await pullFromServer() }
        }
    }

    /// Every gallery template commits the same way: add the configuration
    /// plus its paired activation to the library, both in the chosen set. (A
    /// configuration only takes effect once an activation references it.)
    private func addConfig(_ config: Data, configID: String, set: String, label: String) {
        let actID = DDMDeclarations.activationID(for: configID)
        library.add(config, sets: [set])
        library.add(DDMDeclarations.activation(identifier: actID, configurationIDs: [configID]), sets: [set])
        flash("Added \(label) + activation to set “\(set)”")
    }

    private func pullFromServer() async {
        pulling = true; notice = nil; errorText = nil
        defer { pulling = false }
        do {
            let n = try await library.importFromServer(settings: settings)
            flash("Pulled \(n) declaration(s) from KMFDDM")
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK else { return }
        var added = 0, skipped = 0
        for url in expandJSON(panel.urls) {
            if let data = try? Data(contentsOf: url), library.add(data) { added += 1 } else { skipped += 1 }
        }
        flash("Imported \(added)\(skipped > 0 ? ", skipped \(skipped) non-declaration" : "")")
    }

    /// Files chosen directly, plus any `.json` one level inside chosen dirs.
    private func expandJSON(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for u in urls {
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let inner = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
                out += inner.filter { $0.pathExtension.lowercased() == "json" }
            } else if u.pathExtension.lowercased() == "json" {
                out.append(u)
            }
        }
        return out
    }

    private func exportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do { try library.export(to: dir); flash("Exported \(library.items.count) declaration(s)") }
        catch { errorText = error.localizedDescription }
    }

    private func sync(prune: Bool) async {
        syncing = true; notice = nil; errorText = nil
        defer { syncing = false }
        do {
            let r = try await library.sync(settings: settings, prune: prune)
            var msg = "Synced \(r.declarations) declaration(s), \(r.setAdds) set assignment(s)"
            if prune { msg += ", deleted \(r.pruned) extra(s)" }
            flash(msg)
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Compute what a mirror would delete; confirm before doing it (or just
    /// sync if there's nothing extra on the server).
    private func prepareMirror() async {
        syncing = true; notice = nil; errorText = nil
        do {
            mirrorCandidates = try await library.pruneCandidates(settings: settings)
        } catch {
            errorText = error.localizedDescription
            syncing = false
            return
        }
        syncing = false
        if mirrorCandidates.isEmpty { await sync(prune: false) }
        else { showMirrorConfirm = true }
    }

    private func flash(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notice == message { notice = nil }
        }
    }
}
