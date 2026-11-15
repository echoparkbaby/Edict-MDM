## Edict MDM 2.0.0

**BlueConnect Admin is now Edict MDM.** This is BlueConnect Admin's next major version under a new name. Every remote-support feature from 1.5.6 is still here, and Edict adds Apple device management on a self-hosted, open-source MDM stack (NanoMDM, KMFDDM, SCEP, with optional NanoDEP).

Requires **macOS 15 or later**.

### Upgrading from BlueConnect Admin

- Edict installs **next to** BlueConnect Admin, with its own settings and Keychain entries, so you can run both while you switch.
- On first launch Edict offers to **import** your BlueConnect Admin preferences, saved passwords, Quick Actions, favorites and recents. It only fills in what's missing and never overwrites anything. macOS may ask once per saved password; click **Always Allow**.
- **No server changes.** Edict uses the same BlueSkyConnect PHP endpoints as 1.5.x.
- **MDM is optional.** Until you configure it in Settings → Device Management, Edict works like BlueConnect Admin.

### New: device management

- **One fleet table** that merges BlueSkyConnect hosts and MDM enrollments, matched by serial number. Columns for MDM status, OS, FileVault and the logged-in user.
- **Device detail pane**: live inventory, compliance, DDM status and MDM actions (lock, erase, restart, shut down, rename, unenroll) next to SSH and Screen Sharing.
- **One Device Management workspace** in the sidebar: **Overview, Devices, Security, Updates, Policies, Enrollment** and **Activity**. Overview puts management health, missing evidence and devices needing attention first; Security compares FileVault, firewall, SIP and Gatekeeper without hiding Macs that have not reported; Activity shows what happened to each command. Smart groups and saved views are still here.
- **Control-click any Mac on Devices** for Check In Now, Open Device Details, Copy Serial Number, Refresh, Enable Reporting and Hide from Needs Attention (with Unhide). Select several Macs to act on all of them at once. Restart, Lock and Unenroll are under **More**, one Mac at a time, each with a confirmation.
- **Arrow keys** move between Macs in the device lists: click a Mac, then press Up or Down.
- **Declarative Device Management**: a declaration library with plain-English templates, activation predicates, assets, a sets grid that flags configurations that won't take effect, sync to KMFDDM, git-friendly export, and a per-device view of what each Mac reports back.
- **Configuration profiles**: templates and imported `.mobileconfig` files, a diff before redeploying, and drift detection.
- **Onboarding**: apply chosen profiles and DDM sets to newly enrolled Macs automatically.
- **Enrollment**: build and sign the enrollment profile with your Developer ID; push-certificate expiry countdown.
- **Automated Device Enrollment** through NanoDEP and Apple Business Manager (not yet tested against a live ABM token).
- **Scheduled tasks** and an activity log.

### Also in this release

- The minimum macOS is now **15**.
- Enrollment profiles are now signed with your Developer ID certificate, picked by its fingerprint. Before, the wrong certificate could be used and the profile installed as "Unverified", or signing failed with an "ambiguous certificate" error.
- Faster host list and dashboards on large fleets.
- Fixes for an app hang when a command printed a lot of output, wrong selections when clicking quickly through declarations, Quick Actions opening an extra window, and the Tailscale sheet forgetting its username.
- VoiceOver labels on about 40 controls.
- New shortcuts: ⌥⌘1–6 for sidebar filters and ⌥⌘B for menu bar search (these used to clash with system shortcuts).

### Full changelog

Every change since 1.5.6, grouped by area: [CHANGELOG.md](https://github.com/echoparkbaby/Edict-MDM/blob/main/CHANGELOG.md)

### Assets

- `Edict-MDM.dmg`: the app, signed and notarized. Drag it to Applications.
- `BlueConnectHelper.pkg`: the chat helper and GUI helper for fleet Macs, deployable with Munki.
