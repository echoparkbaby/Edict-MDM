import SwiftUI

/// The editable form for one profile template — the big per-template switch
/// that used to live inline in `ProfilesView`. Binds to a shared
/// `ProfileFormState`; the parent reads it back to build/validate.
struct TemplateFormView: View {
    let template: ProfileTemplate
    @Binding var form: ProfileFormState
    @EnvironmentObject private var settings: SettingsStore

    @ViewBuilder
    var body: some View {
        switch template {
        case .fileVault:
            Form {
                Toggle("Defer until next logout", isOn: $form.fvDefer)
                Text("Forces FileVault on and escrows the recovery key with the MDM. With defer on, the user is prompted to enable it the next time they log out (the standard, least-disruptive flow).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .firewall:
            Form {
                Toggle("Stealth mode (don't respond to probes)", isOn: $form.fwStealth)
                Toggle("Block all incoming connections", isOn: $form.fwBlockAll)
            }
            .formStyle(.columns)
        case .softwareUpdate:
            Form {
                Toggle("Download updates automatically", isOn: $form.suAutoDownload)
                Toggle("Install macOS updates automatically", isOn: $form.suAutoInstallOS)
                Toggle("Install security responses & system files", isOn: $form.suAutoSecurity)
            }
            .formStyle(.columns)
        case .screenLock:
            Form {
                Stepper("Start screen saver after \(form.slIdleMinutes) min", value: $form.slIdleMinutes, in: 1...60)
                Stepper(form.slDelaySeconds == 0 ? "Require password immediately"
                        : "Require password after \(form.slDelaySeconds)s",
                        value: $form.slDelaySeconds, in: 0...300, step: 15)
            }
            .formStyle(.columns)
        case .restrictions:
            Form {
                Toggle("Allow Erase All Content & Settings", isOn: $form.rAllowErase)
                Toggle("Allow AirDrop", isOn: $form.rAllowAirDrop)
                Toggle("Allow Game Center", isOn: $form.rAllowGameCenter)
                Toggle("Allow installing apps", isOn: $form.rAllowAppStore)
                Text("Turn a switch OFF to restrict it. Anything left on isn't written to the profile.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .gatekeeper:
            Form {
                Toggle("Allow identified developers (not just App Store)", isOn: $form.gkAllowDevelopers)
                Text("Gatekeeper assessment is always on — only signed, notarized apps run. Turn the switch off to allow App Store apps only.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .loginWindow:
            Form {
                Toggle("Disable guest account", isOn: $form.lwDisableGuest)
                Toggle("Hide admin users from the list", isOn: $form.lwHideAdmins)
                Toggle("Show name + password fields (not a user list)", isOn: $form.lwNamePasswordFields)
            }
            .formStyle(.columns)
        case .certificate:
            VStack(alignment: .leading, spacing: 6) {
                TextField("Certificate name", text: $form.certName, prompt: Text("Corp Root CA"))
                    .textFieldStyle(.roundedBorder)
                Text("Paste the root CA in PEM form (-----BEGIN CERTIFICATE-----).")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $form.certPEM)
                    .font(.caption.monospaced())
                    .frame(minHeight: 160)
                    .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25), lineWidth: 1) }
            }
        case .timeMachine:
            Form {
                TextField("Backup destination URL", text: $form.tmDest,
                          prompt: Text(verbatim: "smb://nas.local/backups"))
                Toggle("Back up automatically", isOn: $form.tmAuto)
                Toggle("Back up all volumes", isOn: $form.tmAllVolumes)
                Toggle("Skip system files", isOn: $form.tmSkipSys)
            }
            .formStyle(.columns)
        case .dns:
            Form {
                Picker("Protocol", selection: $form.dnsHTTPS) {
                    Text("DNS over HTTPS").tag(true)
                    Text("DNS over TLS").tag(false)
                }
                TextField(form.dnsHTTPS ? "Server URL" : "Server name", text: $form.dnsServer,
                          prompt: Text(form.dnsHTTPS ? "https://dns.example.com/dns-query" : "dns.example.com"))
            }
            .formStyle(.columns)
        case .dock:
            Form {
                Picker("Position", selection: $form.dockOrientation) {
                    Text("Bottom").tag("bottom"); Text("Left").tag("left"); Text("Right").tag("right")
                }
                Toggle("Auto-hide", isOn: $form.dockAutohide)
                Stepper("Icon size: \(form.dockTileSize)", value: $form.dockTileSize, in: 16...128, step: 4)
                Toggle("Show recent apps", isOn: $form.dockRecents)
            }
            .formStyle(.columns)
        case .finder:
            Form {
                Toggle("Show drives on the desktop", isOn: $form.finderShowDrives)
                Toggle("Show hidden files", isOn: $form.finderShowAll)
                Toggle("Warn before emptying Trash", isOn: $form.finderWarnTrash)
            }
            .formStyle(.columns)
        case .kext:
            Form {
                TextField("Allowed Team IDs (comma-separated)", text: $form.kextTeamIDs,
                          prompt: Text("ABCDE12345, FGHIJ67890"))
                Toggle("Allow users to approve more", isOn: $form.kextUserOverrides)
                Text("Pre-approves kernel extensions from these developer Team IDs so security tools and drivers load without a user prompt.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .pppc:
            Form {
                TextField(form.pppcIsPath ? "App path" : "App bundle ID", text: $form.pppcID,
                          prompt: Text(form.pppcIsPath ? "/Applications/App.app" : "com.example.app"))
                Picker("Identifier type", selection: $form.pppcIsPath) {
                    Text("Bundle ID").tag(false); Text("Path").tag(true)
                }
                Picker("Authorization", selection: $form.pppcAuth) {
                    Text("Allow").tag("Allow")
                    Text("Allow (user can change)").tag("AllowStandardUserToSetSystemService")
                    Text("Deny").tag("Deny")
                }
                Toggle("Full Disk Access", isOn: $form.pppcFDA)
                Toggle("Accessibility", isOn: $form.pppcAccessibility)
                Toggle("Screen Recording", isOn: $form.pppcScreen)
                Toggle("Input Monitoring", isOn: $form.pppcInput)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Code requirement").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $form.pppcCodeReq)
                        .font(.caption2.monospaced()).frame(minHeight: 60)
                        .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25), lineWidth: 1) }
                    Text("Required. Get it with:  codesign -dr - /Applications/App.app  (copy the line after “designated => ”).")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.columns)
        case .singleApp:
            Form {
                TextField("App bundle ID", text: $form.singleAppID, prompt: Text("com.apple.TVRemote"))
                Toggle("Disable auto-lock", isOn: $form.singleDisableAutoLock)
                Toggle("Disable touch", isOn: $form.singleDisableTouch)
                Text("Locks the device to this one app (autonomous single-app / kiosk mode). For Apple TV or a dedicated iPad.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .notifications:
            Form {
                TextField("App bundle ID", text: $form.notifBundleID, prompt: Text("com.apple.Safari"))
                HStack {
                    Button("Deliver quietly") {
                        form.notifEnabled = true; form.notifAlertType = 0
                        form.notifSounds = false; form.notifBadges = false
                        form.notifLockScreen = false; form.notifCenter = true; form.notifCritical = false
                    }
                    .help("Silence this app's banners and sounds — warnings still land in Notification Center but never pop an alert. Good for chatty background agents.")
                    Button("Silence completely") {
                        form.notifEnabled = false; form.notifAlertType = 0
                        form.notifSounds = false; form.notifBadges = false
                        form.notifLockScreen = false; form.notifCenter = false; form.notifCritical = false
                    }
                    .help("Turn the app's notifications off entirely.")
                }
                Toggle("Notifications enabled", isOn: $form.notifEnabled)
                Picker("Alert style", selection: $form.notifAlertType) {
                    Text("None").tag(0); Text("Banner").tag(1); Text("Persistent alert").tag(2)
                }
                .disabled(!form.notifEnabled)
                Toggle("Sounds", isOn: $form.notifSounds).disabled(!form.notifEnabled)
                Toggle("Badges", isOn: $form.notifBadges).disabled(!form.notifEnabled)
                Toggle("Show on lock screen", isOn: $form.notifLockScreen).disabled(!form.notifEnabled)
                Toggle("Show in Notification Center", isOn: $form.notifCenter).disabled(!form.notifEnabled)
                Toggle("Allow critical alerts", isOn: $form.notifCritical).disabled(!form.notifEnabled)
                Text("“Deliver quietly” keeps the app running normally but stops its warning banners and sounds from interrupting. Requires the app's bundle ID (find it with the app's Info.plist or `osascript -e 'id of app \"Name\"'`).")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .webFilter:
            Form {
                Toggle("Limit adult content (auto filter)", isOn: $form.wfAutoFilter)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Always allow (one URL per line)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $form.wfAllowed).font(.caption.monospaced()).frame(minHeight: 60)
                        .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25), lineWidth: 1) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Always block (one URL per line)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $form.wfBlocked).font(.caption.monospaced()).frame(minHeight: 60)
                        .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25), lineWidth: 1) }
                }
            }
            .formStyle(.columns)
        case .calDAV, .cardDAV:
            Form {
                TextField("Account description", text: $form.davDesc, prompt: Text("Work Calendar"))
                TextField("Server host", text: $form.davHost, prompt: Text("dav.example.com"))
                TextField("Principal URL (optional)", text: $form.davPrincipal, prompt: Text("/principals/users/me/"))
                TextField("Username (optional)", text: $form.davUser)
                Toggle("Use SSL", isOn: $form.davSSL)
                Text("Password isn't stored in the profile — the user is prompted on install. Port auto-detects unless you need a custom one.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .platformSSO:
            Form {
                Picker("Identity provider", selection: $form.ssoVendor) {
                    ForEach(ProfilePayloads.SSOVendor.allCases) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: form.ssoVendor) { _, v in
                    if v != .custom {
                        form.ssoExtensionID = v.extensionID
                        form.ssoTeamID = v.teamID
                        form.ssoURLs = v.urls.joined(separator: "\n")
                    }
                }
                TextField("Extension identifier", text: $form.ssoExtensionID)
                TextField("Team identifier", text: $form.ssoTeamID)
                Picker("Authentication", selection: $form.ssoAuthMethod) {
                    Text("Secure Enclave key (passwordless)").tag("UserSecureEnclaveKey")
                    Text("Password").tag("Password")
                    Text("Smart Card").tag("SmartCard")
                }
                Toggle("Share device keys across users", isOn: $form.ssoSharedKeys)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Redirect URLs (one per line)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $form.ssoURLs).font(.caption.monospaced()).frame(minHeight: 70)
                        .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25), lineWidth: 1) }
                }
                Text("macOS 13+. The IdP's SSO extension app (Company Portal for Entra, Okta Verify for Okta) must be installed separately — push it with Munki. For Okta, replace example.okta.com with your tenant.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .mail:
            Form {
                TextField("Account description", text: $form.mailDesc, prompt: Text("Work Mail"))
                TextField("Email address", text: $form.mailAddress, prompt: Text("user@example.com"))
                TextField("Mail server", text: $form.mailHost, prompt: Text("mail.example.com"))
                TextField("Username (optional)", text: $form.mailUser)
                Picker("Type", selection: $form.mailIMAP) { Text("IMAP").tag(true); Text("POP").tag(false) }
                Toggle("Use SSL", isOn: $form.mailSSL)
                Text("Password isn't stored — the user is prompted on install. Port auto-detects unless set.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .energy:
            Form {
                Stepper("Display sleep: \(form.energyDisplaySleep == 0 ? "Never" : "\(form.energyDisplaySleep) min")", value: $form.energyDisplaySleep, in: 0...180, step: 5)
                Stepper("System sleep: \(form.energySystemSleep == 0 ? "Never" : "\(form.energySystemSleep) min")", value: $form.energySystemSleep, in: 0...180, step: 5)
                Toggle("Wake on LAN", isOn: $form.energyWakeOnLAN)
                Toggle("Restart after power failure", isOn: $form.energyRestartAfterPower)
            }
            .formStyle(.columns)
        case .safari:
            Form {
                TextField("Homepage URL", text: $form.safariHome, prompt: Text("https://example.com"))
                Toggle("New windows/tabs open to homepage", isOn: $form.safariOpenHome)
                Toggle("Disable private browsing", isOn: $form.safariNoPrivate)
            }
            .formStyle(.columns)
        case .chrome:
            Form {
                TextField("Homepage URL", text: $form.chromeHome, prompt: Text("https://example.com"))
                Toggle("Restore last session on startup", isOn: $form.chromeRestore)
                Toggle("Disable incognito mode", isOn: $form.chromeNoIncognito)
                Text("Applies via Chrome's enterprise policy (com.google.Chrome).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .formStyle(.columns)
        case .screenTime:
            Form {
                Picker("Rating region", selection: $form.stRegion) {
                    Text("United States").tag("us")
                    Text("United Kingdom").tag("gb")
                    Text("Canada").tag("ca")
                    Text("Australia").tag("au")
                    Text("Ireland").tag("ie")
                    Text("Germany").tag("de")
                    Text("France").tag("fr")
                    Text("Japan").tag("jp")
                    Text("New Zealand").tag("nz")
                }
                Picker("Apps", selection: $form.stApps) {
                    Text("Allow all").tag(1000); Text("17+").tag(600); Text("12+").tag(300)
                    Text("9+").tag(200); Text("4+").tag(100); Text("Don't allow").tag(0)
                }
                Picker("Movies", selection: $form.stMovies) {
                    Text("Allow all").tag(1000); Text("NC-17").tag(500); Text("R").tag(400)
                    Text("PG-13").tag(300); Text("PG").tag(200); Text("G").tag(100); Text("Don't allow").tag(0)
                }
                Picker("TV shows", selection: $form.stTV) {
                    Text("Allow all").tag(1000); Text("TV-MA").tag(600); Text("TV-14").tag(500)
                    Text("TV-PG").tag(400); Text("TV-G").tag(300); Text("TV-Y7").tag(200)
                    Text("TV-Y").tag(100); Text("Don't allow").tag(0)
                }
                Toggle("Allow explicit content (music, podcasts, news)", isOn: $form.stExplicit)
                Toggle("Filter explicit language in Siri", isOn: $form.stSiriFilter)
                Toggle("Limit adult websites (built-in web filter)", isOn: $form.stLimitWeb)
                Text("Sets Content & Privacy restrictions. Rating labels are US examples — the level you pick maps to the chosen region's equivalent ratings. Screen Time downtime / app limits aren't profile-deliverable (those are Family Controls only).")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .associatedDomains:
            Form {
                TextField("App bundle ID", text: $form.assocAppID, prompt: Text("com.example.app"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Domains (one per line, e.g. applinks:example.com)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $form.assocDomains).font(.caption.monospaced()).frame(minHeight: 70)
                        .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25), lineWidth: 1) }
                }
            }
            .formStyle(.columns)
        case .munki:
            Form {
                HStack {
                    TextField("Munki repo URL", text: $form.munkiRepoURL,
                              prompt: Text(verbatim: "https://munki.example.com/repo"))
                    if !settings.munkiRepoEndpoint.isEmpty {
                        Button("Use BlueConnect") { form.munkiRepoURL = settings.munkiRepoEndpoint }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                TextField("Client identifier (optional)", text: $form.munkiClientID,
                          prompt: Text("manifest name"))
                Text("Sets ManagedInstalls SoftwareRepoURL so enrolled Macs pull managed software from your BlueConnect Munki repo. The Munki tools must be installed on the Mac (deploy them via Munki bootstrap or a package).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .wifi:
            Form {
                TextField("Network name (SSID)", text: $form.ssid)
                Picker("Security", selection: $form.wifiSecurity) {
                    ForEach(ProfilePayloads.WiFiSecurity.allCases) { Text($0.rawValue).tag($0) }
                }
                if form.wifiSecurity.needsPassword {
                    SecureField("Password", text: $form.wifiPassword)
                }
                Toggle("Hidden network", isOn: $form.wifiHidden)
            }
            .formStyle(.columns)
        case .passcode:
            Form {
                Stepper("Minimum length: \(form.minLength)", value: $form.minLength, in: 4...64)
                Toggle("Require letters and numbers", isOn: $form.requireAlphanumeric)
                Toggle("Disallow simple passwords (repeats / sequences)", isOn: $form.pcDisallowSimple)
                Stepper(form.pcMinComplex == 0 ? "Special characters: none required"
                        : "Require \(form.pcMinComplex) special character\(form.pcMinComplex == 1 ? "" : "s")",
                        value: $form.pcMinComplex, in: 0...4)
                Stepper(form.pcMaxAgeDays == 0 ? "Expiration: never"
                        : "Expire password after \(form.pcMaxAgeDays) days",
                        value: $form.pcMaxAgeDays, in: 0...365, step: 15)
                Stepper(form.pcHistory == 0 ? "Password history: off"
                        : "Block reuse of last \(form.pcHistory)",
                        value: $form.pcHistory, in: 0...20)
                Stepper(form.pcMaxFailed < 2 ? "Lock after failed attempts: off"
                        : "Lock after \(form.pcMaxFailed) failed attempts",
                        value: $form.pcMaxFailed, in: 0...11)
                Stepper(form.maxInactivity == 0 ? "Auto-lock: off"
                        : "Auto-lock after \(form.maxInactivity) min",
                        value: $form.maxInactivity, in: 0...60, step: 5)
                Toggle("Prevent users from removing this profile", isOn: $form.pcPreventRemoval)
                Text("“Prevent removal” locks the profile so it can only be taken off via MDM — a user (even an admin) can't strip the policy in System Settings. It applies to this profile only. Note: a profile sets the rules the password must satisfy; it can't stop a user from changing their own password to another compliant one.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.columns)
        case .custom:
            VStack(alignment: .leading, spacing: 6) {
                Text("Paste a .mobileconfig (XML). It must be a Configuration profile.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $form.customXML)
                    .font(.caption.monospaced())
                    .frame(minHeight: 200)
                    .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25), lineWidth: 1) }
            }
        }
    }
}
