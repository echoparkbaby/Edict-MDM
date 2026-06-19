import Foundation

/// The built-in configuration-profile templates the Profiles catalog
/// offers. Pure metadata (display name, platforms, icon, blurb); the form
/// for each lives in `TemplateFormView` and the bytes are built by
/// `ProfileFormState.build(for:)`.
enum ProfileTemplate: String, CaseIterable, Identifiable {
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
    case platformSSO = "Platform SSO"
    case mail = "Mail"
    case energy = "Energy Saver"
    case safari = "Safari (managed)"
    case chrome = "Chrome (managed)"
    case screenTime = "Screen Time"
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
        case .wifi, .certificate, .dns, .restrictions, .screenTime: return "macOS · iOS · tvOS"
        case .passcode: return "macOS · iOS"
        case .singleApp: return "iOS · tvOS"
        case .notifications, .webFilter, .calDAV, .cardDAV, .mail: return "macOS · iOS"
        case .associatedDomains: return "macOS · iOS · tvOS"
        case .custom: return "any"
        default: return "macOS"
        }
    }
    /// Structured platforms for the filter toggles. Custom is "any", so
    /// it matches every filter.
    var platformSet: Set<ProfilePlatform> {
        switch self {
        case .wifi, .certificate, .dns, .restrictions, .associatedDomains, .screenTime: return [.macOS, .iOS, .tvOS]
        case .passcode, .notifications, .webFilter, .calDAV, .cardDAV, .mail: return [.macOS, .iOS]
        case .singleApp: return [.iOS, .tvOS]
        case .custom: return [.macOS, .iOS, .tvOS]
        default: return [.macOS]
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
        case .platformSSO: return "person.badge.key.fill"
        case .mail: return "envelope.fill"
        case .energy: return "powersleep"
        case .safari: return "safari"
        case .chrome: return "globe"
        case .screenTime: return "hourglass"
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
        case .platformSSO: return "Tie macOS login to Entra ID or Okta (Platform Single Sign-On)."
        case .mail: return "Mail account (IMAP/POP) pushed to the device."
        case .energy: return "Energy Saver — display/system sleep, wake-on-LAN, restart after power failure."
        case .safari: return "Managed Safari — homepage, new-window behavior, private browsing."
        case .chrome: return "Managed Chrome enterprise policy — homepage, startup, incognito."
        case .screenTime: return "Content & Privacy — app/movie/TV ratings by region, explicit content, Siri language filter, adult-website limit."
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
