# NanoDEP — Automated Device Enrollment (DEP) for Edict MDM

This is the server-side companion to Edict's **Device Management → Auto-Enroll (DEP)**
view. It's **optional** — only orgs that use **Apple Business Manager** (ABM) or
**Apple School Manager** (ASM) and want zero-touch enrollment need it.

NanoDEP ([micromdm/nanodep](https://github.com/micromdm/nanodep)) is a proxy in
front of Apple's DEP cloud API (`mdmenrollment.apple.com`). It holds your ABM
MDM-server token and lets Edict list ABM-assigned devices, define DEP enrollment
profiles, assign them, and auto-assign new devices.

> ⚠️ Edict's DEP UI is built to NanoDEP + Apple's DEP spec but has **not** been
> verified end-to-end against a live ABM token. Test against a non-production ABM
> server first.

## Prerequisites

- An **Apple Business Manager** (or School Manager) account (free; needs a D-U-N-S).
- Devices in ABM — bought through Apple/a linked reseller, or hand-added via Apple
  Configurator. NanoDEP does nothing for devices ABM doesn't know about.
- The existing Edict MDM stack (NanoMDM + MySQL). The `nanodep` database is already
  created by `initdb/00-databases.sql`.

## 1. Add the compose service

Append to the MDM stack compose (matches the stack's parametric build pattern). Bind
the port to the **tailnet interface only** — NanoDEP has no device-facing traffic, so
it never needs public/LAN exposure.

```yaml
  nanodep:
    build:
      <<: *svc-build
      args:
        REPO: https://github.com/micromdm/nanodep.git
        TAG: v0.6.0
        CMD: ./cmd/depserver
    image: mdm/nanodep:v0.6.0
    container_name: mdm-nanodep
    restart: unless-stopped
    command:
      - "-api"
      - "${NANODEP_API_KEY}"
      - "-storage"
      - "mysql"
      - "-storage-dsn"
      - "mdm:${MYSQL_APP_PW}@tcp(mdm-db:3306)/nanodep"
      - "-listen"
      - ":9001"
    ports:
      - "192.0.2.10:9001:9001"   # tailnet-only (replace with your tailnet IP)
    depends_on:
      mdm-db:
        condition: service_healthy
```

Add `NANODEP_API_KEY=<a strong unique key>` to `.env` (mode 600) and mirror it to
your secret store. Then `docker compose up -d nanodep`.

## 2. Load your ABM token (one-time, server-side)

NanoDEP needs the encrypted MDM-server token from ABM. The token exchange uses a
keypair NanoDEP generates:

1. **Generate the keypair / get the public key** for a DEP name (e.g. `default`):
   `PUT /v1/tokenpki/default` then `GET /v1/tokenpki/default` returns the public key
   certificate (`.pem`). Auth: HTTP Basic `depserver:<NANODEP_API_KEY>`.
2. **In ABM:** Settings → add an **MDM Server**, upload that public key, then
   **download the server token** (a `.p7m`).
3. **Upload the token to NanoDEP:** decrypt + store it via `PUT /v1/tokens/default`
   (NanoDEP's `deptokens` CLI tool does the decrypt + upload; see the project's
   [operations guide](https://github.com/micromdm/nanodep/blob/main/docs/operations-guide.md)).

Verify: `GET /proxy/default/account` (Basic auth) returns your ABM org/server detail —
the same call Edict's **Test / refresh** button makes.

## 3. Auto-assignment syncer (optional)

For *new* ABM devices to enroll on their own, NanoDEP's **`depsyncer`** must run
periodically — it pulls the device list and applies the auto-assigner profile (the one
Edict's "Set as auto-assigner" sets via `PUT /v1/assigner/default`). Run it on a cron
or as a small loop sidecar. Without the syncer, assignment only happens when you press
Assign in Edict.

## 4. Point Edict at it

In the app: **Settings → Device Management → NanoDEP** —
- **NanoDEP URL:** `http://<tailnet-ip>:9001`
- **DEP name:** `default` (whatever `-name` you used)
- **API Key:** `NANODEP_API_KEY`

Then **Device Management → Auto-Enroll (DEP)** lists ABM devices, builds DEP profiles,
and assigns them.

## Security notes

- NanoDEP is **admin-only / outbound** — no inbound device traffic, so keep its port
  tailnet-only (above). It does **not** belong on the public reverse proxy.
- It holds your **ABM server token** and Apple OAuth tokens — sensitive. Keep `.env`
  600 and the storage DB access restricted.
- It can assign enrollment profiles fleet-wide but cannot issue device commands
  (no lock/erase) — smaller blast radius than NanoMDM/nanocmd.
