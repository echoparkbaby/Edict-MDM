import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Edict MDM configuration-profile library — the center pane for the
/// sidebar's Device Management → Profiles row. Pick a template, fill a
/// form, choose which enrolled Macs to push it to, and Edict builds the
/// .mobileconfig and sends it via the InstallProfile command. No XML.
struct ProfilesView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(ActivityLog.self) private var activity

    enum Template: String, CaseIterable, Identifiable {
        case fileVault = "FileVault Encryption"
        case firewall = "Firewall"
        case softwareUpdate = "Software Update"
        case screenLock = "Screen Lock"
        case restrictions = "Restrictions"
        case gatekeeper = "Gatekeeper"
        case loginWindow = "Login Window"
        case certificate = "Root Certificate"
        case pppc = "Privacy (PPPC)"
        case singleApp = "Single App Mode"
        case notifications = "Notifications"
        case webFilter = "Web Content Filter"
        case calDAV = "Calendar (CalDAV)"
        case cardDAV = "Contacts (CardDAV)"
        case associatedDomains = "Associated Domains"
        case munki = "Munki (BlueConnect)"
        case timeMachine = "Time Machine"
        case dns = "Encrypted DNS"
        case dock = "Dock"
        case finder = "Finder"
        case kext = "Kernel Extensions"
        case wifi = "Wi-Fi Network"
        case passcode = "Password Policy"
        case custom = "Custom Profile"
        var id: String { rawValue }
        /// Which Apple platforms this template applies to (shown as a badge).
        var platforms: String {
            switch self {
            case .wifi, .certificate, .dns, .restrictions: return "macOS · iOS · tvOS"
            case .passcode: return "macOS · iOS"
            case .singleApp: return "iOS · tvOS"
            case .notifications, .webFilter, .calDAV, .cardDAV: return "macOS · iOS"
            case .associatedDomains: return "macOS · iOS · tvOS"
            case .custom: return "any"
            default: return "macOS"
            }
        }
        var icon: String {
            switch self {
            case .fileVault: return "lock.shield"
            case .firewall: return "firewall"
            case .softwareUpdate: return "arrow.triangle.2.circlepath"
            case .screenLock: return "lock.display"
            case .restrictions: return "hand.raised"
            case .gatekeeper: return "checkmark.shield"
            case .loginWindow: return "person.crop.rectangle"
            case .certificate: return "seal"
            case .pppc: return "hand.raised.circle"
            case .singleApp: return "apps.iphone"
            case .notifications: return "bell.badge"
            case .webFilter: return "globe.badge.chevron.backward"
            case .calDAV: return "calendar"
            case .cardDAV: return "person.crop.square.filled.and.at.rectangle"
            case .associatedDomains: return "link.circle"
            case .munki: return "shippingbox"
            case .timeMachine: return "clock.arrow.circlepath"
            case .dns: return "network.badge.shield.half.filled"
            case .dock: return "dock.rectangle"
            case .finder: return "macwindow"
            case .kext: return "puzzlepiece.extension"
            case .wifi: return "wifi"
            case .passcode: return "lock.rectangle"
            case .custom: return "doc.text"
            }
        }
        var blurb: String {
            switch self {
            case .fileVault: return "Force-enable disk encryption and escrow the recovery key."
            case .firewall: return "Turn on the application firewall, with stealth mode."
            case .softwareUpdate: return "Automatic update checks, downloads, and installs."
            case .screenLock: return "Require the password after the screen saver or sleep."
            case .restrictions: return "Disable AirDrop, Erase All Content, Game Center, App installs."
            case .gatekeeper: return "Only allow signed apps to run; App Store + identified developers."
            case .loginWindow: return "Harden the login window — disable guest, hide admin users."
            case .certificate: return "Install and trust a root CA from a pasted PEM certificate."
            case .pppc: return "Pre-grant an app Full Disk Access, Accessibility, Screen Recording, etc."
            case .singleApp: return "Lock a device to one app — kiosk mode for Apple TV / iPad."
            case .notifications: return "Control an app's notification behavior — alerts, sounds, lock screen."
            case .webFilter: return "Built-in web content filter with allow / block URL lists."
            case .calDAV: return "Calendar account (CalDAV) pushed to the device."
            case .cardDAV: return "Contacts account (CardDAV) pushed to the device."
            case .associatedDomains: return "Associate an app with web domains (universal links)."
            case .munki: return "Point the Mac at your BlueConnect Munki repo for managed software."
            case .timeMachine: return "Managed Time Machine backup destination and schedule."
            case .dns: return "Encrypted DNS (DoH/DoT) — route lookups through a private resolver."
            case .dock: return "Dock position, size, auto-hide, recents."
            case .finder: return "Show drives on the desktop, reveal hidden files, trash warnings."
            case .kext: return "Allow third-party kernel extensions by developer Team ID."
            case .wifi: return "Auto-join Wi-Fi network pushed to the Mac's system store."
            case .passcode: return "Login password requirements (length, complexity, lock timeout)."
            case .custom: return "Paste or drag in any .mobileconfig — covers every payload type."
            }
        }
    }

    @State private var template: Template = .fileVault

    // FileVault
    @State private var fvDefer = true
    // Firewall
    @State private var fwBlockAll = false
    @State private var fwStealth = true
    // Software Update
    @State private var suAutoDownload = true
    @State private var suAutoInstallOS = false
    @State private var suAutoSecurity = true
    // Screen lock
    @State private var slIdleMinutes = 5
    @State private var slDelaySeconds = 0
    // Restrictions
    @State private var rAllowErase = true
    @State private var rAllowAirDrop = true
    @State private var rAllowGameCenter = true
    @State private var rAllowAppStore = true
    // Gatekeeper
    @State private var gkAllowDevelopers = true
    // Login Window
    @State private var lwDisableGuest = true
    @State private var lwHideAdmins = false
    @State private var lwNamePasswordFields = true
    // Certificate
    @State private var certPEM = ""
    @State private var certName = ""
    // Munki
    @State private var munkiRepoURL = ""
    @State private var munkiClientID = ""
    // Time Machine
    @State private var tmDest = ""
    @State private var tmAuto = true
    @State private var tmAllVolumes = false
    @State private var tmSkipSys = true
    // DNS
    @State private var dnsHTTPS = true
    @State private var dnsServer = ""
    // Dock
    @State private var dockOrientation = "bottom"
    @State private var dockAutohide = false
    @State private var dockTileSize = 48
    @State private var dockRecents = true
    // Finder
    @State private var finderShowDrives = true
    @State private var finderShowAll = false
    @State private var finderWarnTrash = true
    // KEXT
    @State private var kextTeamIDs = ""
    @State private var kextUserOverrides = false
    // PPPC
    @State private var pppcID = ""
    @State private var pppcIsPath = false
    @State private var pppcCodeReq = ""
    @State private var pppcFDA = true
    @State private var pppcAccessibility = false
    @State private var pppcScreen = false
    @State private var pppcInput = false
    @State private var pppcAuth = "Allow"
    // Single App Mode
    @State private var singleAppID = ""
    @State private var singleDisableAutoLock = true
    @State private var singleDisableTouch = false
    // Notifications
    @State private var notifBundleID = ""
    @State private var notifEnabled = true
    @State private var notifAlertType = 2
    @State private var notifSounds = true
    @State private var notifBadges = true
    @State private var notifLockScreen = true
    @State private var notifCenter = true
    @State private var notifCritical = false
    // Web filter
    @State private var wfAutoFilter = false
    @State private var wfAllowed = ""
    @State private var wfBlocked = ""
    // CalDAV / CardDAV
    @State private var davDesc = ""
    @State private var davHost = ""
    @State private var davPort = 0
    @State private var davPrincipal = ""
    @State private var davUser = ""
    @State private var davSSL = true
    // Associated domains
    @State private var assocAppID = ""
    @State private var assocDomains = ""
    // Drag-drop feedback
    @State private var dropHighlight = false

    // Wi-Fi
    @State private var ssid = ""
    @State private var wifiPassword = ""
    @State private var wifiHidden = false
    @State private var wifiSecurity: ProfilePayloads.WiFiSecurity = .wpa2

    // Passcode
    @State private var minLength = 8
    @State private var requireAlphanumeric = true
    @State private var maxInactivity = 0   // minutes; 0 = none

    // Custom
    @State private var customXML = ""

    // Targets + deploy
    @State private var devices: [MDMEnrollment] = []
    @State private var targetIDs = Set<String>()
    @State private var loadingDevices = false
    @State private var deploying = false
    @State private var result: String?

    // Smart-group targeting
    @Environment(BlueSkyHostListStore.self) private var hostStore
    @State private var targetMode: TargetMode = .selected
    @State private var groupID: UUID?
    @State private var osVersions: [String: String] = [:]
    @State private var fileVault: [String: String] = [:]
    @State private var models: [String: String] = [:]

    enum TargetMode: String, CaseIterable, Identifiable {
        case selected = "Pick devices"
        case group = "Smart group"
        var id: String { rawValue }
    }

    // Saved / favorited profiles
    enum CatalogItem: Hashable { case template(Template); case saved(UUID) }
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

    /// Templates alphabetized; Custom pinned last.
    private var sortedTemplates: [Template] {
        Template.allCases.filter { $0 != .custom }
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
                .onDrop(of: [.fileURL, .data], isTargeted: $dropHighlight) { providers in
                    handleDrop(providers)
                }
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

    private var catalog: some View {
        VStack(spacing: 0) {
            List(selection: $selected) {
                Section("Templates") {
                    ForEach(sortedTemplates) { t in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(t.rawValue)
                                    Text(t.platforms).font(.caption2)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                        .foregroundStyle(.secondary)
                                }
                                Text(t.blurb).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        } icon: { Image(systemName: t.icon) }
                        .tag(CatalogItem.template(t))
                    }
                }
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
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button { importProfiles() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
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
                    formForTemplate
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
                    .disabled(!formValid)
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
                .disabled(deploying || resolvedTargets.isEmpty || !formValid)
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
                        Button(role: .destructive) { deleteSaved(sp) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).help("Delete this saved profile")
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
                .foregroundStyle(result.hasPrefix("Deployed") || result.hasPrefix("Saved") || result.hasPrefix("Imported") ? .green : .orange)
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
                Button("Save") { saveCurrent() }
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

    @ViewBuilder
    private var formForTemplate: some View {
        switch template {
        case .fileVault:
            Form {
                Toggle("Defer until next logout", isOn: $fvDefer)
                Text("Forces FileVault on and escrows the recovery key with the MDM. With defer on, the user is prompted to enable it the next time they log out (the standard, least-disruptive flow).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .firewall:
            Form {
                Toggle("Stealth mode (don't respond to probes)", isOn: $fwStealth)
                Toggle("Block all incoming connections", isOn: $fwBlockAll)
            }
            .formStyle(.columns)
        case .softwareUpdate:
            Form {
                Toggle("Download updates automatically", isOn: $suAutoDownload)
                Toggle("Install macOS updates automatically", isOn: $suAutoInstallOS)
                Toggle("Install security responses & system files", isOn: $suAutoSecurity)
            }
            .formStyle(.columns)
        case .screenLock:
            Form {
                Stepper("Start screen saver after \(slIdleMinutes) min", value: $slIdleMinutes, in: 1...60)
                Stepper(slDelaySeconds == 0 ? "Require password immediately"
                        : "Require password after \(slDelaySeconds)s",
                        value: $slDelaySeconds, in: 0...300, step: 15)
            }
            .formStyle(.columns)
        case .restrictions:
            Form {
                Toggle("Allow Erase All Content & Settings", isOn: $rAllowErase)
                Toggle("Allow AirDrop", isOn: $rAllowAirDrop)
                Toggle("Allow Game Center", isOn: $rAllowGameCenter)
                Toggle("Allow installing apps", isOn: $rAllowAppStore)
                Text("Turn a switch OFF to restrict it. Anything left on isn't written to the profile.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .gatekeeper:
            Form {
                Toggle("Allow identified developers (not just App Store)", isOn: $gkAllowDevelopers)
                Text("Gatekeeper assessment is always on — only signed, notarized apps run. Turn the switch off to allow App Store apps only.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .loginWindow:
            Form {
                Toggle("Disable guest account", isOn: $lwDisableGuest)
                Toggle("Hide admin users from the list", isOn: $lwHideAdmins)
                Toggle("Show name + password fields (not a user list)", isOn: $lwNamePasswordFields)
            }
            .formStyle(.columns)
        case .certificate:
            VStack(alignment: .leading, spacing: 6) {
                TextField("Certificate name", text: $certName, prompt: Text("Corp Root CA"))
                    .textFieldStyle(.roundedBorder)
                Text("Paste the root CA in PEM form (-----BEGIN CERTIFICATE-----).")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $certPEM)
                    .font(.caption.monospaced())
                    .frame(minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
            }
        case .timeMachine:
            Form {
                TextField("Backup destination URL", text: $tmDest,
                          prompt: Text(verbatim: "smb://nas.local/backups"))
                Toggle("Back up automatically", isOn: $tmAuto)
                Toggle("Back up all volumes", isOn: $tmAllVolumes)
                Toggle("Skip system files", isOn: $tmSkipSys)
            }
            .formStyle(.columns)
        case .dns:
            Form {
                Picker("Protocol", selection: $dnsHTTPS) {
                    Text("DNS over HTTPS").tag(true)
                    Text("DNS over TLS").tag(false)
                }
                TextField(dnsHTTPS ? "Server URL" : "Server name", text: $dnsServer,
                          prompt: Text(dnsHTTPS ? "https://dns.example.com/dns-query" : "dns.example.com"))
            }
            .formStyle(.columns)
        case .dock:
            Form {
                Picker("Position", selection: $dockOrientation) {
                    Text("Bottom").tag("bottom"); Text("Left").tag("left"); Text("Right").tag("right")
                }
                Toggle("Auto-hide", isOn: $dockAutohide)
                Stepper("Icon size: \(dockTileSize)", value: $dockTileSize, in: 16...128, step: 4)
                Toggle("Show recent apps", isOn: $dockRecents)
            }
            .formStyle(.columns)
        case .finder:
            Form {
                Toggle("Show drives on the desktop", isOn: $finderShowDrives)
                Toggle("Show hidden files", isOn: $finderShowAll)
                Toggle("Warn before emptying Trash", isOn: $finderWarnTrash)
            }
            .formStyle(.columns)
        case .kext:
            Form {
                TextField("Allowed Team IDs (comma-separated)", text: $kextTeamIDs,
                          prompt: Text("ABCDE12345, FGHIJ67890"))
                Toggle("Allow users to approve more", isOn: $kextUserOverrides)
                Text("Pre-approves kernel extensions from these developer Team IDs so security tools and drivers load without a user prompt.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .pppc:
            Form {
                TextField(pppcIsPath ? "App path" : "App bundle ID", text: $pppcID,
                          prompt: Text(pppcIsPath ? "/Applications/App.app" : "com.example.app"))
                Picker("Identifier type", selection: $pppcIsPath) {
                    Text("Bundle ID").tag(false); Text("Path").tag(true)
                }
                Picker("Authorization", selection: $pppcAuth) {
                    Text("Allow").tag("Allow")
                    Text("Allow (user can change)").tag("AllowStandardUserToSetSystemService")
                    Text("Deny").tag("Deny")
                }
                Toggle("Full Disk Access", isOn: $pppcFDA)
                Toggle("Accessibility", isOn: $pppcAccessibility)
                Toggle("Screen Recording", isOn: $pppcScreen)
                Toggle("Input Monitoring", isOn: $pppcInput)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Code requirement").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $pppcCodeReq)
                        .font(.caption2.monospaced()).frame(minHeight: 60)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                    Text("Required. Get it with:  codesign -dr - /Applications/App.app  (copy the line after “designated => ”).")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.columns)
        case .singleApp:
            Form {
                TextField("App bundle ID", text: $singleAppID, prompt: Text("com.apple.TVRemote"))
                Toggle("Disable auto-lock", isOn: $singleDisableAutoLock)
                Toggle("Disable touch", isOn: $singleDisableTouch)
                Text("Locks the device to this one app (autonomous single-app / kiosk mode). For Apple TV or a dedicated iPad.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .notifications:
            Form {
                TextField("App bundle ID", text: $notifBundleID, prompt: Text("com.apple.Safari"))
                Toggle("Notifications enabled", isOn: $notifEnabled)
                Picker("Alert style", selection: $notifAlertType) {
                    Text("None").tag(0); Text("Banner").tag(1); Text("Persistent alert").tag(2)
                }
                Toggle("Sounds", isOn: $notifSounds)
                Toggle("Badges", isOn: $notifBadges)
                Toggle("Show on lock screen", isOn: $notifLockScreen)
                Toggle("Show in Notification Center", isOn: $notifCenter)
                Toggle("Allow critical alerts", isOn: $notifCritical)
            }
            .formStyle(.columns)
        case .webFilter:
            Form {
                Toggle("Limit adult content (auto filter)", isOn: $wfAutoFilter)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Always allow (one URL per line)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $wfAllowed).font(.caption.monospaced()).frame(minHeight: 60)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Always block (one URL per line)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $wfBlocked).font(.caption.monospaced()).frame(minHeight: 60)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                }
            }
            .formStyle(.columns)
        case .calDAV, .cardDAV:
            Form {
                TextField("Account description", text: $davDesc, prompt: Text("Work Calendar"))
                TextField("Server host", text: $davHost, prompt: Text("dav.example.com"))
                TextField("Principal URL (optional)", text: $davPrincipal, prompt: Text("/principals/users/me/"))
                TextField("Username (optional)", text: $davUser)
                Toggle("Use SSL", isOn: $davSSL)
                Text("Password isn't stored in the profile — the user is prompted on install. Port auto-detects unless you need a custom one.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .associatedDomains:
            Form {
                TextField("App bundle ID", text: $assocAppID, prompt: Text("com.example.app"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Domains (one per line, e.g. applinks:example.com)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $assocDomains).font(.caption.monospaced()).frame(minHeight: 70)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                }
            }
            .formStyle(.columns)
        case .munki:
            Form {
                HStack {
                    TextField("Munki repo URL", text: $munkiRepoURL,
                              prompt: Text(verbatim: "https://munki.example.com/repo"))
                    if !settings.munkiRepoEndpoint.isEmpty {
                        Button("Use BlueConnect") { munkiRepoURL = settings.munkiRepoEndpoint }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                TextField("Client identifier (optional)", text: $munkiClientID,
                          prompt: Text("manifest name"))
                Text("Sets ManagedInstalls SoftwareRepoURL so enrolled Macs pull managed software from your BlueConnect Munki repo. The Munki tools must be installed on the Mac (deploy them via Munki bootstrap or a package).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .wifi:
            Form {
                TextField("Network name (SSID)", text: $ssid)
                Picker("Security", selection: $wifiSecurity) {
                    ForEach(ProfilePayloads.WiFiSecurity.allCases) { Text($0.rawValue).tag($0) }
                }
                if wifiSecurity.needsPassword {
                    SecureField("Password", text: $wifiPassword)
                }
                Toggle("Hidden network", isOn: $wifiHidden)
            }
            .formStyle(.columns)
        case .passcode:
            Form {
                Stepper("Minimum length: \(minLength)", value: $minLength, in: 4...64)
                Toggle("Require letters and numbers", isOn: $requireAlphanumeric)
                Stepper(maxInactivity == 0 ? "Auto-lock: off"
                        : "Auto-lock after \(maxInactivity) min",
                        value: $maxInactivity, in: 0...60, step: 5)
            }
            .formStyle(.columns)
        case .custom:
            VStack(alignment: .leading, spacing: 6) {
                Text("Paste a .mobileconfig (XML). It must be a Configuration profile.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $customXML)
                    .font(.caption.monospaced())
                    .frame(minHeight: 200)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
            }
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
                Spacer()
                if loadingDevices { ProgressView().controlSize(.small) }
            }
            if targetMode == .selected {
                HStack {
                    Spacer()
                    Button(targetIDs.count == devices.count ? "None" : "All") {
                        targetIDs = targetIDs.count == devices.count ? [] : Set(devices.map(\.id))
                    }
                    .font(.caption).buttonStyle(.link)
                }
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
                        Text("\(groupMembers(g).count) member\(groupMembers(g).count == 1 ? "" : "s") match right now. Membership re-evaluates each deploy.")
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

    private func bscMatched(_ d: MDMEnrollment) -> Bool {
        guard let serial = d.serialNumber, !serial.isEmpty else { return false }
        return hostStore.hosts.contains { ($0.serialnum ?? "").caseInsensitiveCompare(serial) == .orderedSame }
    }

    private func groupMembers(_ g: SmartGroup) -> [MDMEnrollment] {
        devices.filter { g.contains(deviceFacts($0),
                                    requireFileVault: settings.mdmRequireFileVault,
                                    minOS: settings.mdmMinOSVersion) }
    }

    private func deviceLabel(_ d: MDMEnrollment) -> String {
        if let stored = settings.mdmDevices.first(where: { $0.id == d.id })?.label, !stored.isEmpty {
            return stored
        }
        return d.serialNumber ?? String(d.id.prefix(8))
    }

    private var formValid: Bool {
        switch template {
        case .wifi: return !ssid.trimmingCharacters(in: .whitespaces).isEmpty
        case .custom: return !customXML.trimmingCharacters(in: .whitespaces).isEmpty
        case .certificate: return certPEM.contains("BEGIN CERTIFICATE")
        case .munki: return !munkiRepoURL.trimmingCharacters(in: .whitespaces).isEmpty
        case .dns: return !dnsServer.trimmingCharacters(in: .whitespaces).isEmpty
        case .singleApp: return !singleAppID.trimmingCharacters(in: .whitespaces).isEmpty
        case .notifications: return !notifBundleID.trimmingCharacters(in: .whitespaces).isEmpty
        case .calDAV, .cardDAV:
            return !davDesc.trimmingCharacters(in: .whitespaces).isEmpty
                && !davHost.trimmingCharacters(in: .whitespaces).isEmpty
        case .associatedDomains:
            return !assocAppID.trimmingCharacters(in: .whitespaces).isEmpty
                && !assocDomains.trimmingCharacters(in: .whitespaces).isEmpty
        case .pppc:
            return !pppcID.trimmingCharacters(in: .whitespaces).isEmpty
                && !pppcCodeReq.trimmingCharacters(in: .whitespaces).isEmpty
                && (pppcFDA || pppcAccessibility || pppcScreen || pppcInput)
        default: return true
        }
    }

    private func buildProfile() throws -> (data: Data, name: String) {
        switch template {
        case .fileVault:
            return (ProfilePayloads.fileVault(deferEnable: fvDefer), "FileVault")
        case .firewall:
            return (ProfilePayloads.firewall(blockAllIncoming: fwBlockAll, stealthMode: fwStealth), "Firewall")
        case .softwareUpdate:
            return (ProfilePayloads.softwareUpdate(autoCheck: true, autoDownload: suAutoDownload,
                                                   autoInstallOS: suAutoInstallOS,
                                                   autoInstallSecurity: suAutoSecurity), "Software Update")
        case .screenLock:
            return (ProfilePayloads.screenLock(idleSeconds: slIdleMinutes * 60,
                                               delaySeconds: slDelaySeconds), "Screen Lock")
        case .restrictions:
            return (ProfilePayloads.restrictions(allowEraseAllContent: rAllowErase,
                                                 allowAirDrop: rAllowAirDrop,
                                                 allowGameCenter: rAllowGameCenter,
                                                 allowAppStore: rAllowAppStore), "Restrictions")
        case .gatekeeper:
            return (ProfilePayloads.gatekeeper(allowIdentifiedDevelopers: gkAllowDevelopers), "Gatekeeper")
        case .loginWindow:
            return (ProfilePayloads.loginWindow(disableGuest: lwDisableGuest,
                                                hideAdminUsers: lwHideAdmins,
                                                showNamePasswordFields: lwNamePasswordFields), "Login Window")
        case .certificate:
            return (try ProfilePayloads.rootCertificate(pem: certPEM, name: certName), "Certificate")
        case .munki:
            return (ProfilePayloads.munki(repoURL: munkiRepoURL.trimmingCharacters(in: .whitespaces),
                                          clientIdentifier: munkiClientID.trimmingCharacters(in: .whitespaces)),
                    "Munki")
        case .timeMachine:
            return (ProfilePayloads.timeMachine(destinationURL: tmDest.trimmingCharacters(in: .whitespaces),
                                                autoBackup: tmAuto, allVolumes: tmAllVolumes,
                                                skipSystemFiles: tmSkipSys), "Time Machine")
        case .dns:
            return (ProfilePayloads.encryptedDNS(useHTTPS: dnsHTTPS,
                                                 server: dnsServer.trimmingCharacters(in: .whitespaces)), "Encrypted DNS")
        case .dock:
            return (ProfilePayloads.dock(orientation: dockOrientation, autohide: dockAutohide,
                                         tileSize: dockTileSize, showRecents: dockRecents), "Dock")
        case .finder:
            return (ProfilePayloads.finder(showDrivesOnDesktop: finderShowDrives,
                                           showAllFiles: finderShowAll,
                                           warnOnEmptyTrash: finderWarnTrash), "Finder")
        case .kext:
            let teams = kextTeamIDs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return (ProfilePayloads.kernelExtensions(teamIdentifiers: teams,
                                                     allowUserOverrides: kextUserOverrides), "Kernel Extensions")
        case .pppc:
            var services: [String] = []
            if pppcFDA { services.append("SystemPolicyAllFiles") }
            if pppcAccessibility { services.append("Accessibility") }
            if pppcScreen { services.append("ScreenCapture") }
            if pppcInput { services.append("ListenEvent") }
            return (ProfilePayloads.pppc(identifier: pppcID.trimmingCharacters(in: .whitespaces),
                                         identifierType: pppcIsPath ? "path" : "bundleID",
                                         codeRequirement: pppcCodeReq.trimmingCharacters(in: .whitespaces),
                                         services: services, authorization: pppcAuth), "Privacy (PPPC)")
        case .singleApp:
            return (ProfilePayloads.singleAppMode(bundleID: singleAppID.trimmingCharacters(in: .whitespaces),
                                                  disableAutoLock: singleDisableAutoLock,
                                                  disableTouch: singleDisableTouch), "Single App Mode")
        case .notifications:
            return (ProfilePayloads.notifications(bundleID: notifBundleID.trimmingCharacters(in: .whitespaces),
                                                  enabled: notifEnabled, alertType: notifAlertType,
                                                  sounds: notifSounds, badges: notifBadges,
                                                  lockScreen: notifLockScreen, notificationCenter: notifCenter,
                                                  critical: notifCritical), "Notifications")
        case .webFilter:
            let allow = wfAllowed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let block = wfBlocked.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return (ProfilePayloads.webFilter(autoFilter: wfAutoFilter, allowedURLs: allow, blockedURLs: block), "Web Content Filter")
        case .calDAV:
            return (ProfilePayloads.calDAV(description: davDesc.trimmingCharacters(in: .whitespaces),
                                           host: davHost.trimmingCharacters(in: .whitespaces),
                                           port: davPort,
                                           principalURL: davPrincipal.trimmingCharacters(in: .whitespaces),
                                           username: davUser.trimmingCharacters(in: .whitespaces),
                                           useSSL: davSSL), "CalDAV: \(davDesc)")
        case .cardDAV:
            return (ProfilePayloads.cardDAV(description: davDesc.trimmingCharacters(in: .whitespaces),
                                            host: davHost.trimmingCharacters(in: .whitespaces),
                                            port: davPort,
                                            principalURL: davPrincipal.trimmingCharacters(in: .whitespaces),
                                            username: davUser.trimmingCharacters(in: .whitespaces),
                                            useSSL: davSSL), "CardDAV: \(davDesc)")
        case .associatedDomains:
            let domains = assocDomains.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return (ProfilePayloads.associatedDomains(appID: assocAppID.trimmingCharacters(in: .whitespaces),
                                                      domains: domains), "Associated Domains: \(assocAppID)")
        case .wifi:
            return (ProfilePayloads.wifi(ssid: ssid, password: wifiPassword,
                                         hidden: wifiHidden, security: wifiSecurity),
                    "Wi-Fi “\(ssid)”")
        case .passcode:
            return (ProfilePayloads.passcode(minLength: minLength,
                                             requireAlphanumeric: requireAlphanumeric,
                                             maxInactivityMinutes: maxInactivity == 0 ? nil : maxInactivity),
                    "Password Policy")
        case .custom:
            return (try ProfilePayloads.custom(xml: customXML), "Custom profile")
        }
    }

    /// Accept a dropped .mobileconfig: load its XML into the Custom
    /// template so it can be reviewed and deployed.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                customXML = text
                template = .custom
                result = "Loaded \(url.lastPathComponent) — review and deploy."
            }
        }
        return true
    }

    @MainActor
    private func loadDevices() async {
        guard settings.mdmEnabled, settings.mdmConfigured,
              !settings.mdmDevicesAPIBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        loadingDevices = true
        defer { loadingDevices = false }
        devices = (try? await EnrollmentsAPI(settings: settings).list().filter(\.isDevice)) ?? []
        // Facts for smart-group membership.
        let svc = KMFDDMService(settings: settings)
        var os: [String: String] = [:], fv: [String: String] = [:], mdl: [String: String] = [:]
        for d in devices {
            if let v = try? await svc.statusValues(enrollmentID: d.id, pathPrefix: ".StatusItems.device.operating-system.version").first?.value { os[d.id] = v }
            if let v = try? await svc.statusValues(enrollmentID: d.id, pathPrefix: ".StatusItems.diskmanagement.filevault.enabled").first?.value { fv[d.id] = v }
            if let v = try? await svc.statusValues(enrollmentID: d.id, pathPrefix: ".StatusItems.device.model.marketing-name").first?.value { mdl[d.id] = v }
        }
        osVersions = os; fileVault = fv; models = mdl
    }

    /// Build the current template and deploy it.
    @MainActor
    private func deployBuilt() async {
        let built: (data: Data, name: String)
        do { built = try buildProfile() }
        catch { result = "Couldn't build profile: \(error.localizedDescription)"; return }
        await deploy(data: built.data, name: built.name)
    }

    /// Build the template, then run it through the diff gate.
    @MainActor
    private func attemptDeployBuilt() async {
        let built: (data: Data, name: String)
        do { built = try buildProfile() }
        catch { result = "Couldn't build profile: \(error.localizedDescription)"; return }
        await attemptDeploy(data: built.data, name: built.name)
    }

    /// If any target already has a profile with this identifier (per the
    /// deployment log), show a diff sheet first; otherwise deploy straight
    /// away. The diff compares the last bytes Edict sent against the new
    /// ones, so the operator sees exactly what this push will change.
    @MainActor
    private func attemptDeploy(data: Data, name: String) async {
        guard let newID = DeploymentLog.payloadIdentifier(data) else {
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
            let changes = ProfileDiff.compare(old: newest.data, new: data)
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
        DeploymentLog.record(profileData: data, name: name, to: deployedTo,
                             nowEpoch: Date().timeIntervalSince1970)
        result = failed == 0
            ? "Deployed \(name) to \(ok) device\(ok == 1 ? "" : "s")"
            : "Deployed to \(ok), failed \(failed)"
        activity.record(.category, title: "Deployed profile: \(name)",
                        detail: "\(ok) device\(ok == 1 ? "" : "s")" + (failed > 0 ? ", \(failed) failed" : ""))
    }

    // MARK: - Saved profiles

    private func saveCurrent() {
        showingSaveSheet = false
        let built: (data: Data, name: String)
        do { built = try buildProfile() } catch { result = "Couldn't build: \(error.localizedDescription)"; return }
        let desc = SavedProfilesStore.describe(built.data, fallbackName: saveName)
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

    private func importProfiles() {
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
            let desc = SavedProfilesStore.describe(data, fallbackName: url.deletingPathExtension().lastPathComponent)
            saved.append(SavedProfile(name: desc.name, data: data, favorite: true, summary: desc.summary))
            added += 1
        }
        if added > 0 {
            SavedProfilesStore.save(saved)
            result = "Imported \(added) profile\(added == 1 ? "" : "s")"
        }
    }
}
