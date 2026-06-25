# Declarations & DDM

Declarative Device Management is the modern half of Edict. Instead of pushing a command and hoping, you declare a desired state and the device reports back what it actually did. KMFDDM stores the declarations and sets; NanoMDM delivers them.

## The model in one minute

- A **declaration** is a typed policy: a configuration (passcode, software-update settings, screen sharing…), an **asset** (a certificate or file the device downloads), an **activation** (a predicate deciding which devices a configuration applies to), or a **management** declaration.
- A **set** is a named bundle of declarations. You assign a set to enrollments; KMFDDM tracks who has what.
- When a set or declaration changes, KMFDDM fires `DeclarativeManagement` at NanoMDM, which tells the affected Macs to re-sync. (This wiring is the `-enqueue` flag in [Server Stack](Server-Stack.md).)

## Authoring in Edict

**Device Management → Declarations → Add** opens a plain-English template gallery — no hand-typed JSON for the common cases:

- Enforce a macOS update (hard deadline)
- Software-update settings (the everyday default; recommended baseline)
- Status reporting (what the device reports back)
- Passcode policy
- Screen sharing
- External / network-drive restrictions
- Install a certificate
- Service config files (sshd / sudo / pam …)

Fill the form, drop the declaration into a **set**, and **Sync** to KMFDDM. The **sets grid** shows blast radius, flags configurations that won't take effect because they're missing an activation (and fixes them in one click), and previews exactly what a Mac in a set receives.

**Activation predicates** let a declaration self-target by device condition (OS version, model, etc.) instead of manual assignment.

### Certificates and service config files

These two templates deploy **files**, which DDM never embeds — the device downloads them from a URL you host. Edict builds the asset + configuration + activation for you, but you supply the file and the HTTPS URL. Full how-to is in the project README's *Deploying files* section.

## The status channel

The underused, most valuable part of DDM: the device reports state back. Edict's **per-device status view** surfaces what each Mac reports — OS, FileVault, software-update state and **failure reason** — plus any declaration-apply errors. This is how you know a policy landed, not just that you sent it.

KMFDDM exposes this at `/v1/status-values/<enrollment-id>` and `/v1/status-errors/<enrollment-id>`; Edict reads both and renders them in plain English.

## OS minimums

Declarations carry platform requirements — several are macOS 14+ or 15+, and a few (like service config files) need a **supervised** device. Each template states its requirement. The DDM *account* declaration types are iOS/iPadOS-only and intentionally not included. Older Macs that can't do DDM still enroll for inventory and commands; they just won't receive declarations.

## Export / import

Sync to KMFDDM is additive or mirror. You can also **export** the whole library to a `syncdir`/`ddm_examples` folder for version control, and **import** from files or from the server — so your declarations live in git alongside the rest of your infrastructure.
