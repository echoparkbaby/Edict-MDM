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
    @State private var pulling = false
    @State private var setsField = ""
    @State private var mirrorCandidates: [String] = []
    @State private var showMirrorConfirm = false

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
                addEnforcement(config, configID: configID, set: set)
            }
        }
        .onChange(of: selectedID) { _, _ in setsField = selected?.sets.joined(separator: ", ") ?? "" }
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
            Menu("Add", systemImage: "plus") {
                Button("Add Declaration (JSON)…") { showNewSheet = true }
                Button("Import .json file(s)…") { importFiles() }
                Button("Pull from KMFDDM (server)…") { Task { await pullFromServer() } }
                Divider()
                Section("Built-in") {
                    Button("Enforce macOS Update…") { showEnforce = true }
                    Button("Status Subscriptions (+ activation)") { addStatusSubscriptions() }
                }
            }
            .fixedSize()
            .disabled(pulling)
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
            Text("Add a declaration as JSON, import .json files (e.g. from macadmins/ddm_examples), or add a built-in like Status Subscriptions. Then Sync to push them to KMFDDM, or Export a folder to version in git.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List + detail

    private var list: some View {
        List(library.items, selection: $selectedID) { item in
            VStack(alignment: .leading, spacing: 2) {
                Text(item.identifier).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(item.kind).font(.caption2)
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
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(item.identifier).font(.headline).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button(role: .destructive) { library.remove(item.id); selectedID = nil } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .help("Remove from the local library (does not touch KMFDDM)")
                }
                HStack(spacing: 6) {
                    Text("Sets").font(.caption).foregroundStyle(.secondary)
                    TextField("default, security", text: $setsField).textFieldStyle(.roundedBorder)
                    Button("Save") { saveSets(item) }.disabled(setsField == item.sets.joined(separator: ", "))
                }
                ScrollView {
                    Text(item.prettyJSON)
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(.rect(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 0.5) }
            }
            .padding(12)
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

    private func addStatusSubscriptions() {
        let configID = "com.hellocomputer.edict.status-subscriptions"
        let actID = DDMDeclarations.activationID(for: configID)
        library.add(DDMDeclarations.statusSubscriptions(identifier: configID), sets: ["default"])
        library.add(DDMDeclarations.activation(identifier: actID, configurationIDs: [configID]), sets: ["default"])
        flash("Added status subscriptions + activation to set “default”")
    }

    /// Add an update-enforcement config + its paired activation to the
    /// library (the deploy path's `KMFDDMService.deploy` makes the activation
    /// itself; in the library we author both explicitly).
    private func addEnforcement(_ config: Data, configID: String, set: String) {
        let actID = DDMDeclarations.activationID(for: configID)
        library.add(config, sets: [set])
        library.add(DDMDeclarations.activation(identifier: actID, configurationIDs: [configID]), sets: [set])
        flash("Added “\(configID)” + activation to set “\(set)”")
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
