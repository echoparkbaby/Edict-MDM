# Enrolling Macs

Two ways in: hand the profile to a Mac (manual), or let Apple Business Manager assign it at setup (DEP / zero-touch).

## Manual enrollment

Best for Macs already in service, or a small fleet.

1. Build and sign the enrollment profile in Edict's **Enrollment** tab ([Connecting Edict](Connecting-Edict.md)).
2. Get the `.mobileconfig` onto the Mac. Options:
   - Email/AirDrop/download it, then double-click — **System Settings → General → Device Management** shows it pending; the user approves.
   - Install it over an existing **BlueSkyConnect** SSH session with `profiles install -type configuration -path enroll.mobileconfig` (still requires user approval on modern macOS).
3. The Mac runs SCEP to get its identity certificate, checks in to NanoMDM, and appears in Edict within a minute.

**Manual enrollments are not supervised.** Some DDM declarations and commands (e.g. service config files) require supervision, which only DEP provides. Inventory, most profiles, and many declarations work fine without it.

## DEP / zero-touch enrollment

Best for new Macs or a lab. Devices in **Apple Business Manager** enroll automatically during Setup Assistant, fully supervised, and can be made non-removable.

This needs the optional **NanoDEP** service and an ABM server token. Full walkthrough: **[server/mdm/nanodep-setup.md](../server/mdm/nanodep-setup.md)**.

Summary:

1. Stand up NanoDEP and load your ABM token (one time).
2. In Edict, **Device Management → Auto-Enroll (DEP)** lists the devices ABM has assigned to this MDM server.
3. Build a **DEP profile** (skip-screens, supervised, etc.) and assign it — or set it as the **auto-assigner** so new ABM devices get it automatically.
4. Wipe/restart the Mac; at Setup Assistant it enrolls on its own.

> Edict's DEP UI is built to the NanoDEP + Apple DEP spec but hasn't been verified end-to-end against a live ABM token. Test against a non-production ABM server first.

## Confirming enrollment

A freshly enrolled Mac shows up in the fleet table with its MDM status, OS, and (after first inventory) hardware/security detail. If it doesn't appear:

- Check the Mac reached the **public** checkin URL (cert trusted, DNS resolves off-LAN).
- Check the enrollments sidecar returns it: `curl -u nanomdm:$NANOMDM_API_KEY http://<admin-bind>:9095/v1/enrollments`.
- See **[Troubleshooting](Troubleshooting.md)**.

## Removing a Mac

Use **remote unenroll** from the device's detail pane (sends the `RemoveProfile`/unenroll), then the enrollments sidecar's guarded purge clears its rows once it's no longer enabled. Erasing or re-imaging a Mac leaves stale rows until purged.
