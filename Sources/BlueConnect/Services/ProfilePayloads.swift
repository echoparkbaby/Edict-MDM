import Foundation

/// Builders for the configuration profiles (.mobileconfig) Edict deploys
/// via the MDM InstallProfile command — so common policy is a form, not
/// hand-edited XML. Each returns the profile as serialized plist bytes.
enum ProfilePayloads {

    enum WiFiSecurity: String, CaseIterable, Identifiable {
        case wpa2 = "WPA2", wpa3 = "WPA3", none = "None"
        var id: String { rawValue }
        /// EncryptionType value Apple's Wi-Fi payload expects.
        var encryptionType: String { self == .none ? "None" : "WPA2" }
        var needsPassword: Bool { self != .none }
    }

    /// `com.apple.wifi.managed` — auto-join Wi-Fi network.
    static func wifi(ssid: String, password: String,
                     hidden: Bool, security: WiFiSecurity) -> Data {
        var payload: [String: Any] = base("com.apple.wifi.managed",
                                           displayName: "Wi-Fi (\(ssid))")
        payload["SSID_STR"] = ssid
        payload["HIDDEN_NETWORK"] = hidden
        payload["AutoJoin"] = true
        payload["EncryptionType"] = security.encryptionType
        if security.needsPassword, !password.isEmpty {
            payload["Password"] = password
        }
        return profile(displayName: "Wi-Fi: \(ssid)",
                       identifier: "xyz.hellocomputer.edict.wifi",
                       payloads: [payload])
    }

    /// `com.apple.mobiledevice.passwordpolicy` — login password policy.
    static func passcode(minLength: Int, requireAlphanumeric: Bool,
                         maxInactivityMinutes: Int?) -> Data {
        var payload: [String: Any] = base("com.apple.mobiledevice.passwordpolicy",
                                           displayName: "Password Policy")
        payload["minLength"] = minLength
        payload["requireAlphanumeric"] = requireAlphanumeric
        payload["allowSimple"] = !requireAlphanumeric
        if let m = maxInactivityMinutes, m > 0 {
            payload["maxInactivity"] = m
        }
        return profile(displayName: "Password Policy",
                       identifier: "xyz.hellocomputer.edict.passcode",
                       payloads: [payload])
    }

    /// `com.apple.MCX.FileVault2` — force-enable FileVault disk
    /// encryption, deferring until the user next logs out, and escrow the
    /// recovery key. Staple of every commercial MDM.
    static func fileVault(deferEnable: Bool) -> Data {
        var fv: [String: Any] = base("com.apple.MCX.FileVault2",
                                      displayName: "FileVault Encryption")
        fv["Enable"] = "On"
        fv["Defer"] = deferEnable
        fv["UseRecoveryKey"] = true
        fv["ShowRecoveryKey"] = false
        if deferEnable { fv["DeferForceAtUserLoginMaxBypassAttempts"] = 0 }
        // Personal-recovery-key escrow so the org can unlock the disk.
        var escrow: [String: Any] = base("com.apple.security.FDERecoveryKeyEscrow",
                                          displayName: "FileVault Key Escrow")
        escrow["Location"] = "Edict MDM"
        return profile(displayName: "FileVault Encryption",
                       identifier: "xyz.hellocomputer.edict.filevault",
                       payloads: [fv, escrow])
    }

    /// `com.apple.security.firewall` — application firewall on, with
    /// optional stealth mode and block-all-incoming.
    static func firewall(blockAllIncoming: Bool, stealthMode: Bool) -> Data {
        var fw: [String: Any] = base("com.apple.security.firewall",
                                     displayName: "Firewall")
        fw["EnableFirewall"] = true
        fw["BlockAllIncoming"] = blockAllIncoming
        fw["EnableStealthMode"] = stealthMode
        return profile(displayName: "Firewall",
                       identifier: "xyz.hellocomputer.edict.firewall",
                       payloads: [fw])
    }

    /// `com.apple.SoftwareUpdate` — automatic update behavior.
    static func softwareUpdate(autoCheck: Bool, autoDownload: Bool,
                               autoInstallOS: Bool, autoInstallSecurity: Bool) -> Data {
        var su: [String: Any] = base("com.apple.SoftwareUpdate",
                                     displayName: "Software Update")
        su["AutomaticCheckEnabled"] = autoCheck
        su["AutomaticDownload"] = autoDownload
        su["AutomaticallyInstallMacOSUpdates"] = autoInstallOS
        su["ConfigDataInstall"] = autoInstallSecurity
        su["CriticalUpdateInstall"] = autoInstallSecurity
        return profile(displayName: "Software Update",
                       identifier: "xyz.hellocomputer.edict.softwareupdate",
                       payloads: [su])
    }

    /// `com.apple.screensaver` — require the login password after the
    /// screen saver / display sleep, after `delaySeconds`.
    static func screenLock(idleSeconds: Int, delaySeconds: Int) -> Data {
        var ss: [String: Any] = base("com.apple.screensaver",
                                     displayName: "Screen Lock")
        ss["idleTime"] = idleSeconds
        ss["askForPassword"] = 1
        ss["askForPasswordDelay"] = delaySeconds
        return profile(displayName: "Screen Lock",
                       identifier: "xyz.hellocomputer.edict.screenlock",
                       payloads: [ss])
    }

    /// `com.apple.applicationaccess` — common device restrictions. Only
    /// the toggles the operator turns OFF are emitted (everything is
    /// allowed by default), keeping the profile minimal.
    static func restrictions(allowEraseAllContent: Bool, allowAirDrop: Bool,
                             allowGameCenter: Bool, allowAppStore: Bool) -> Data {
        var r: [String: Any] = base("com.apple.applicationaccess",
                                     displayName: "Restrictions")
        if !allowEraseAllContent { r["allowEraseContentAndSettings"] = false }
        if !allowAirDrop { r["allowAirDrop"] = false }
        if !allowGameCenter { r["allowGameCenter"] = false }
        if !allowAppStore { r["allowAppInstallation"] = false }
        return profile(displayName: "Restrictions",
                       identifier: "xyz.hellocomputer.edict.restrictions",
                       payloads: [r])
    }

    /// `com.apple.systempolicy.control` — Gatekeeper. Require assessment
    /// (only signed apps run); optionally restrict to App Store only.
    static func gatekeeper(allowIdentifiedDevelopers: Bool) -> Data {
        var gk: [String: Any] = base("com.apple.systempolicy.control",
                                     displayName: "Gatekeeper")
        gk["EnableAssessment"] = true
        gk["AllowIdentifiedDevelopers"] = allowIdentifiedDevelopers
        return profile(displayName: "Gatekeeper",
                       identifier: "xyz.hellocomputer.edict.gatekeeper",
                       payloads: [gk])
    }

    /// `com.apple.loginwindow` — login window hardening.
    static func loginWindow(disableGuest: Bool, hideAdminUsers: Bool,
                            showNamePasswordFields: Bool) -> Data {
        var lw: [String: Any] = base("com.apple.loginwindow",
                                     displayName: "Login Window")
        lw["DisableConsoleAccess"] = true
        lw["HideAdminUsers"] = hideAdminUsers
        // SHOWFULLNAME true => name+password text fields; false => user list.
        lw["SHOWFULLNAME"] = showNamePasswordFields
        if disableGuest {
            lw["DisableGuestAccount"] = true
            lw["EnableExternalAccounts"] = false
        }
        return profile(displayName: "Login Window",
                       identifier: "xyz.hellocomputer.edict.loginwindow",
                       payloads: [lw])
    }

    /// `com.apple.security.root` — install + trust a root CA from a pasted
    /// PEM certificate. The payload carries the DER bytes.
    static func rootCertificate(pem: String, name: String) throws -> Data {
        // Extract the base64 between the PEM markers and decode to DER.
        let b64 = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let der = Data(base64Encoded: b64), !der.isEmpty else {
            throw Invalid.notCertificate
        }
        var cert: [String: Any] = base("com.apple.security.root",
                                       displayName: name.isEmpty ? "Root Certificate" : name)
        cert["PayloadCertificateFileName"] = "\(name.isEmpty ? "root" : name).cer"
        cert["PayloadContent"] = der
        return profile(displayName: name.isEmpty ? "Root Certificate" : name,
                       identifier: "xyz.hellocomputer.edict.rootcert",
                       payloads: [cert])
    }

    /// Munki client configuration via an MCX preferences payload — points
    /// the Mac at a Munki software repo. Ties Edict MDM to BlueConnect's
    /// existing Munki: enroll a Mac and it starts pulling managed software.
    static func munki(repoURL: String, clientIdentifier: String) -> Data {
        var prefs: [String: Any] = ["SoftwareRepoURL": repoURL]
        if !clientIdentifier.isEmpty { prefs["ClientIdentifier"] = clientIdentifier }
        var mcx: [String: Any] = base("com.apple.ManagedClient.preferences",
                                      displayName: "Munki")
        mcx["PayloadContent"] = [
            "com.googlecode.munki.ManagedInstalls": [
                "Forced": [["mcx_preference_settings": prefs]],
            ],
        ]
        return profile(displayName: "Munki",
                       identifier: "xyz.hellocomputer.edict.munki",
                       payloads: [mcx])
    }

    /// `com.apple.TCC.configuration-profile-policy` — Privacy Preferences
    /// Policy Control (PPPC). Pre-grant an app access to protected
    /// services (Full Disk Access, Accessibility, Screen Recording, …)
    /// without the user prompt. CodeRequirement comes from
    /// `codesign -dr - /Applications/App.app`.
    static func pppc(identifier: String, identifierType: String, codeRequirement: String,
                     services: [String], authorization: String) -> Data {
        var entries: [String: Any] = [:]
        for svc in services {
            entries[svc] = [[
                "Identifier": identifier,
                "IdentifierType": identifierType,
                "CodeRequirement": codeRequirement,
                "Authorization": authorization,
            ]]
        }
        var tcc: [String: Any] = base("com.apple.TCC.configuration-profile-policy",
                                      displayName: "Privacy Preferences")
        tcc["Services"] = entries
        return profile(displayName: "Privacy: \(identifier)",
                       identifier: "xyz.hellocomputer.edict.pppc.\(identifier)", payloads: [tcc])
    }

    /// `com.apple.app.lock` — Single App Mode (autonomous kiosk). Locks
    /// the device to one app; great for Apple TV / iPad kiosks.
    static func singleAppMode(bundleID: String, disableAutoLock: Bool, disableTouch: Bool) -> Data {
        var options: [String: Any] = [:]
        if disableAutoLock { options["DisableAutoLock"] = true }
        if disableTouch { options["DisableTouch"] = true }
        var app: [String: Any] = ["Identifier": bundleID]
        if !options.isEmpty { app["Options"] = options }
        var lock: [String: Any] = base("com.apple.app.lock", displayName: "Single App Mode")
        lock["App"] = app
        return profile(displayName: "Single App Mode",
                       identifier: "xyz.hellocomputer.edict.singleapp", payloads: [lock])
    }

    /// `com.apple.notificationsettings` — per-app notification behavior.
    /// AlertType: 0 none, 1 banner, 2 persistent alert.
    static func notifications(bundleID: String, enabled: Bool, alertType: Int,
                              sounds: Bool, badges: Bool, lockScreen: Bool,
                              notificationCenter: Bool, critical: Bool) -> Data {
        let setting: [String: Any] = [
            "BundleIdentifier": bundleID,
            "NotificationsEnabled": enabled,
            "AlertType": alertType,
            "SoundsEnabled": sounds,
            "BadgesEnabled": badges,
            "ShowInLockScreen": lockScreen,
            "ShowInNotificationCenter": notificationCenter,
            "CriticalAlertEnabled": critical,
        ]
        var n: [String: Any] = base("com.apple.notificationsettings", displayName: "Notifications")
        n["NotificationSettings"] = [setting]
        return profile(displayName: "Notifications: \(bundleID)",
                       identifier: "xyz.hellocomputer.edict.notifications.\(bundleID)", payloads: [n])
    }

    /// `com.apple.webcontent-filter` — built-in web content filter with
    /// always-permitted and always-blocked URL lists.
    static func webFilter(autoFilter: Bool, allowedURLs: [String], blockedURLs: [String]) -> Data {
        var w: [String: Any] = base("com.apple.webcontent-filter", displayName: "Web Content Filter")
        w["FilterType"] = "BuiltIn"
        w["AutoFilterEnabled"] = autoFilter
        if !allowedURLs.isEmpty { w["PermittedURLs"] = allowedURLs }
        if !blockedURLs.isEmpty { w["BlacklistedURLs"] = blockedURLs }
        return profile(displayName: "Web Content Filter",
                       identifier: "xyz.hellocomputer.edict.webfilter", payloads: [w])
    }

    /// `com.apple.caldav.account` — calendar account.
    static func calDAV(description: String, host: String, port: Int, principalURL: String,
                       username: String, useSSL: Bool) -> Data {
        var c: [String: Any] = base("com.apple.caldav.account", displayName: "CalDAV")
        c["CalDAVAccountDescription"] = description
        c["CalDAVHostName"] = host
        if port > 0 { c["CalDAVPort"] = port }
        if !principalURL.isEmpty { c["CalDAVPrincipalURL"] = principalURL }
        if !username.isEmpty { c["CalDAVUsername"] = username }
        c["CalDAVUseSSL"] = useSSL
        return profile(displayName: "CalDAV: \(description)",
                       identifier: "xyz.hellocomputer.edict.caldav", payloads: [c])
    }

    /// `com.apple.carddav.account` — contacts account.
    static func cardDAV(description: String, host: String, port: Int, principalURL: String,
                        username: String, useSSL: Bool) -> Data {
        var c: [String: Any] = base("com.apple.carddav.account", displayName: "CardDAV")
        c["CardDAVAccountDescription"] = description
        c["CardDAVHostName"] = host
        if port > 0 { c["CardDAVPort"] = port }
        if !principalURL.isEmpty { c["CardDAVPrincipalURL"] = principalURL }
        if !username.isEmpty { c["CardDAVUsername"] = username }
        c["CardDAVUseSSL"] = useSSL
        return profile(displayName: "CardDAV: \(description)",
                       identifier: "xyz.hellocomputer.edict.carddav", payloads: [c])
    }

    /// `com.apple.associated-domains` — associate an app with web domains
    /// (universal links, shared web credentials).
    static func associatedDomains(appID: String, domains: [String]) -> Data {
        var a: [String: Any] = base("com.apple.associated-domains", displayName: "Associated Domains")
        a["Configuration"] = [[
            "ApplicationIdentifier": appID,
            "AssociatedDomains": domains,
            "EnableDirectDownloads": false,
        ]]
        return profile(displayName: "Associated Domains: \(appID)",
                       identifier: "xyz.hellocomputer.edict.assoc", payloads: [a])
    }

    /// Identity-provider preset for Platform SSO. The extension + team IDs
    /// are the vendor's published values; URLs are the IdP's auth hosts.
    enum SSOVendor: String, CaseIterable, Identifiable {
        case entra = "Microsoft Entra ID"
        case okta = "Okta"
        case custom = "Custom"
        var id: String { rawValue }
        var extensionID: String {
            switch self {
            case .entra:  return "com.microsoft.CompanyPortalMac.ssoextension"
            case .okta:   return "com.okta.mobile.auth-service-extension"
            case .custom: return ""
            }
        }
        var teamID: String {
            switch self {
            case .entra:  return "UBF8T346G9"
            case .okta:   return "B7F62B65BN"
            case .custom: return ""
            }
        }
        /// Default redirect URLs the extension should handle.
        var urls: [String] {
            switch self {
            case .entra:  return ["https://login.microsoftonline.com",
                                  "https://login.microsoft.com",
                                  "https://sts.windows.net",
                                  "https://login.windows.net"]
            case .okta:   return ["https://example.okta.com"]
            case .custom: return []
            }
        }
    }

    /// `com.apple.extensiblesso` — Platform Single Sign-On. Ties macOS
    /// login to an IdP (Entra ID, Okta, …). macOS 13+. The PlatformSSO
    /// sub-dictionary turns on device-bound (passwordless) auth.
    static func platformSSO(extensionID: String, teamID: String,
                            urls: [String], authMethod: String,
                            useSharedDeviceKeys: Bool) -> Data {
        var sso: [String: Any] = base("com.apple.extensiblesso",
                                      displayName: "Single Sign-On Extension")
        sso["ExtensionIdentifier"] = extensionID
        sso["TeamIdentifier"] = teamID
        sso["Type"] = "Redirect"
        if !urls.isEmpty { sso["URLs"] = urls }
        sso["PlatformSSO"] = [
            "AuthenticationMethod": authMethod,            // Password | UserSecureEnclaveKey | SmartCard
            "UseSharedDeviceKeys": useSharedDeviceKeys,
        ]
        return profile(displayName: "Platform SSO", identifier: "xyz.hellocomputer.edict.platformsso",
                       payloads: [sso])
    }

    /// `com.apple.mail.managed` — a Mail account. The password isn't in the
    /// profile; the user is prompted on install.
    static func mail(accountDescription: String, address: String, host: String, port: Int,
                     username: String, useSSL: Bool, imap: Bool) -> Data {
        var m: [String: Any] = base("com.apple.mail.managed", displayName: "Mail")
        m["EmailAccountDescription"] = accountDescription
        m["EmailAccountName"] = address
        m["EmailAddress"] = address
        m["EmailAccountType"] = imap ? "EmailTypeIMAP" : "EmailTypePOP"
        m["IncomingMailServerHostName"] = host
        if port > 0 { m["IncomingMailServerPortNumber"] = port }
        m["IncomingMailServerUseSSL"] = useSSL
        m["OutgoingMailServerHostName"] = host
        m["OutgoingMailServerUseSSL"] = useSSL
        if !username.isEmpty {
            m["IncomingMailServerUsername"] = username
            m["OutgoingMailServerUsername"] = username
        }
        return profile(displayName: "Mail: \(accountDescription)",
                       identifier: "xyz.hellocomputer.edict.mail", payloads: [m])
    }

    /// `com.apple.MCX` energy-saver schedule (sleep timers in minutes,
    /// 0 = never). Applied to both AC profiles.
    static func energy(displaySleep: Int, systemSleep: Int, wakeOnLAN: Bool,
                       restartAfterPowerFailure: Bool) -> Data {
        var e: [String: Any] = base("com.apple.MCX", displayName: "Energy Saver")
        var ac: [String: Any] = ["Wake On LAN": wakeOnLAN ? 1 : 0,
                                 "RestartAfterPowerFailure": restartAfterPowerFailure ? 1 : 0]
        if displaySleep >= 0 { ac["Display Sleep Timer"] = displaySleep }
        if systemSleep >= 0 { ac["System Sleep Timer"] = systemSleep }
        e["com.apple.EnergySaver.desktop.ACPower"] = ac
        e["com.apple.EnergySaver.portable.ACPower"] = ac
        return profile(displayName: "Energy Saver",
                       identifier: "xyz.hellocomputer.edict.energy", payloads: [e])
    }

    /// Managed Safari preferences (`com.apple.Safari` domain payload).
    static func safari(homepage: String, openWithHomepage: Bool, disablePrivateBrowsing: Bool) -> Data {
        var s: [String: Any] = base("com.apple.Safari", displayName: "Safari")
        if !homepage.isEmpty { s["HomePage"] = homepage }
        if openWithHomepage { s["NewWindowBehavior"] = 0; s["NewTabBehavior"] = 0 } // 0 = homepage
        if disablePrivateBrowsing { s["DisablePrivateBrowsing"] = true }
        return profile(displayName: "Safari (managed)",
                       identifier: "xyz.hellocomputer.edict.safari", payloads: [s])
    }

    /// Managed Chrome enterprise policy (`com.google.Chrome` domain payload).
    static func chrome(homepage: String, restoreLastSession: Bool, disableIncognito: Bool) -> Data {
        var c: [String: Any] = base("com.google.Chrome", displayName: "Google Chrome")
        if !homepage.isEmpty {
            c["HomepageLocation"] = homepage
            c["HomepageIsNewTabPage"] = false
            c["ShowHomeButton"] = true
        }
        c["RestoreOnStartup"] = restoreLastSession ? 1 : 5   // 1 = restore last, 5 = new tab
        if disableIncognito { c["IncognitoModeAvailability"] = 1 }  // 1 = disabled
        return profile(displayName: "Chrome (managed)",
                       identifier: "xyz.hellocomputer.edict.chrome", payloads: [c])
    }

    /// Screen Time content restrictions via `com.apple.applicationaccess`
    /// — US age-rating thresholds for apps/movies/TV + explicit-content
    /// blocking. (Downtime / app time-limits aren't a profile payload —
    /// those are Family Controls only.) Rating ints are Apple's US
    /// thresholds; 1000 = allow all, 0 = allow none.
    static func screenTime(ratingApps: Int, ratingMovies: Int, ratingTVShows: Int,
                           allowExplicitContent: Bool) -> Data {
        var r: [String: Any] = base("com.apple.applicationaccess", displayName: "Screen Time")
        r["ratingRegion"] = "us"
        r["ratingApps"] = ratingApps
        r["ratingMovies"] = ratingMovies
        r["ratingTVShows"] = ratingTVShows
        r["allowExplicitContent"] = allowExplicitContent
        return profile(displayName: "Screen Time",
                       identifier: "xyz.hellocomputer.edict.screentime", payloads: [r])
    }

    // MARK: - iMazing-catalog–derived templates

    /// `com.apple.MCX.TimeMachine` — managed Time Machine backup.
    static func timeMachine(destinationURL: String, autoBackup: Bool,
                            allVolumes: Bool, skipSystemFiles: Bool) -> Data {
        var tm: [String: Any] = base("com.apple.MCX.TimeMachine", displayName: "Time Machine")
        if !destinationURL.isEmpty { tm["BackupDestURL"] = destinationURL }
        tm["AutoBackup"] = autoBackup
        tm["BackupAllVolumes"] = allVolumes
        tm["BackupSkipSys"] = skipSystemFiles
        return profile(displayName: "Time Machine",
                       identifier: "xyz.hellocomputer.edict.timemachine", payloads: [tm])
    }

    /// `com.apple.dnsSettings.managed` — encrypted DNS (DoH/DoT).
    static func encryptedDNS(useHTTPS: Bool, server: String) -> Data {
        var dns: [String: Any] = base("com.apple.dnsSettings.managed", displayName: "Encrypted DNS")
        var s: [String: Any] = ["DNSProtocol": useHTTPS ? "HTTPS" : "TLS"]
        if useHTTPS { s["ServerURL"] = server } else { s["ServerName"] = server }
        dns["DNSSettings"] = s
        return profile(displayName: "Encrypted DNS",
                       identifier: "xyz.hellocomputer.edict.dns", payloads: [dns])
    }

    /// `com.apple.dock` — Dock appearance/behavior.
    static func dock(orientation: String, autohide: Bool, tileSize: Int, showRecents: Bool) -> Data {
        var d: [String: Any] = base("com.apple.dock", displayName: "Dock")
        d["orientation"] = orientation     // "left" / "bottom" / "right"
        d["autohide"] = autohide
        d["tilesize"] = tileSize
        d["show-recents"] = showRecents
        return profile(displayName: "Dock",
                       identifier: "xyz.hellocomputer.edict.dock", payloads: [d])
    }

    /// `com.apple.finder` — Finder desktop + visibility prefs.
    static func finder(showDrivesOnDesktop: Bool, showAllFiles: Bool, warnOnEmptyTrash: Bool) -> Data {
        var f: [String: Any] = base("com.apple.finder", displayName: "Finder")
        f["ShowHardDrivesOnDesktop"] = showDrivesOnDesktop
        f["ShowExternalHardDrivesOnDesktop"] = showDrivesOnDesktop
        f["ShowRemovableMediaOnDesktop"] = showDrivesOnDesktop
        f["ShowMountedServersOnDesktop"] = showDrivesOnDesktop
        f["AppleShowAllFiles"] = showAllFiles
        f["WarnOnEmptyTrash"] = warnOnEmptyTrash
        return profile(displayName: "Finder",
                       identifier: "xyz.hellocomputer.edict.finder", payloads: [f])
    }

    /// `com.apple.syspolicy.kernel-extension-policy` — allow third-party
    /// kernel extensions by developer Team ID (security tools, drivers).
    static func kernelExtensions(teamIdentifiers: [String], allowUserOverrides: Bool) -> Data {
        var k: [String: Any] = base("com.apple.syspolicy.kernel-extension-policy",
                                    displayName: "Kernel Extensions")
        k["AllowUserOverrides"] = allowUserOverrides
        if !teamIdentifiers.isEmpty { k["AllowedTeamIdentifiers"] = teamIdentifiers }
        return profile(displayName: "Kernel Extensions",
                       identifier: "xyz.hellocomputer.edict.kext", payloads: [k])
    }

    /// Validate + normalize a pasted profile. Accepts a full mobileconfig
    /// (returns it as-is) — used for the "Custom" template. Throws if it
    /// isn't a configuration-profile plist.
    static func custom(xml: String) throws -> Data {
        guard let data = xml.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw Invalid.notPlist }
        guard (obj["PayloadType"] as? String) == "Configuration",
              obj["PayloadContent"] != nil
        else { throw Invalid.notProfile }
        return data
    }

    enum Invalid: LocalizedError {
        case notPlist, notProfile, notCertificate
        var errorDescription: String? {
            switch self {
            case .notPlist:   return "That isn't valid plist XML."
            case .notProfile: return "Not a configuration profile (needs PayloadType=Configuration and PayloadContent)."
            case .notCertificate: return "That doesn't look like a PEM certificate (expected -----BEGIN CERTIFICATE-----)."
            }
        }
    }

    /// The PayloadIdentifier a built profile will carry — for RemoveProfile.
    static func identifier(forBuiltIn kind: String) -> String {
        "xyz.hellocomputer.edict.\(kind)"
    }

    // MARK: - Builders

    private static func base(_ type: String, displayName: String) -> [String: Any] {
        [
            "PayloadType": type,
            "PayloadVersion": 1,
            "PayloadIdentifier": "xyz.hellocomputer.edict.\(type).\(UUID().uuidString)",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": displayName,
        ]
    }

    private static func profile(displayName: String, identifier: String,
                                payloads: [[String: Any]]) -> Data {
        let dict: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier,
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": displayName,
            "PayloadScope": "System",
            "PayloadContent": payloads,
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: dict,
                                                    format: .xml, options: 0)) ?? Data()
    }
}
