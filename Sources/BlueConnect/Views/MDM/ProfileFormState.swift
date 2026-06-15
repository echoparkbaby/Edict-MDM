import Foundation

/// Every field the profile-template forms edit, plus the validation and
/// profile-building logic that used to live inline in `ProfilesView`. A
/// plain value type so `TemplateFormView` binds to it and `build`/`isValid`
/// are unit-testable — the Profiles analog of `DashboardFacts`.
struct ProfileFormState {
    // FileVault
    var fvDefer = true
    // Firewall
    var fwBlockAll = false
    var fwStealth = true
    // Software Update
    var suAutoDownload = true
    var suAutoInstallOS = false
    var suAutoSecurity = true
    // Screen lock
    var slIdleMinutes = 5
    var slDelaySeconds = 0
    // Restrictions
    var rAllowErase = true
    var rAllowAirDrop = true
    var rAllowGameCenter = true
    var rAllowAppStore = true
    // Gatekeeper
    var gkAllowDevelopers = true
    // Login Window
    var lwDisableGuest = true
    var lwHideAdmins = false
    var lwNamePasswordFields = true
    // Certificate
    var certPEM = ""
    var certName = ""
    // Munki
    var munkiRepoURL = ""
    var munkiClientID = ""
    // Time Machine
    var tmDest = ""
    var tmAuto = true
    var tmAllVolumes = false
    var tmSkipSys = true
    // DNS
    var dnsHTTPS = true
    var dnsServer = ""
    // Dock
    var dockOrientation = "bottom"
    var dockAutohide = false
    var dockTileSize = 48
    var dockRecents = true
    // Finder
    var finderShowDrives = true
    var finderShowAll = false
    var finderWarnTrash = true
    // KEXT
    var kextTeamIDs = ""
    var kextUserOverrides = false
    // PPPC
    var pppcID = ""
    var pppcIsPath = false
    var pppcCodeReq = ""
    var pppcFDA = true
    var pppcAccessibility = false
    var pppcScreen = false
    var pppcInput = false
    var pppcAuth = "Allow"
    // Single App Mode
    var singleAppID = ""
    var singleDisableAutoLock = true
    var singleDisableTouch = false
    // Notifications
    var notifBundleID = ""
    var notifEnabled = true
    var notifAlertType = 2
    var notifSounds = true
    var notifBadges = true
    var notifLockScreen = true
    var notifCenter = true
    var notifCritical = false
    // Web filter
    var wfAutoFilter = false
    var wfAllowed = ""
    var wfBlocked = ""
    // CalDAV / CardDAV
    var davDesc = ""
    var davHost = ""
    var davPort = 0
    var davPrincipal = ""
    var davUser = ""
    var davSSL = true
    // Associated domains
    var assocAppID = ""
    var assocDomains = ""
    // Platform SSO
    var ssoVendor: ProfilePayloads.SSOVendor = .entra
    var ssoExtensionID = ProfilePayloads.SSOVendor.entra.extensionID
    var ssoTeamID = ProfilePayloads.SSOVendor.entra.teamID
    var ssoURLs = ProfilePayloads.SSOVendor.entra.urls.joined(separator: "\n")
    var ssoAuthMethod = "UserSecureEnclaveKey"
    var ssoSharedKeys = false
    // Mail
    var mailDesc = ""
    var mailAddress = ""
    var mailHost = ""
    var mailPort = 0
    var mailUser = ""
    var mailSSL = true
    var mailIMAP = true
    // Energy
    var energyDisplaySleep = 10
    var energySystemSleep = 0
    var energyWakeOnLAN = true
    var energyRestartAfterPower = true
    // Safari
    var safariHome = ""
    var safariOpenHome = true
    var safariNoPrivate = false
    // Chrome
    var chromeHome = ""
    var chromeRestore = false
    var chromeNoIncognito = false
    // Screen Time (US rating thresholds; 1000 = allow all)
    var stApps = 1000
    var stMovies = 1000
    var stTV = 1000
    var stExplicit = true
    // Wi-Fi
    var ssid = ""
    var wifiPassword = ""
    var wifiHidden = false
    var wifiSecurity: ProfilePayloads.WiFiSecurity = .wpa2
    // Passcode
    var minLength = 8
    var requireAlphanumeric = true
    var maxInactivity = 0   // minutes; 0 = none
    // Custom
    var customXML = ""

    /// Whether the form has the minimum required input for the template.
    func isValid(for template: ProfileTemplate) -> Bool {
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
        case .platformSSO:
            return !ssoExtensionID.trimmingCharacters(in: .whitespaces).isEmpty
                && !ssoTeamID.trimmingCharacters(in: .whitespaces).isEmpty
        case .mail:
            return !mailDesc.trimmingCharacters(in: .whitespaces).isEmpty
                && !mailAddress.trimmingCharacters(in: .whitespaces).isEmpty
                && !mailHost.trimmingCharacters(in: .whitespaces).isEmpty
        case .pppc:
            return !pppcID.trimmingCharacters(in: .whitespaces).isEmpty
                && !pppcCodeReq.trimmingCharacters(in: .whitespaces).isEmpty
                && (pppcFDA || pppcAccessibility || pppcScreen || pppcInput)
        default: return true
        }
    }

    /// Build the `.mobileconfig` bytes + a display name for the template.
    func build(for template: ProfileTemplate) throws -> (data: Data, name: String) {
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
        case .platformSSO:
            let urls = ssoURLs.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return (ProfilePayloads.platformSSO(extensionID: ssoExtensionID.trimmingCharacters(in: .whitespaces),
                                                teamID: ssoTeamID.trimmingCharacters(in: .whitespaces),
                                                urls: urls, authMethod: ssoAuthMethod,
                                                useSharedDeviceKeys: ssoSharedKeys),
                    "Platform SSO (\(ssoVendor.rawValue))")
        case .mail:
            return (ProfilePayloads.mail(accountDescription: mailDesc.trimmingCharacters(in: .whitespaces),
                                         address: mailAddress.trimmingCharacters(in: .whitespaces),
                                         host: mailHost.trimmingCharacters(in: .whitespaces),
                                         port: mailPort, username: mailUser.trimmingCharacters(in: .whitespaces),
                                         useSSL: mailSSL, imap: mailIMAP), "Mail: \(mailDesc)")
        case .energy:
            return (ProfilePayloads.energy(displaySleep: energyDisplaySleep, systemSleep: energySystemSleep,
                                           wakeOnLAN: energyWakeOnLAN,
                                           restartAfterPowerFailure: energyRestartAfterPower), "Energy Saver")
        case .safari:
            return (ProfilePayloads.safari(homepage: safariHome.trimmingCharacters(in: .whitespaces),
                                           openWithHomepage: safariOpenHome,
                                           disablePrivateBrowsing: safariNoPrivate), "Safari (managed)")
        case .chrome:
            return (ProfilePayloads.chrome(homepage: chromeHome.trimmingCharacters(in: .whitespaces),
                                           restoreLastSession: chromeRestore,
                                           disableIncognito: chromeNoIncognito), "Chrome (managed)")
        case .screenTime:
            return (ProfilePayloads.screenTime(ratingApps: stApps, ratingMovies: stMovies,
                                               ratingTVShows: stTV, allowExplicitContent: stExplicit), "Screen Time")
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
}
