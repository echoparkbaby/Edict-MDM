import Foundation
import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {
    /// Register fallback defaults in `UserDefaults.standard` for keys
    /// that non-SwiftUI code (e.g. `TerminalSession.applyAppearance`)
    /// reads directly. `@AppStorage`'s declared defaults only return
    /// when the SwiftUI property is *read*; they never materialize as
    /// actual stored values, so a `UserDefaults.standard.string(forKey:)`
    /// from outside a view returns nil on a fresh install. Registering
    /// here keeps direct readers and `@AppStorage` consumers in sync.
    init() {
        UserDefaults.standard.register(defaults: [
            "terminalFontName":      "Inconsolata-Regular",
            "terminalFontSize":      14.0,
            "terminalForegroundHex": "#50FA7B",
            "terminalBackgroundHex": "#0F0F0F",
            "terminalCursorHex":     "#FF2734",
        ])
    }
    /// Full URL for the JSON host-list endpoint's *base*. The app appends
    /// `/bs_hosts.json.php` to this. Examples:
    ///   https://bluesky.example.com
    ///   http://10.0.0.10:8095
    /// Empty by default — user fills it in via the LoginView on first launch.
    @AppStorage("apiURL") var apiURL: String = ""
    @AppStorage("apiUsername") var apiUsername: String = "admin"
    /// Loaded from Keychain at runtime; not persisted in UserDefaults.
    @Published var webAdminPass: String = ""

    func loadPasswordFromKeychain() {
        guard !apiUsername.isEmpty else { webAdminPass = ""; return }
        webAdminPass = KeychainHelper.read(account: keychainAccount) ?? ""
    }

    func savePasswordToKeychain() {
        guard !apiUsername.isEmpty else { return }
        KeychainHelper.save(webAdminPass, account: keychainAccount)
    }

    func clearCredentials() {
        KeychainHelper.delete(account: keychainAccount)
        webAdminPass = ""
    }

    private var keychainAccount: String {
        // Per (apiURL + username) so multiple servers can coexist.
        "\(apiURL)|\(apiUsername)"
    }

    /// Host for the SSH ProxyCommand. Often the same machine the API points to.
    @AppStorage("serverFqdn") var serverFqdn: String = ""
    @AppStorage("sshTunnelPort") var sshTunnelPort: Int = 3122
    @AppStorage("adminKeyPath") var adminKeyPath: String = "~/.ssh/bluesky_admin"
    @AppStorage("defaultRemoteUser") var defaultRemoteUser: String = "ladmin"
    /// Title shown on the chat window — both the admin-side panel and
    /// the remote chat client's NSWindow title bar. Default is the
    /// neutral "Tech Support"; admins can override per their voice
    /// ("Brandon", "Computer Help", "Help Desk", etc.).
    @AppStorage("chatWindowTitle") var chatWindowTitle: String = "Tech Support"
    /// Comma-separated CIDRs the network scanner probes when the
    /// operator clicks "Scan" in the sidebar. Defaults to the two
    /// most-common home/SOHO LAN ranges; admins on /22 or odd
    /// subnets can edit. /16 is the smallest prefix accepted (the
    /// scanner refuses /15 and below to keep run time bounded).
    @AppStorage("scanSubnets") var scanSubnets: String = "10.0.0.0/24, 192.168.1.0/24"

    // MARK: - UniFi controller (legacy single-config — see UniFi profiles below)

    /// **Legacy.** Kept only so `migrateLegacyUnifiSettingsIfNeeded`
    /// can read the pre-1.4.x single-controller config one last time
    /// and promote it to the new `unifiProfiles` list. Live UI binds
    /// to `UniFiProfile` fields instead.
    @AppStorage("unifiBaseURL") var unifiBaseURL: String = ""
    /// **Legacy.** See `unifiBaseURL`.
    @AppStorage("unifiSite") var unifiSite: String = "default"
    /// **Legacy.** In-memory mirror of the pre-1.4.x single API key.
    /// Migration moves the Keychain entry to a per-profile account.
    @Published var unifiAPIKey: String = ""

    /// JSON-encoded `[UniFiProfile]`. Hand-rolled rather than a typed
    /// helper because @AppStorage only persists primitives — the
    /// `unifiProfiles` computed property below is the typed accessor.
    @AppStorage("unifiProfiles") private var unifiProfilesRaw: String = "[]"
    /// Empty string when no profile is active (or before migration).
    @AppStorage("activeUnifiProfileID") private var activeUnifiProfileIDRaw: String = ""
    /// One-shot guard so the legacy → profiles migration runs at most
    /// once even across version downgrades. Avoids stomping a freshly
    /// edited profile list if the user later re-runs an old build
    /// that still wrote to the legacy keys.
    @AppStorage("unifiProfilesMigrated") private var unifiProfilesMigrated: Bool = false

    @AppStorage("hideInactive") var hideInactive: Bool = false  // "Active only" filter
    @AppStorage("showOnlyInactive") var showOnlyInactive: Bool = false  // "Inactive only" filter

    // Terminal appearance — SwiftTerm view font + colors. Colors are
    // persisted as RGB hex strings ("#RRGGBB") so they round-trip
    // through @AppStorage's String storage cleanly. The TerminalSession
    // applies these to its LocalProcessTerminalView on init and
    // re-applies them when the user changes them in Settings.
    /// PostScript font name (e.g. "Inconsolata-Regular", "Menlo-Regular").
    /// Empty string → fall back to `NSFont.monospacedSystemFont`. We resolve
    /// at render time so an uninstalled font name silently degrades to the
    /// system mono face instead of crashing.
    // Defaults match the Peppermint preset (near-black background,
    // bright green text, red cursor, Inconsolata 14pt). The green is
    // readable across all four built-in presets (red / bright blue /
    // navy / black backgrounds) so a fresh install or "Reset" lands
    // somewhere usable on every theme.
    @AppStorage("terminalFontName")      var terminalFontName: String = "Inconsolata-Regular"
    @AppStorage("terminalFontSize")      var terminalFontSize: Double = 14.0
    @AppStorage("terminalForegroundHex") var terminalForegroundHex: String = "#50FA7B"
    @AppStorage("terminalBackgroundHex") var terminalBackgroundHex: String = "#0F0F0F"
    @AppStorage("terminalCursorHex")     var terminalCursorHex: String = "#FF2734"

    // Column visibility
    @AppStorage("colShowFavorite") var colShowFavorite: Bool = true
    @AppStorage("colShowActive") var colShowActive: Bool = true
    @AppStorage("colShowID") var colShowID: Bool = true
    @AppStorage("colShowConnect") var colShowConnect: Bool = true
    @AppStorage("colShowUser") var colShowUser: Bool = true
    @AppStorage("colShowRecent") var colShowRecent: Bool = true
    @AppStorage("colShowStatus") var colShowStatus: Bool = true
    @AppStorage("colShowLastSeen") var colShowLastSeen: Bool = true
    @AppStorage("colShowNotes") var colShowNotes: Bool = true

    // Notifications
    @AppStorage("notifyOnStateChange") var notifyOnStateChange: Bool = false

    /// Auto-lock idle timeout in minutes. 0 disables auto-lock.
    /// Only applies when Touch ID is required (otherwise nothing to lock).
    @AppStorage("idleLockMinutes") var idleLockMinutes: Int = 0

    /// Show the Local Network section and run the Bonjour browser. On by
    /// default — turn it off if you don't want the app to discover machines
    /// on your LAN (silences the macOS Local Network privacy prompt too).
    @AppStorage("localNetworkEnabled") var localNetworkEnabled: Bool = true

    /// Show the Tailscale section in the sidebar and poll `tailscale status`.
    /// Off by default — opt in if you actually use the tailnet.
    @AppStorage("tailscaleEnabled") var tailscaleEnabled: Bool = false

    /// JSON-encoded `[String]` of Tailscale peer names that the user has
    /// hidden from the sidebar (machines without the BSC client, iOS,
    /// Windows, Linux peers they don't want to see, etc).
    @AppStorage("hiddenTailscalePeersJSON") var hiddenTailscalePeersJSON: String = "[]"

    var hiddenTailscalePeers: Set<String> {
        get {
            guard let data = hiddenTailscalePeersJSON.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return Set(arr)
        }
        set {
            let arr = Array(newValue).sorted()
            if let data = try? JSONEncoder().encode(arr),
               let s = String(data: data, encoding: .utf8) {
                hiddenTailscalePeersJSON = s
            }
        }
    }

    /// Global default ports used for every Tailscale peer. Per-peer
    /// overrides (below) take precedence. Defaults match macOS Remote
    /// Login (22) and Screen Sharing (5900); set these once if you've
    /// moved sshd / VNC across your fleet uniformly.
    @AppStorage("tailscaleSSHPort") var tailscaleSSHPort: Int = 22
    @AppStorage("tailscaleVNCPort") var tailscaleVNCPort: Int = 5900

    /// Global default remote user for every Tailscale peer. Empty falls
    /// back to `defaultRemoteUser`. Per-peer overrides take precedence.
    @AppStorage("tailscaleDefaultUser") var tailscaleDefaultUser: String = ""

    /// JSON-encoded per-peer port overrides, keyed by Tailscale peer name.
    /// Shape: `{"mahogany": {"ssh": 2222}, "beachwood": {"vnc": 5901}}`.
    /// Missing keys / nil fields fall back to the global defaults above.
    @AppStorage("tailscalePortOverridesJSON") var tailscalePortOverridesJSON: String = "{}"

    var tailscalePortOverrides: [String: PortOverride] {
        get {
            guard let data = tailscalePortOverridesJSON.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: PortOverride].self, from: data)
            else { return [:] }
            return dict
        }
        set {
            // Drop entries that don't actually override anything.
            let pruned = newValue.filter { _, v in v.ssh != nil || v.vnc != nil }
            if let data = try? JSONEncoder().encode(pruned),
               let s = String(data: data, encoding: .utf8) {
                tailscalePortOverridesJSON = s
            }
        }
    }

    /// Resolved SSH port for a given Tailscale peer name (override → global default).
    func tailscaleSSHPort(for peerName: String) -> Int {
        tailscalePortOverrides[peerName]?.ssh ?? tailscaleSSHPort
    }

    /// Resolved VNC port for a given Tailscale peer name (override → global default).
    func tailscaleVNCPort(for peerName: String) -> Int {
        tailscalePortOverrides[peerName]?.vnc ?? tailscaleVNCPort
    }

    /// Resolved remote user for a given Tailscale peer name. Order:
    /// per-peer override → tailscaleDefaultUser → defaultRemoteUser.
    func tailscaleUser(for peerName: String) -> String {
        if let u = tailscalePortOverrides[peerName]?.user, !u.isEmpty {
            return u
        }
        if !tailscaleDefaultUser.isEmpty {
            return tailscaleDefaultUser
        }
        return defaultRemoteUser
    }

    /// HTTPS URL to a package-catalog JSON that powers the Install Package
    /// menu on host rows. See `Models/Package.swift` for the schema.
    /// Empty disables the feature.
    @AppStorage("packageCatalogURL") var packageCatalogURL: String = ""

    /// Picks the protocol used to upload installers to your Package Repo.
    /// One service active at a time. Determines which structured fields
    /// in Settings are read when building the upload target URL.
    @AppStorage("packageRepoService") var packageRepoService: String = "ssh"

    // MARK: SSH / SFTP fields
    /// Raw SCP/SFTP target — `user@host:/path/` or `sftp://user@host:port/path/`.
    @AppStorage("packageUploadSCPPath") var packageUploadSCPPath: String = ""
    /// SSH private key path. Tilde-expanded by `expandedPackageUploadKeyPath`.
    @AppStorage("packageUploadKeyPath") var packageUploadKeyPath: String = "~/.ssh/id_rsa"

    // MARK: FTP / FTPS fields
    @AppStorage("packageRepoFTPHost")   var packageRepoFTPHost: String = ""
    @AppStorage("packageRepoFTPPort")   var packageRepoFTPPort: Int = 21
    @AppStorage("packageRepoFTPUser")   var packageRepoFTPUser: String = ""
    @AppStorage("packageRepoFTPPath")   var packageRepoFTPPath: String = "/"
    @AppStorage("packageRepoFTPSecure") var packageRepoFTPSecure: Bool = false
    /// FTP password loaded from Keychain at runtime; not persisted in UserDefaults.
    @Published var ftpPassword: String = ""

    // MARK: Nextcloud (WebDAV) fields
    @AppStorage("packageRepoNextcloudServer") var packageRepoNextcloudServer: String = ""
    @AppStorage("packageRepoNextcloudUser")   var packageRepoNextcloudUser: String = ""
    @AppStorage("packageRepoNextcloudPath")   var packageRepoNextcloudPath: String = "/"
    /// Nextcloud app password loaded from Keychain at runtime.
    @Published var nextcloudPassword: String = ""

    var expandedPackageUploadKeyPath: String {
        NSString(string: packageUploadKeyPath).expandingTildeInPath
    }

    /// True when the currently-selected service has enough configuration
    /// to attempt an upload. Picker UI dims the Refresh / drop affordances
    /// when this is false.
    var isPackageRepoConfigured: Bool {
        switch packageRepoService {
        case "ftp":
            return !packageRepoFTPHost.isEmpty && !packageRepoFTPUser.isEmpty && !ftpPassword.isEmpty
        case "nextcloud":
            return !packageRepoNextcloudServer.isEmpty
                && !packageRepoNextcloudUser.isEmpty
                && !nextcloudPassword.isEmpty
        default:
            return !packageUploadSCPPath.isEmpty
        }
    }

    /// Resolved upload URL for the active service. Built from the
    /// structured fields (FTP/Nextcloud) or returned verbatim (SSH).
    var packageRepoUploadURL: String {
        switch packageRepoService {
        case "ftp":
            return ftpUploadURL
        case "nextcloud":
            return nextcloudUploadURL
        default:
            return packageUploadSCPPath
        }
    }

    private var ftpUploadURL: String {
        let scheme = packageRepoFTPSecure ? "ftps" : "ftp"
        let portPart = (packageRepoFTPPort > 0 && packageRepoFTPPort != 21)
            ? ":\(packageRepoFTPPort)" : ""
        let user = packageRepoFTPUser
            .addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? packageRepoFTPUser
        let pw = ftpPassword
            .addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? ftpPassword
        var path = packageRepoFTPPath
        if !path.hasPrefix("/") { path = "/" + path }
        if !path.hasSuffix("/") { path += "/" }
        return "\(scheme)://\(user):\(pw)@\(packageRepoFTPHost)\(portPart)\(path)"
    }

    private var nextcloudUploadURL: String {
        var server = packageRepoNextcloudServer
        var scheme = "https"
        if let r = server.range(of: "https://") { server.removeSubrange(r) }
        else if let r = server.range(of: "http://") { scheme = "http"; server.removeSubrange(r) }
        server = server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let user = packageRepoNextcloudUser
            .addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? packageRepoNextcloudUser
        let pw = nextcloudPassword
            .addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? nextcloudPassword
        let userInPath = packageRepoNextcloudUser
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? packageRepoNextcloudUser

        var path = packageRepoNextcloudPath
        if !path.hasPrefix("/") { path = "/" + path }
        if !path.hasSuffix("/") { path += "/" }

        return "\(scheme)://\(user):\(pw)@\(server)/remote.php/dav/files/\(userInPath)\(path)"
    }

    // MARK: Keychain — FTP / Nextcloud passwords

    private static let ftpPasswordAccount = "BlueConnectAdmin.packageRepoFTPPassword"
    private static let nextcloudPasswordAccount = "BlueConnectAdmin.packageRepoNextcloudPassword"

    func loadRepoPasswordsFromKeychain() {
        ftpPassword = KeychainHelper.read(account: Self.ftpPasswordAccount) ?? ""
        nextcloudPassword = KeychainHelper.read(account: Self.nextcloudPasswordAccount) ?? ""
    }

    func saveFTPPassword() {
        KeychainHelper.save(ftpPassword, account: Self.ftpPasswordAccount)
    }

    func saveNextcloudPassword() {
        KeychainHelper.save(nextcloudPassword, account: Self.nextcloudPasswordAccount)
    }

    // MARK: erase-install (Graham Pugh)
    /// Path on the *remote* host to `erase-install.sh`. Default matches
    /// Graham Pugh's standard pkg install location.
    @AppStorage("eraseInstallPath") var eraseInstallPath: String =
        "/Library/Management/erase-install/erase-install.sh"
    /// Flags appended to every erase-install invocation, in addition to
    /// the mode-specific flags chosen in the run sheet.
    @AppStorage("eraseInstallDefaultFlags") var eraseInstallDefaultFlags: String =
        "--min-drive-space=50 --cleanup-after-use --check-power --power-wait-limit 180"

    /// JSON-encoded last-10 erase-install run specs, newest first.
    /// Stored verbatim — the sheet reads + applies, and pushes a new
    /// entry onto the front whenever Run is clicked.
    @AppStorage("eraseInstallRecentRunsJSON") var eraseInstallRecentRunsJSON: String = "[]"

    // MARK: MunkiReport
    /// Root URL of your MunkiReport server (no trailing slash). Used to
    /// build per-host links like `<root>/clients/show/<serial>` when the
    /// user picks "Open in MunkiReport" from the host context menu, and
    /// as the base for the BlueConnect JSON API endpoint.
    @AppStorage("munkiReportURL") var munkiReportURL: String = ""

    /// Bearer token for the standalone blueconnect_api.php JSON endpoint
    /// (server/munkireport-module/blueconnect_api.php). Loaded from
    /// Keychain at runtime; the matching `BLUECONNECT_API_TOKEN` env var
    /// lives on the MR container.
    @Published var munkiReportAPIToken: String = ""

    /// Path appended to `munkiReportURL` to reach the BlueConnect API.
    /// Default works when the PHP file sits at MR's webroot. For setups
    /// where the file is bind-mounted under a subpath (e.g. MR's
    /// `/var/munkireport/public/custom/`), use `custom/blueconnect_api.php`.
    @AppStorage("munkiReportAPIPath") var munkiReportAPIPath: String = "blueconnect_api.php"

    private static let munkiReportTokenAccount = "BlueConnectAdmin.munkiReportAPIToken"

    func loadMunkiReportTokenFromKeychain() {
        munkiReportAPIToken = KeychainHelper.read(account: Self.munkiReportTokenAccount) ?? ""
    }

    func saveMunkiReportTokenToKeychain() {
        KeychainHelper.save(munkiReportAPIToken, account: Self.munkiReportTokenAccount)
    }

    /// True when we have both a URL and a token configured to call the
    /// blueconnect_api.php endpoint. Inventory UI gates on this.
    var isMunkiReportAPIConfigured: Bool {
        !munkiReportURL.isEmpty && !munkiReportAPIToken.isEmpty
    }

    /// JSON-encoded list of `MRSection` rawValues controlling display
    /// order in the inventory pane. Newly-introduced sections (added in
    /// app updates) are appended at the end of the resolved list so
    /// users don't lose access after an upgrade.
    @AppStorage("mrSectionOrder")  private var mrSectionOrderJSON: String  = ""

    /// JSON-encoded list of `MRSection` rawValues the user has hidden
    /// from the inventory pane. Empty default = show everything.
    @AppStorage("mrSectionHidden") private var mrSectionHiddenJSON: String = "[]"

    /// Resolved inventory-section order, with any new-since-last-launch
    /// sections appended at the end so upgrades never drop content.
    var munkiReportSectionOrder: [MRSection] {
        get {
            let stored: [MRSection]
            if let data = mrSectionOrderJSON.data(using: .utf8),
               let raw  = try? JSONDecoder().decode([String].self, from: data) {
                stored = raw.compactMap { MRSection(rawValue: $0) }
            } else {
                stored = []
            }
            // Append anything new to preserve forward-compat.
            let existing = Set(stored)
            let appended = MRSection.defaultOrder.filter { !existing.contains($0) }
            let merged = stored.isEmpty ? MRSection.defaultOrder : (stored + appended)
            return merged
        }
        set {
            let raw = newValue.map(\.rawValue)
            if let data = try? JSONEncoder().encode(raw),
               let s    = String(data: data, encoding: .utf8) {
                mrSectionOrderJSON = s
            }
        }
    }

    /// Set of hidden inventory sections.
    var munkiReportHiddenSections: Set<MRSection> {
        get {
            guard let data = mrSectionHiddenJSON.data(using: .utf8),
                  let raw  = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return Set(raw.compactMap { MRSection(rawValue: $0) })
        }
        set {
            let raw = Array(newValue).map(\.rawValue).sorted()
            if let data = try? JSONEncoder().encode(raw),
               let s    = String(data: data, encoding: .utf8) {
                mrSectionHiddenJSON = s
            }
        }
    }

    func munkiReportSectionIsVisible(_ s: MRSection) -> Bool {
        !munkiReportHiddenSections.contains(s)
    }

    /// Browser-openable URL for the per-host MunkiReport detail page.
    /// `nil` when `munkiReportURL` isn't set or the serial doesn't escape
    /// cleanly. Path is `/clients/detail/<serial>` — the route used by
    /// MunkiReport-PHP 5.x.
    func munkiReportDetailURL(serial: String) -> URL? {
        let base = munkiReportURL
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty,
              let encoded = serial.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              !encoded.isEmpty
        else { return nil }
        return URL(string: "\(base)/clients/detail/\(encoded)")
    }

    // MARK: Munki repo (Wasabi / S3-compatible / proxy-fronted)
    /// Hostname-style endpoint for the Munki repo, e.g.
    /// `munki.macfaqulty.com` or `s3.us-east-1.wasabisys.com`. No scheme.
    @AppStorage("munkiRepoEndpoint") var munkiRepoEndpoint: String = ""
    /// Bucket name. Often empty if the endpoint already IS the bucket
    /// (virtual-hosted style with a CNAME, or a Worker that has the bucket baked in).
    @AppStorage("munkiRepoBucket") var munkiRepoBucket: String = ""
    /// Path inside the bucket that the Munki repo lives under. Common
    /// values: `munki_repo`, `repo`, or empty if the repo is at the bucket
    /// root. The fetcher inserts this between bucket and key, so the
    /// catalogs/all URL ends up `…/<bucket>/<prefix>/catalogs/all`.
    @AppStorage("munkiRepoPrefix") var munkiRepoPrefix: String = ""
    /// Wasabi region, used in the SigV4 credential scope. Ignored in
    /// `.basic` auth mode (the proxy talks to Wasabi on our behalf).
    @AppStorage("munkiRepoRegion") var munkiRepoRegion: String = "us-east-1"

    /// Auth flavour. `.s3` = SigV4 directly to Wasabi/S3. `.basic` = the
    /// repo is fronted by a proxy that wants HTTP Basic Auth (very common
    /// for Cloudflare-Worker-fronted Munki repos — the Worker handles
    /// SigV4 itself). `.both` = passthrough proxy that requires Basic
    /// Auth AND forwards our SigV4 to Wasabi.
    @AppStorage("munkiRepoAuthMode") var munkiRepoAuthMode: String = "s3"

    @AppStorage("munkiRepoAccessKey") var munkiRepoAccessKey: String = ""
    /// Secret key loaded from Keychain at runtime; never written to UserDefaults.
    @Published var munkiRepoSecretKey: String = ""

    @AppStorage("munkiRepoBasicUser") var munkiRepoBasicUser: String = ""
    /// Basic Auth password loaded from Keychain at runtime.
    @Published var munkiRepoBasicPassword: String = ""

    private static let munkiSecretAccount = "BlueConnectAdmin.munkiRepoSecretKey"
    private static let munkiBasicAccount  = "BlueConnectAdmin.munkiRepoBasicPassword"
    private static let unifiAPIKeyAccount = "BlueConnectAdmin.unifiAPIKey"

    func loadUnifiAPIKeyFromKeychain() {
        unifiAPIKey = KeychainHelper.read(account: Self.unifiAPIKeyAccount) ?? ""
        migrateLegacyUnifiSettingsIfNeeded()
    }
    func saveUnifiAPIKeyToKeychain() {
        KeychainHelper.save(unifiAPIKey, account: Self.unifiAPIKeyAccount)
    }

    // MARK: - Edict MDM (NanoMDM + KMFDDM admin APIs)

    /// Master toggle. Gates the Device Management features so a v1.5-style
    /// operator who never touches MDM doesn't see any of it.
    @AppStorage("mdmEnabled") var mdmEnabled: Bool = false
    /// NanoMDM admin API base — reached over the tailnet
    /// (e.g. `http://192.0.2.10:9090`). This is the ADMIN surface, not the
    /// public device-facing `/mdm` checkin URL that enrolled Macs hit.
    @AppStorage("nanoMDMBaseURL") var nanoMDMBaseURL: String = ""
    /// KMFDDM admin API base over the tailnet (e.g. `http://192.0.2.10:9093`).
    @AppStorage("kmfddmBaseURL") var kmfddmBaseURL: String = ""
    /// HTTP Basic API keys, loaded from Keychain at runtime (not @AppStorage).
    @Published var nanoMDMAPIKey: String = ""
    @Published var kmfddmAPIKey: String = ""

    private static let nanoMDMAPIKeyAccount = "EdictMDM.nanoMDMAPIKey"
    private static let kmfddmAPIKeyAccount  = "EdictMDM.kmfddmAPIKey"

    func loadMDMKeysFromKeychain() {
        nanoMDMAPIKey = KeychainHelper.read(account: Self.nanoMDMAPIKeyAccount) ?? ""
        kmfddmAPIKey  = KeychainHelper.read(account: Self.kmfddmAPIKeyAccount) ?? ""
    }
    func setNanoMDMAPIKey(_ key: String) {
        nanoMDMAPIKey = key
        KeychainHelper.save(key, account: Self.nanoMDMAPIKeyAccount)
    }
    func setKMFDDMAPIKey(_ key: String) {
        kmfddmAPIKey = key
        KeychainHelper.save(key, account: Self.kmfddmAPIKeyAccount)
    }
    /// Both halves of the MDM admin config present?
    var mdmConfigured: Bool {
        !nanoMDMBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !kmfddmBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Compliance baseline
    /// The fleet baseline Edict grades each Mac against in the Devices view.
    @AppStorage("mdmRequireFileVault") var mdmRequireFileVault: Bool = false
    @AppStorage("mdmMinOSVersion") var mdmMinOSVersion: String = ""
    /// Whether any rule is set — gates the compliance UI.
    var mdmComplianceConfigured: Bool {
        mdmRequireFileVault || !mdmMinOSVersion.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Scheduled automation tasks. JSON in @AppStorage.
    @AppStorage("mdmScheduledTasksRaw") private var scheduledTasksRaw: String = "[]"
    var scheduledTasks: [ScheduledTask] {
        get {
            guard let data = scheduledTasksRaw.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([ScheduledTask].self, from: data)
            else { return [] }
            return arr
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            scheduledTasksRaw = String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    /// Smart groups (dynamic device groups). JSON in @AppStorage.
    @AppStorage("mdmSmartGroupsRaw") private var smartGroupsRaw: String = "[]"
    var smartGroups: [SmartGroup] {
        get {
            guard let data = smartGroupsRaw.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([SmartGroup].self, from: data)
            else { return [] }
            return arr
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            smartGroupsRaw = String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    /// Saved Prism (fleet-analytics) views — scope + attribute to chart.
    @AppStorage("mdmPrismViewsRaw") private var prismViewsRaw: String = "[]"
    var prismViews: [PrismView] {
        get {
            guard let data = prismViewsRaw.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([PrismView].self, from: data)
            else { return [] }
            return arr
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            prismViewsRaw = String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    // MARK: - Onboarding baseline

    /// When on, a Mac that enrolls AFTER `mdmOnboardingEnabledAt` is
    /// automatically given the baseline (chosen profiles + DDM sets) the next
    /// time Edict refreshes the fleet. Devices that enrolled earlier are left
    /// alone (use the per-device Onboard button for those).
    @AppStorage("mdmOnboardingEnabled") var mdmOnboardingEnabled: Bool = false
    /// Epoch when auto-onboarding was last switched on — the cutoff for
    /// "new" devices, so flipping it on doesn't mass-apply to the whole fleet.
    @AppStorage("mdmOnboardingEnabledAt") var mdmOnboardingEnabledAt: Double = 0

    /// Saved-profile IDs every new Mac should get (InstallProfile).
    @AppStorage("mdmOnboardProfileIDsRaw") private var mdmOnboardProfileIDsRaw: String = "[]"
    var mdmOnboardProfileIDs: [UUID] {
        get { (try? JSONDecoder().decode([UUID].self, from: Data(mdmOnboardProfileIDsRaw.utf8))) ?? [] }
        set { mdmOnboardProfileIDsRaw = String(data: (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]" }
    }

    /// KMFDDM set names every new Mac should be associated with.
    @AppStorage("mdmOnboardSetsRaw") private var mdmOnboardSetsRaw: String = "[]"
    var mdmOnboardSets: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(mdmOnboardSetsRaw.utf8))) ?? [] }
        set { mdmOnboardSetsRaw = String(data: (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]" }
    }

    /// Enrollment IDs already onboarded, so a device is never baselined twice
    /// automatically.
    @AppStorage("mdmOnboardedIDsRaw") private var mdmOnboardedIDsRaw: String = "[]"
    var mdmOnboardedIDs: Set<String> {
        get { Set((try? JSONDecoder().decode([String].self, from: Data(mdmOnboardedIDsRaw.utf8))) ?? []) }
        set { mdmOnboardedIDsRaw = String(data: (try? JSONEncoder().encode(Array(newValue)) ) ?? Data("[]".utf8), encoding: .utf8) ?? "[]" }
    }
    func isOnboarded(_ id: String) -> Bool { mdmOnboardedIDs.contains(id) }
    func markOnboarded(_ id: String) { mdmOnboardedIDs.insert(id) }

    /// True once at least one profile or set is in the baseline.
    var hasOnboardingBaseline: Bool { !mdmOnboardProfileIDs.isEmpty || !mdmOnboardSets.isEmpty }

    /// PayloadIdentifier of the enrollment profile installed on managed
    /// Macs. "Remove from MDM" sends a RemoveProfile for this identifier —
    /// pulling the enrollment profile unenrolls the device.
    @AppStorage("mdmEnrollmentProfileID") var mdmEnrollmentProfileID: String = "xyz.hellocomputer.blueconnectmdm"

    /// Base URL of the enrollments sidecar (read-only list of enrolled
    /// devices straight from NanoMDM's database — NanoMDM itself has no
    /// list API). Same Basic-auth key as NanoMDM. e.g. `http://192.0.2.10:9095`.
    @AppStorage("mdmDevicesAPIBaseURL") var mdmDevicesAPIBaseURL: String = ""

    /// Public, device-facing base URL — the reverse proxy in front of
    /// NanoMDM/SCEP that enrolling Macs reach over the internet
    /// (e.g. `https://mdm.example.com`). Used only to generate
    /// enrollment profiles; `/mdm` and `/scep` are appended.
    @AppStorage("mdmPublicURL") var mdmPublicURL: String = ""
    /// Enrollment-profile personalization (shown to the user installing it).
    @AppStorage("mdmProfileDisplayName") var mdmProfileDisplayName: String = "Edict MDM Enrollment"
    @AppStorage("mdmProfileOrganization") var mdmProfileOrganization: String = ""
    @AppStorage("mdmProfileDescription") var mdmProfileDescription: String = ""
    @AppStorage("mdmProfileConsentText") var mdmProfileConsentText: String = ""

    /// SCEP shared-secret challenge (the `-challenge` the SCEP server
    /// runs with). Goes into the generated enrollment profile. Keychain.
    @Published var scepChallenge: String = ""
    private static let scepChallengeAccount = "EdictMDM.scepChallenge"
    func loadSCEPChallengeFromKeychain() {
        scepChallenge = KeychainHelper.read(account: Self.scepChallengeAccount) ?? ""
    }
    func setSCEPChallenge(_ value: String) {
        scepChallenge = value
        KeychainHelper.save(value, account: Self.scepChallengeAccount)
    }

    /// Devices Edict knows about. NanoMDM has no list-enrollments API,
    /// so the operator registers each enrollment ID once and we keep the
    /// list locally. JSON-encoded [MDMDevice] — same hand-rolled pattern
    /// as unifiProfiles (@AppStorage only persists primitives).
    @AppStorage("mdmDevicesRaw") private var mdmDevicesRaw: String = "[]"

    var mdmDevices: [MDMDevice] {
        get {
            guard let data = mdmDevicesRaw.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([MDMDevice].self, from: data)
            else { return [] }
            return arr
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            mdmDevicesRaw = String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    /// Cache the device-reported computer name (DeviceInformation →
    /// DeviceName) so target lists / synthetic rows show a real name instead
    /// of a serial. Persists via `mdmDevicesRaw`; no-op if unchanged.
    func setMDMDeviceAutoName(_ name: String, for id: String) {
        var list = mdmDevices
        if let idx = list.firstIndex(where: { $0.id == id }) {
            guard list[idx].autoName != name else { return }
            list[idx].autoName = name
        } else {
            list.append(MDMDevice(id: id, label: "", autoName: name))
        }
        mdmDevices = list
    }

    // MARK: - UniFi profiles (multi-controller)

    /// Per-profile Keychain account name. Suffixed by the profile's
    /// UUID so deleting a profile cleanly orphans its key (callers
    /// must `KeychainHelper.delete` after they remove from the list).
    private func unifiAPIKeyAccount(for id: UUID) -> String {
        "BlueConnectAdmin.unifiAPIKey.\(id.uuidString)"
    }

    var unifiProfiles: [UniFiProfile] {
        get {
            guard let data = unifiProfilesRaw.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([UniFiProfile].self, from: data)
            else { return [] }
            return arr
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            unifiProfilesRaw = String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    var activeUnifiProfileID: UUID? {
        get { UUID(uuidString: activeUnifiProfileIDRaw) }
        set { activeUnifiProfileIDRaw = newValue?.uuidString ?? "" }
    }

    /// Currently selected profile. Falls back to the first profile in
    /// the list when `activeUnifiProfileID` is nil or stale, so the
    /// UI never has to handle a "no active selection but profiles
    /// exist" state.
    var activeUnifiProfile: UniFiProfile? {
        let list = unifiProfiles
        if let id = activeUnifiProfileID,
           let p = list.first(where: { $0.id == id }) { return p }
        return list.first
    }

    func unifiAPIKey(for profile: UniFiProfile) -> String {
        KeychainHelper.read(account: unifiAPIKeyAccount(for: profile.id)) ?? ""
    }

    func setUnifiAPIKey(_ key: String, for profile: UniFiProfile) {
        KeychainHelper.save(key, account: unifiAPIKeyAccount(for: profile.id))
    }

    func deleteUnifiAPIKey(for profile: UniFiProfile) {
        KeychainHelper.delete(account: unifiAPIKeyAccount(for: profile.id))
    }

    func isConfigured(_ profile: UniFiProfile) -> Bool {
        profile.hasURL && !unifiAPIKey(for: profile).isEmpty
    }

    var isUnifiConfigured: Bool {
        guard let p = activeUnifiProfile else { return false }
        return isConfigured(p)
    }

    /// `(baseURL, apiKey, site)` for the active profile, or nil when
    /// nothing is configured. The exact tuple shape the scanner +
    /// settings test path consume.
    var activeUnifiCredentials: (String, String, String)? {
        guard let p = activeUnifiProfile, isConfigured(p) else { return nil }
        return (p.baseURL, unifiAPIKey(for: p), p.resolvedSite)
    }

    /// One-shot legacy → profiles migration. Runs once after the
    /// keychain bootstrap so the legacy `unifiAPIKey` mirror is
    /// populated. If a legacy URL is present and the profiles list is
    /// empty, promote the legacy single-controller config into a
    /// "Default" profile, copy the key across Keychain accounts, then
    /// clear the legacy AppStorage + Keychain entries so a downgrade
    /// can't resurrect them.
    private func migrateLegacyUnifiSettingsIfNeeded() {
        guard !unifiProfilesMigrated else { return }
        defer { unifiProfilesMigrated = true }
        let legacyURL = unifiBaseURL.trimmingCharacters(in: .whitespaces)
        guard !legacyURL.isEmpty else { return }
        // Don't stomp profiles a newer build already wrote.
        guard unifiProfiles.isEmpty else { return }
        let profile = UniFiProfile(
            label: "Default",
            baseURL: legacyURL,
            site: unifiSite
        )
        unifiProfiles = [profile]
        activeUnifiProfileID = profile.id
        if !unifiAPIKey.isEmpty {
            setUnifiAPIKey(unifiAPIKey, for: profile)
        }
        // Decommission the legacy entries.
        KeychainHelper.delete(account: Self.unifiAPIKeyAccount)
        unifiBaseURL = ""
        unifiSite = "default"
        unifiAPIKey = ""
    }

    func loadMunkiSecretFromKeychain() {
        munkiRepoSecretKey = KeychainHelper.read(account: Self.munkiSecretAccount) ?? ""
        munkiRepoBasicPassword = KeychainHelper.read(account: Self.munkiBasicAccount) ?? ""
    }

    func saveMunkiSecretToKeychain() {
        KeychainHelper.save(munkiRepoSecretKey, account: Self.munkiSecretAccount)
    }

    func saveMunkiBasicPasswordToKeychain() {
        KeychainHelper.save(munkiRepoBasicPassword, account: Self.munkiBasicAccount)
    }

    /// True when we have enough config to attempt a fetch under the
    /// currently-selected auth mode.
    var isMunkiRepoConfigured: Bool {
        guard !munkiRepoEndpoint.isEmpty else { return false }
        switch munkiRepoAuthMode {
        case "none":
            return true  // plain HTTPS, public/firewalled — endpoint is enough
        case "basic":
            return !munkiRepoBasicUser.isEmpty && !munkiRepoBasicPassword.isEmpty
        case "both":
            return !munkiRepoAccessKey.isEmpty && !munkiRepoSecretKey.isEmpty
                && !munkiRepoBasicUser.isEmpty && !munkiRepoBasicPassword.isEmpty
        default: // "s3"
            return !munkiRepoAccessKey.isEmpty && !munkiRepoSecretKey.isEmpty
        }
    }

    // Sidebar status-filter order (comma-separated keys, local per-Mac).
    @AppStorage("statusOrder") var statusOrderRaw: String = "all,favorites,recent,active,inactive,uncat"

    // Sidebar group collapse state — persisted per-Mac.
    @AppStorage("sidebarCategoriesCollapsed")    var sidebarCategoriesCollapsed: Bool = false
    @AppStorage("sidebarLocalNetworkCollapsed")  var sidebarLocalNetworkCollapsed: Bool = false
    @AppStorage("sidebarTailscaleCollapsed")     var sidebarTailscaleCollapsed: Bool = false
    @AppStorage("sidebarMunkiCollapsed")         var sidebarMunkiCollapsed: Bool = false
    /// When true, the Munki Repo group is removed from the sidebar
    /// entirely (independent of the collapsed/expanded state). Useful
    /// for admins who run the Munki picker but don't want the sidebar
    /// real estate. The repo browser and Install Package's Munki tab
    /// still work regardless — this is sidebar visibility only.
    @AppStorage("sidebarMunkiHidden")            var sidebarMunkiHidden: Bool = false

    var expandedKeyPath: String {
        NSString(string: adminKeyPath).expandingTildeInPath
    }
}
