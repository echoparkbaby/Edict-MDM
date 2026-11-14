import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Edict MDM configuration-profile library — the center pane for the
/// sidebar's Device Management → Profiles row. Pick a template, fill a
/// form, choose which enrolled Macs to push it to, and Edict builds the
/// .mobileconfig and sends it via the InstallProfile command. No XML.
struct ProfilesView: View {

    @EnvironmentObject private var settings: SettingsStore
    @Environment(MDMFleetIndex.self) private var fleet
    @Environment(ActivityLog.self) private var activity

    @State private var template: ProfileTemplate = .fileVault
    /// All the template form fields + build/validation, factored out so the
    /// form is its own view and the logic is testable.
    @State private var form = ProfileFormState()
    /// Drag-drop highlight for the .mobileconfig drop target.
    @State private var dropHighlight = false

    // Targets + deploy
    private var devices: [MDMEnrollment] { fleet.devices.filter(\.isEnabled) }
    @State private var targetIDs = Set<String>()
    private var loadingDevices: Bool { fleet.loading }
    @State private var deploying = false
    @State private var result: String?

    // Smart-group targeting
    @Environment(BlueSkyHostListStore.self) private var hostStore
    @State private var targetMode: TargetMode = .selected
    @State private var groupID: UUID?
    private var osVersions: [String: String] { fleet.snapshots.compactMapValues(\.os) }
    private var fileVault: [String: String] { fleet.snapshots.compactMapValues { $0.fileVault.map { $0 ? "true" : "false" } } }
    private var models: [String: String] { fleet.snapshots.compactMapValues(\.model) }

    enum TargetMode: String, CaseIterable, Identifiable {
        case selected = "Pick devices"
        case group = "Smart group"
        var id: String { rawValue }
    }

    // Saved / favorited profiles
    enum CatalogItem: Hashable { case template(ProfileTemplate); case saved(UUID) }
    @State private var selected: CatalogItem = .template(.fileVault)
    @State private var saved: [SavedProfile] = []
    @State private var showingSaveSheet = false
    @State private var saveName = ""
    @State private var saveFavorite = false

    /// Set when a deploy would replace a profile already on a device —
    /// drives the diff-review sheet before the push goes out.
    @State private var pendingDeploy: PendingDeploy?

    struct PendingDeploy: Identifiable {
        let id = UUID()
        let data: Data
        let name: String
        let changes: [ProfileDiff.Change]
        let deviceCount: Int
    }

    /// Platform filter toggles — empty = show all.
    @State private var platformFilter: Set<ProfilePlatform> = []

    /// Templates alphabetized and platform-filtered; Custom pinned last.
    private var sortedTemplates: [ProfileTemplate] {
        ProfileTemplate.allCases.filter { $0 != .custom }
            .filter { platformFilter.isEmpty || !$0.platformSet.isDisjoint(with: platformFilter) }
            .sorted { $0.rawValue.localizedCaseInsensitiveCompare($1.rawValue) == .orderedAscending } + [.custom]
    }
    /// Saved profiles: favorites first, then alphabetical.
    private var sortedSaved: [SavedProfile] {
        saved.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
    private var currentSaved: SavedProfile? {
        if case .saved(let id) = selected { return saved.first { $0.id == id } }
        return nil
    }

    var body: some View {
        Group {
            if !settings.mdmEnabled || !settings.mdmConfigured {
                unconfigured
            } else {
                HSplitView {
                    catalog.frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
                    editor.frame(minWidth: 380, maxWidth: .infinity)
                }
                .overlay(alignment: .top) {
                    if dropHighlight {
                        Text("Drop a .mobileconfig to load it")
                            .font(.caption).padding(8)
                            .background(Capsule().fill(Color.accentColor.opacity(0.85)))
                            .foregroundStyle(.white).padding(.top, 8)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    handleDrop(urls)
                } isTargeted: { dropHighlight = $0 }
            }
        }
        .task {
            saved = SavedProfilesStore.load()
            await loadDevices()
        }
        .onChange(of: selected) { _, v in if case .template(let t) = v { template = t } }
        .sheet(isPresented: $showingSaveSheet) { saveSheet }
        .sheet(item: $pendingDeploy) { diffSheet($0) }
    }

    private var unconfigured: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.fill").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Device Management isn't configured").font(.headline)
            Text("Set the server URLs and keys in Settings → Device Management first.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var platformToggles: some View {
        HStack(spacing: 6) {
            ForEach(ProfilePlatform.allCases) { p in
                let on = platformFilter.contains(p)
                Button {
                    if on { platformFilter.remove(p) } else { platformFilter.insert(p) }
                } label: {
                    Text(p.rawValue).font(.caption.weight(on ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(on ? Color.accentColor.opacity(0.22) : Color(NSColor.controlBackgroundColor)))
                        .overlay(Capsule().stroke(on ? Color.accentColor : .clear, lineWidth: 1))
                        .foregroundStyle(on ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if !platformFilter.isEmpty {
                Button { platformFilter.removeAll() } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Clear platform filter")
                .accessibilityLabel("Clear platform filter")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private var catalog: some View {
        VStack(spacing: 0) {
            platformToggles
            Divider()
            List(selection: $selected) {
                if !saved.isEmpty {
                    Section("Saved") {
                        ForEach(sortedSaved) { sp in
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(sp.name).lineLimit(1)
                                    if !sp.summary.isEmpty {
                                        Text(sp.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            } icon: {
                                Image(systemName: sp.favorite ? "star.fill" : "doc")
                                    .foregroundStyle(sp.favorite ? .yellow : .secondary)
                            }
                            .tag(CatalogItem.saved(sp.id))
                        }
                    }
                }
                Section("Templates") {
                    ForEach(sortedTemplates) { t in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                // Name on its own line so a long type can't get
                                // clipped by the platform badge sitting beside it.
                                Text(t.rawValue).fixedSize(horizontal: false, vertical: true)
                                Text(t.platforms).font(.caption2)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                    .foregroundStyle(.secondary)
                                Text(t.blurb).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        } icon: { Image(systemName: t.icon) }
                        .tag(CatalogItem.template(t))
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button { Task { await importProfiles() } } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderless).font(.caption)
                    .help("Import .mobileconfig files (signed or plain) as saved profiles")
                Spacer()
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let sp = currentSaved {
            savedEditor(sp)
        } else {
            templateEditor
        }
    }

    private var templateEditor: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(template.rawValue).font(.headline)
                    TemplateFormView(template: template, form: $form)
                    Divider()
                    targetPicker
                    resultLine
                }
                .padding(16)
            }
            Divider()
            HStack {
                Button {
                    saveName = template.rawValue; saveFavorite = false; showingSaveSheet = true
                } label: { Label("Save…", systemImage: "tray.and.arrow.down") }
                    .disabled(!form.isValid(for: template))
                    .help("Save this configured profile to reuse or favorite")
                Spacer()
                Button {
                    Task { await attemptDeployBuilt() }
                } label: {
                    if deploying { ProgressView().controlSize(.small) }
                    else { Label("Deploy to \(resolvedTargets.count) device\(resolvedTargets.count == 1 ? "" : "s")",
                                 systemImage: "paperplane.fill") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(deploying || resolvedTargets.isEmpty || !form.isValid(for: template))
            }
            .padding(12)
        }
    }

    private func savedEditor(_ sp: SavedProfile) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(sp.name).font(.headline)
                        if sp.isSigned {
                            Label("Signed", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                        }
                        Spacer()
                        Button { toggleFavorite(sp) } label: {
                            Image(systemName: sp.favorite ? "star.fill" : "star").foregroundStyle(.yellow)
                        }.buttonStyle(.plain).help("Favorite")
                        .accessibilityLabel(sp.favorite ? "Remove from favorites" : "Add to favorites")
                        Button(role: .destructive) { deleteSaved(sp) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).help("Delete this saved profile")
                            .accessibilityLabel("Delete this saved profile")
                    }
                    if !sp.summary.isEmpty {
                        Text("Payloads: \(sp.summary)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Stored .mobileconfig, \(sp.data.count) bytes — deploys as-is\(sp.isSigned ? " with its signature intact" : "").")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    targetPicker
                    resultLine
                }
                .padding(16)
            }
            Divider()
            HStack {
                Spacer()
                Button {
                    Task { await attemptDeploy(data: sp.data, name: sp.name) }
                } label: {
                    if deploying { ProgressView().controlSize(.small) }
                    else { Label("Deploy to \(resolvedTargets.count) device\(resolvedTargets.count == 1 ? "" : "s")",
                                 systemImage: "paperplane.fill") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(deploying || resolvedTargets.isEmpty)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var resultLine: some View {
        if let result {
            Text(result).font(.caption)
                .foregroundStyle(result.hasPrefix("Queued") || result.hasPrefix("Saved") || result.hasPrefix("Imported") ? .green : .orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Profile").font(.headline)
            TextField("Name", text: $saveName).textFieldStyle(.roundedBorder)
            Toggle("Favorite", isOn: $saveFavorite)
            HStack {
                Spacer()
                Button("Cancel") { showingSaveSheet = false }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await saveCurrent() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 380)
    }

    /// The devices a deploy will hit, by the active target mode.
    private var resolvedTargets: [MDMEnrollment] {
        switch targetMode {
        case .selected: return devices.filter { targetIDs.contains($0.id) }
        case .group:    return selectedGroup.map { groupMembers($0) } ?? []
        }
    }


    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Deploy to").font(.caption).bold().foregroundStyle(.secondary)
                Picker("", selection: $targetMode) {
                    ForEach(TargetMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                if targetMode == .selected {
                    Button(targetIDs.count == devices.count ? "None" : "All") {
                        targetIDs = targetIDs.count == devices.count ? [] : Set(devices.map(\.id))
                    }
                    .font(.caption).buttonStyle(.link)
                }
                Spacer()
                if loadingDevices { ProgressView().controlSize(.small) }
            }
            if targetMode == .selected {
                if devices.isEmpty && !loadingDevices {
                    Text("No enrolled devices. Enroll a Mac first (Devices tab).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(devices) { d in
                    Toggle(isOn: Binding(
                        get: { targetIDs.contains(d.id) },
                        set: { if $0 { targetIDs.insert(d.id) } else { targetIDs.remove(d.id) } }
                    )) { Text(deviceLabel(d)) }
                    .toggleStyle(.checkbox)
                }
            } else {
                if settings.smartGroups.isEmpty {
                    Text("No smart groups yet. Create one in the Devices view (group filter → New Group).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Group", selection: $groupID) {
                        Text("Choose a group").tag(Optional<UUID>.none)
                        ForEach(settings.smartGroups) { g in
                            Text("\(g.name) (\(groupMembers(g).count))").tag(Optional(g.id))
                        }
                    }
                    if let g = selectedGroup {
                        let n = groupMembers(g).count
                        Text("\(n) member\(n == 1 ? "" : "s") match right now. Membership re-evaluates each deploy.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var selectedGroup: SmartGroup? {
        guard let id = groupID else { return nil }
        return settings.smartGroups.first { $0.id == id }
    }

    private func deviceFacts(_ d: MDMEnrollment) -> SmartGroup.DeviceFacts {
        SmartGroup.DeviceFacts(
            osVersion: osVersions[d.id],
            fileVaultOn: fileVault[d.id].map { $0 == "true" || $0 == "1" },
            model: models[d.id],
            matchedBlueSky: bscMatched(d),
            enrolled: d.isEnabled
        )
    }

    private func bscMatched(_ d: MDMEnrollment) -> Bool { bscHost(d) != nil }

    private func bscHost(_ d: MDMEnrollment) -> BlueSkyHost? {
        guard let serial = d.serialNumber, !serial.isEmpty else { return nil }
        return hostStore.hosts.first { ($0.serialnum ?? "").caseInsensitiveCompare(serial) == .orderedSame }
    }

    private func groupMembers(_ g: SmartGroup) -> [MDMEnrollment] {
        devices.filter { g.contains(deviceFacts($0),
                                    requireFileVault: settings.mdmRequireFileVault,
                                    minOS: settings.mdmMinOSVersion) }
    }

    /// Friendly name for a target row: operator label, then the BlueSky host
    /// name (free, already cached for BSC clients), then the device's own
    /// computer name reported by MDM (DeviceInformation → DeviceName, cached
    /// in `autoName`), then the serial, then a short id. No MunkiReport — the
    /// name is the device's to give, and MDM reports it.
    private func deviceLabel(_ d: MDMEnrollment) -> String {
        let dev = settings.mdmDevices.first { $0.id == d.id }
        if let stored = dev?.label, !stored.isEmpty { return stored }
        if let host = bscHost(d) { return host.displayName }
        if let auto = dev?.autoName, !auto.isEmpty { return auto }
        return d.serialNumber ?? String(d.id.prefix(8))
    }

    /// Ask MDM for the computer name of any device that would otherwise show
    /// as a serial (no operator label, no BlueSky match, no cached name) and
    /// stash it in `autoName`. One DeviceInformation command per unnamed Mac,
    /// cached persistently — so it's a one-time cost that converges.
    private func resolveDeviceNames() async {
        let unnamed = devices.filter { d in
            let dev = settings.mdmDevices.first { $0.id == d.id }
            return (dev?.label ?? "").isEmpty && (dev?.autoName ?? "").isEmpty && bscHost(d) == nil
        }
        guard !unnamed.isEmpty else { return }
        let nano = NanoMDMService(settings: settings)
        let api = EnrollmentsAPI(settings: settings)
        for d in unnamed {
            guard let uuid = try? await nano.requestDeviceInformation(enrollmentID: d.id) else { continue }
            _ = try? await nano.push(enrollmentIDs: d.id)
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(2))
                guard let res = try? await api.commandResult(uuid: uuid) else { continue }
                if let name = (res.dict("QueryResponses")["DeviceName"] as? String)?
                    .trimmingCharacters(in: .whitespaces), !name.isEmpty {
                    settings.setMDMDeviceAutoName(name, for: d.id)
                }
                break
            }
        }
    }


    /// Accept a dropped .mobileconfig: load its XML into the Custom
    /// template so it can be reviewed and deployed.
    private func handleDrop(_ urls: [URL]) -> Bool {
        guard let url = urls.first else { return false }
        do {
            form.customXML = try String(contentsOf: url, encoding: .utf8)
        } catch {
            result = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
        // Select the Custom template too, so the editor shows it even when a
        // saved profile was selected (onChange(of: selected) syncs `template`).
        template = .custom
        selected = .template(.custom)
        result = "Loaded \(url.lastPathComponent) — review and deploy."
        return true
    }

    @MainActor
    private func loadDevices() async {
        if fleet.refreshedAt == nil && !fleet.loading {
            await fleet.refresh(settings: settings,
                                bscSerials: Set(hostStore.hosts.compactMap { $0.serialnum?.uppercased() }))
        }
        if let error = fleet.loadError { result = "Couldn't load devices: \(error)" }
        Task { await resolveDeviceNames() }
    }

    /// Build the current template and deploy it.
    @MainActor
    private func deployBuilt() async {
        let built: (data: Data, name: String)
        do { built = try form.build(for: template) }
        catch { result = "Couldn't build profile: \(error.localizedDescription)"; return }
        await deploy(data: built.data, name: built.name)
    }

    /// Build the template, then run it through the diff gate.
    @MainActor
    private func attemptDeployBuilt() async {
        let built: (data: Data, name: String)
        do { built = try form.build(for: template) }
        catch { result = "Couldn't build profile: \(error.localizedDescription)"; return }
        await attemptDeploy(data: built.data, name: built.name)
    }

    /// If any target already has a profile with this identifier (per the
    /// deployment log), show a diff sheet first; otherwise deploy straight
    /// away. The diff compares the last bytes Edict sent against the new
    /// ones, so the operator sees exactly what this push will change.
    @MainActor
    private func attemptDeploy(data: Data, name: String) async {
        guard let newID = await DeploymentLog.payloadIdentifier(data) else {
            await deploy(data: data, name: name); return
        }
        let log = DeploymentLog.load()
        var newest: DeploymentLog.Entry?
        var affected = 0
        for t in resolvedTargets {
            guard let prior = (log[t.id] ?? []).first(where: { $0.identifier == newID }) else { continue }
            affected += 1
            if newest == nil || prior.epoch > newest!.epoch { newest = prior }
        }
        if let newest, !newest.dataBase64.isEmpty {
            let changes = await ProfileDiff.compare(old: newest.data, new: data)
            if !changes.isEmpty {
                pendingDeploy = PendingDeploy(data: data, name: name, changes: changes, deviceCount: affected)
                return
            }
        }
        await deploy(data: data, name: name)
    }

    private func diffSheet(_ pending: PendingDeploy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Replacing “\(pending.name)”").font(.headline)
                    Text("\(pending.deviceCount) of \(resolvedTargets.count) target device\(resolvedTargets.count == 1 ? "" : "s") already \(pending.deviceCount == 1 ? "has" : "have") this profile. \(pending.changes.count) change\(pending.changes.count == 1 ? "" : "s") versus what Edict last sent:")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pending.changes) { c in
                        HStack(alignment: .top, spacing: 8) {
                            Text(c.kind.rawValue)
                                .font(.caption2.bold())
                                .foregroundStyle(diffColor(c.kind))
                                .frame(width: 56, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.path).font(.caption.bold())
                                switch c.kind {
                                case .changed:
                                    Text("\(c.before ?? "—")  →  \(c.after ?? "—")")
                                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                case .added:
                                    Text(c.after ?? "—").font(.caption2.monospaced()).foregroundStyle(.green)
                                case .removed:
                                    Text(c.before ?? "—").font(.caption2.monospaced()).foregroundStyle(.red)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 280)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            HStack {
                Spacer()
                Button("Cancel") { pendingDeploy = nil }.keyboardShortcut(.cancelAction)
                Button("Deploy anyway") {
                    let p = pending
                    pendingDeploy = nil
                    Task { await deploy(data: p.data, name: p.name) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 460)
    }

    private func diffColor(_ kind: ProfileDiff.Change.Kind) -> Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        case .changed: return .orange
        }
    }

    /// Deploy raw profile bytes (template-built or saved/imported) to the
    /// resolved targets.
    @MainActor
    private func deploy(data: Data, name: String) async {
        deploying = true
        result = nil
        defer { deploying = false }
        let nano = NanoMDMService(settings: settings)
        let targets = resolvedTargets
        var ok = 0, failed = 0
        var deployedTo: [String] = []
        for t in targets {
            do {
                try await nano.installProfile(enrollmentID: t.id, profile: data)
                _ = try? await nano.push(enrollmentIDs: t.id)
                deployedTo.append(t.id)
                ok += 1
            } catch { failed += 1 }
        }
        // Track for drift detection in the device detail.
        await DeploymentLog.record(profileData: data, name: name, to: deployedTo,
                                   nowEpoch: Date().timeIntervalSince1970)
        result = failed == 0
            ? "Queued \(name) to \(ok) device\(ok == 1 ? "" : "s")"
            : "Queued to \(ok), failed \(failed)"
        activity.record(.category, title: "Queued profile: \(name)",
                        detail: "\(ok) device\(ok == 1 ? "" : "s")" + (failed > 0 ? ", \(failed) failed" : ""))
    }

    // MARK: - Saved profiles

    private func saveCurrent() async {
        showingSaveSheet = false
        let built: (data: Data, name: String)
        do { built = try form.build(for: template) } catch { result = "Couldn't build: \(error.localizedDescription)"; return }
        let desc = await SavedProfilesStore.describe(built.data, fallbackName: saveName)
        let sp = SavedProfile(name: saveName.trimmingCharacters(in: .whitespaces),
                              data: built.data, favorite: saveFavorite, summary: desc.summary)
        saved.append(sp)
        SavedProfilesStore.save(saved)
        selected = .saved(sp.id)
        result = "Saved \(sp.name)"
    }

    private func toggleFavorite(_ sp: SavedProfile) {
        guard let idx = saved.firstIndex(where: { $0.id == sp.id }) else { return }
        saved[idx].favorite.toggle()
        SavedProfilesStore.save(saved)
    }

    private func deleteSaved(_ sp: SavedProfile) {
        saved.removeAll { $0.id == sp.id }
        SavedProfilesStore.save(saved)
        selected = .template(.fileVault)
    }

    private func importProfiles() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "mobileconfig") ?? .data]
        guard panel.runModal() == .OK else { return }
        var urls: [URL] = []
        for u in panel.urls {
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let inner = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
                urls += inner.filter { $0.pathExtension.lowercased() == "mobileconfig" }
            } else {
                urls.append(u)
            }
        }
        var added = 0
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let desc = await SavedProfilesStore.describe(data, fallbackName: url.deletingPathExtension().lastPathComponent)
            saved.append(SavedProfile(name: desc.name, data: data, favorite: true, summary: desc.summary))
            added += 1
        }
        if added > 0 {
            SavedProfilesStore.save(saved)
            result = "Imported \(added) profile\(added == 1 ? "" : "s")"
        }
    }
}
