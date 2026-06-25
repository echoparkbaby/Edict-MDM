# Edict MDM

**One native macOS app for the whole Mac fleet: hands-on remote support and Apple device management, together.**

Edict MDM joins two things admins usually run in separate tools:

- **Remote support** over [BlueSkyConnect](https://github.com/BlueSkyTools/BlueSkyConnect) — SSH, Screen Sharing/VNC, SCP, and run-command, over the existing reverse tunnel.
- **Apple device management** on a self-hosted, open-source MDM stack — [NanoMDM](https://github.com/micromdm/nanomdm) + [KMFDDM](https://github.com/jessepeterson/kmfddm) + SCEP, with optional [NanoDEP](https://github.com/micromdm/nanodep) for zero-touch enrollment.

It's one fleet table, one detail pane, one dashboard. No cloud tenant, no per-seat pricing: you point Edict at servers you run.

> Status: pre-release. Built and used against a live homelab fleet. See [Honest limitations](#honest-limitations) before you rely on it.

---

## Why

Most small fleets end up with a remote-support tool *and* an MDM, and the two never talk. A Mac is a row in one and a row in the other, matched by hand. Edict joins them on the serial number: every host shows its MDM status next to its SSH session, and every MDM device can be Screen-Shared or have a command run on it without leaving the table.

It also leans into **Declarative Device Management (DDM)** rather than treating it as a checkbox. DDM's hardest, most-skipped part is the status channel: knowing what a device actually *did* with a policy, not just what you sent. Edict reads it back, in plain English.

---

## Highlights

**Fleet**
- Merged table of BlueSkyConnect hosts and MDM enrollments, joined by serial. Columns for MDM status, OS, FileVault, and the logged-in macOS user.
- Unified detail pane: live inventory, DDM status, compliance, and BlueConnect actions (Screen Share / SSH / run command / send file) on the same device.
- Prism dashboard: a compliance ring, an actionable attention strip (out-of-compliance, needs-onboarding, drift, not-reporting), and a breakdown by any attribute. Smart groups and saved scopes.

**Declarative Device Management**
- A declaration **library** with a plain-English template gallery — no hand-typed JSON for the common cases. Templates: enforce a macOS update, software-update settings, status reporting, passcode policy, screen sharing, external/network-drive restrictions, install a certificate, and manage service config files (sshd/sudo/pam…).
- **Activation predicates**: declarations that self-target by device condition.
- The **asset model**: certificate and data-file assets the device downloads (used by the certificate and service-config-files templates).
- A **sets grid** that shows blast radius at a glance, flags configurations that won't take effect (missing activation) and fixes them in one click, and previews exactly what a Mac in a set receives.
- Sync to KMFDDM (additive or mirror), export to a `ddm_examples`/`syncdir` folder for git, and import from files or the server.
- **Per-device status channel view**: what each Mac reports back (OS, FileVault, software-update state and failure reason) plus declaration-apply errors.

**Profiles & policy**
- Configuration-profile library: templates and imported `.mobileconfig` files, deployed via `InstallProfile`, with a diff viewer on re-deploy and managed-profile drift detection.
- Onboarding baseline: auto-apply chosen profiles and DDM sets to newly-enrolled Macs, plus per-smart-group policy.

**Enrollment**
- Build and sign the enrollment `.mobileconfig`; push-cert expiry countdown.
- Automated Device Enrollment (DEP) via NanoDEP + Apple Business Manager: account view, device list, profile builder, and auto-assigner.

**Devices**
- Lock, erase, restart, shut down, rename; live inventory (hardware/security/profiles/apps); compliance baseline grading; remote unenroll; activity log; scheduled automation.

---

## How it fits together

```
            ┌──────────────────────────────────────────────┐
            │                Edict MDM (macOS app)          │
            └──────────────────────────────────────────────┘
                 │            │              │            │
        admin APIs (tailnet)  │       BSC tunnel     MunkiReport API
                 │            │              │            │
   ┌─────────────┴───┐  ┌─────┴──────┐  ┌────┴─────┐  ┌───┴────────┐
   │ NanoMDM (MDM)   │  │ KMFDDM     │  │ BlueSky  │  │ MunkiReport│
   │ + SCEP          │  │ (DDM/sets) │  │ Connect  │  │ (optional) │
   │ + NanoDEP (opt) │  └────────────┘  └──────────┘  └────────────┘
   │ + enrollments   │
   │   sidecar       │     Apple devices enroll against the public,
   └─────────────────┘     reverse-proxied NanoMDM /mdm + /scep endpoints.
```

The app talks to the **admin** APIs over a private network (e.g. Tailscale); only the device-facing enrollment endpoints are exposed publicly through a reverse proxy.

---

## Requirements

- **macOS 14 or later** to run the app.
- A **self-hosted MDM stack**: NanoMDM + KMFDDM + a SCEP CA, MySQL, and a small read-only enrollments sidecar. NanoDEP is optional (only for ABM zero-touch).
- An **Apple MDM push certificate** (via the Apple Push Certificates Portal / a vendor cert).
- A public HTTPS endpoint for the device-facing `/mdm` and `/scep` paths.
- Optional: a **BlueSkyConnect** server for the SSH/VNC remote-support side, and **MunkiReport** for extra inventory.

Server-side setup notes (including a NanoDEP compose service) live under [`server/mdm/`](server/mdm/).

---

## Setup

1. **Stand up the stack** (NanoMDM/KMFDDM/SCEP/MySQL + enrollments sidecar). Bind the admin ports to your tailnet, not the public LAN.
2. **Point Edict at it:** Settings → Device Management. Enter the NanoMDM, KMFDDM, and enrollments-sidecar URLs and their API keys (stored in the Keychain). Test Connection exercises the whole path.
3. **Build the enrollment profile:** the Enrollment tab personalizes and signs a `.mobileconfig`. Hand it out, or push it to a fleet Mac over the BlueSkyConnect tunnel.
4. **Author declarations:** Device Management → Declarations → Add. Pick a template, fill the form, drop it into a set, and Sync.

---

## Building from source

```sh
swift build            # or open Package.swift in Xcode
bash build-app.sh      # produces a signed "Edict MDM.app"
swift test             # unit tests for the pure model + service layers
```

Swift Package, no third-party dependencies. The app is `macOS 14+`, SwiftUI, and uses `@Observable`/`@AppStorage` plus the Keychain and JSON files under `~/Library/Application Support/EdictMDM/` for storage (no SwiftData).

---

## Honest limitations

- **You run the servers.** Edict is a client. It does not host MDM; it drives NanoMDM/KMFDDM/NanoDEP that you operate.
- **DEP is untested against a live Apple Business Manager token.** The Automated Device Enrollment feature is built to NanoDEP + Apple's DEP web service spec, and the in-app UI says so. Validate it against a non-production ABM server first.
- **DDM configs have OS minimums and platform limits** (several are macOS 14+/15+ or supervised-only; the DDM account types are iOS/iPadOS-only and are intentionally not included). Each template states its requirement.
- **Certificate and service-config-files templates host their payload by URL.** Apple downloads the cert/zip from an HTTPS URL you host; the bytes aren't embedded in the declaration.

---

## Built on

Edict stands on excellent open-source work: [NanoMDM](https://github.com/micromdm/nanomdm), [KMFDDM](https://github.com/jessepeterson/kmfddm), [micromdm/scep](https://github.com/micromdm/scep), [NanoDEP](https://github.com/micromdm/nanodep), [BlueSkyConnect](https://github.com/BlueSkyTools/BlueSkyConnect), and [MunkiReport](https://github.com/munkireport/munkireport-php). Declaration schemas are verified against [apple/device-management](https://github.com/apple/device-management).

Not affiliated with or endorsed by Apple. Apple, Mac, macOS, and Apple Business Manager are trademarks of Apple Inc.

## License

_TBD before publishing._
