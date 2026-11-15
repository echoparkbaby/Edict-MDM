# Changelog

## 2.0.0 (2026-11-15)

Changes since BlueConnect Admin 1.5.6. 188 commits between June and November 2026. Grouped by area, in roughly the order the work landed.

**Name and packaging**
- The app is now **Edict MDM**, with its own bundle ID, settings, Keychain entries and a new "Ember" icon. It installs next to BlueConnect Admin.
- One-time import of BlueConnect Admin preferences and saved passwords on first launch.
- Minimum macOS raised from 13 to **15**.
- Releases now publish to the Edict-MDM repository. BlueConnect Admin 1.5.x keeps its own repository.

**MDM foundation**
- Connections to NanoMDM, KMFDDM and (optionally) NanoDEP, set up in Settings > Device Management.
- Enrollment list read from the server, with automatic retry on a transient failure. Unenrolled devices are removed from the MDM database.
- Device commands: Check In, Lock, Erase, Restart, Shut Down, Rename and Unenroll.
- Live queries for hardware, security (FileVault, firewall, SIP, Activation Lock), installed profiles and apps.
- MDM-only Macs show their real device name instead of a serial number.
- iPhone, iPad and Apple TV enrollments are recognized and labelled by type.

**One fleet table**
- BlueSkyConnect hosts and MDM enrollments merged into a single table, matched by serial number.
- New columns: MDM status, OS, FileVault and logged-in user. OS and FileVault fall back to MunkiReport when MDM has not reported, with a "via MunkiReport" tooltip.
- An MDM tab in the host inspector, next to SSH, Screen Sharing and MunkiReport.
- SSH, Screen Sharing and Quick Actions work on MDM devices that also have a BlueSky tunnel.
- Bulk MDM actions on a multi-row selection.
- The "Inventory" tab is renamed "MunkiReport", and it no longer disappears when a fetch fails. Fetch errors show what the server returned.
- MunkiReport data is cached on disk and reloaded at launch.

**Device Management workspace**
- Sidebar section with Overview, Devices, Security, Updates, Policies, Enrollment and Activity.
- Overview leads with management health, missing evidence and Macs needing attention.
- Security compares FileVault, firewall, SIP and Gatekeeper, and keeps Macs that have not reported visible.
- Updates shows per-device update compliance and a fleet summary.
- Activity records each command and separates queued, waiting, deferred, acknowledged and failed.
- Smart groups, saved views, show/hide columns, search and CSV export.
- Control-click menu on Devices (Check In Now, Open Device Details, Copy Serial Number, Refresh, Enable Reporting, Hide from Needs Attention), with Restart, Lock and Unenroll under More.
- Arrow keys move between Macs in the device lists.
- Refresh with Command-R.

**Declarative Device Management**
- Declaration library built in the app, synced to KMFDDM, with an optional mirror mode that removes server extras after a confirmation.
- Template gallery with forms, so common declarations need no hand-written JSON: macOS update enforcement, software update settings, status reporting, passcode policy, drive restrictions, screen sharing, certificate install and service config files.
- Plain-English summary of each declaration.
- Sets grid showing which Macs each set reaches, a preview of what a Mac receives, a flag on configurations that will not take effect, and a one-click fix to activate them.
- Activation predicates, so a declaration can target itself by device attributes.
- Assets (certificates and data files hosted by URL).
- Pull existing declarations from KMFDDM, and export the library as a git-friendly folder.
- Per-device view of the DDM status each Mac reports.

**Configuration profiles**
- Profile library with 29 templates: FileVault, Firewall, Software Update, Screen Lock, Restrictions, Gatekeeper, Login Window, Root Certificate, Privacy (PPPC), Single App Mode, Notifications, Web Content Filter, CalDAV, CardDAV, Associated Domains, Platform SSO, Mail, Energy Saver, managed Safari, managed Chrome, Screen Time, Munki, Time Machine, Encrypted DNS, Dock, Finder, Kernel Extensions, Wi-Fi and Password Policy, plus a custom profile.
- Import `.mobileconfig` files, signed or plain, including by drag and drop. Save and favorite profiles.
- A diff of what will change before a profile is redeployed.
- Drift detection for installed profiles, with optional automatic repair.
- Deploy to a single Mac, a selection or a smart group.
- Platform filters (macOS, iOS, tvOS) and platform badges on templates.
- Target Macs are listed by name, not serial number.

**Compliance, onboarding and automation**
- Compliance baseline with per-device grading. No baseline means "not evaluated", never "compliant".
- One-click FileVault remediation.
- Onboarding baseline: chosen profiles and DDM sets are applied to newly enrolled Macs, with separate baselines per smart group and a "needs onboarding" badge.
- Scheduled recurring MDM tasks while the app is running.
- Notifications for new enrollments, Macs falling out of compliance and certificate expiry.

**Enrollment**
- Enrollment profile builder: personalize, sign with your Developer ID and download.
- Push the enrollment profile to a Mac over its BlueSky tunnel. It lands on the logged-in user's Desktop, or in /Users/Shared if nobody is logged in.
- Push certificate expiry countdown.
- Automated Device Enrollment through NanoDEP and Apple Business Manager: account view, device list, profile builder and automatic assignment. Not yet tested against a live ABM token.
- Enrollment profiles are signed by certificate fingerprint, which fixes "Unverified" profiles and "ambiguous certificate" errors.

**Terminal**
- Terminal themes (presets, customize, save, import and export) and sharper text, contributed by @kfattic in BlueConnect-Admin PR #23.
- SwiftTerm is now included in the source tree.
- Settings window enlarged to 900 x 600 so the themes pane fits.

**Security**
- Plain HTTP is allowed only for a fixed list of hosts. It was allowed for every host before.
- The UniFi controller's certificate is pinned on first use.
- The Touch ID check before destructive actions now refuses when it cannot verify, where it used to allow.
- Passwords are no longer passed to `curl` on the command line, where other local users could read them.
- Admin secrets are stored in the Keychain as this-device-only, and existing entries are migrated.
- Saved profiles are encrypted on disk.
- Safer file writes and export paths.

**Fixes and performance**
- Fixed crashes when sorting the inventory, Devices and Security tables.
- Fixed a hang when a command printed a lot of output, and a beach ball when opening Screen Sharing to an offline host.
- Fixed lost deployment log entries and overlapping scheduled runs.
- Fixed wrong selections when clicking quickly through declarations, Quick Actions opening an extra window, and the Tailscale sheet forgetting its username.
- Fixed empty Model, macOS and FileVault values on the dashboard.
- Faster host list and dashboards on large fleets.
- VoiceOver labels on about 40 controls.
- Shortcuts moved off system-reserved keys: Option-Command-1 to 6 for sidebar filters and Option-Command-B for menu bar search.
