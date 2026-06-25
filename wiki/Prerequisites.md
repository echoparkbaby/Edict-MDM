# Prerequisites

You need four things before the stack will do anything useful: a host, a public hostname, an Apple Business Manager account, and the Edict app.

## A Linux host with Docker

- Any Linux box that runs **Docker Engine + Compose v2**. A small VM or container is plenty — 2 vCPU / 2 GB RAM / 20 GB disk handles a small fleet.
- Your user should be in the `docker` group (or you run compose with `sudo`).
- The stack builds each Go service from source on first `up` (the upstream projects publish source, not always images at every tag), so the host needs outbound internet to clone the repos. After the first build the images are cached.

## A public hostname + TLS

Macs check in from anywhere, so the device-facing endpoints must be reachable on the public internet over HTTPS with a **publicly trusted** certificate (Apple rejects self-signed for enrollment).

You need:

- A DNS name you control, e.g. `mdm.example.com`, pointed at wherever your reverse proxy answers.
- A reverse proxy that terminates TLS (nginx, Caddy, Traefik, or Nginx Proxy Manager all work) with a Let's Encrypt (or other public CA) certificate.
- One inbound port open to the proxy (443).

Only **NanoMDM checkin** and **SCEP** are published this way. The admin APIs stay private — see **[Networking & Remote Access](Networking-and-Remote-Access.md)**.

## An Apple Business Manager account

- **Apple Business Manager** (ABM) or **Apple School Manager** is free but requires a **D-U-N-S number** for your organization. Sign up at [business.apple.com](https://business.apple.com).
- You need it to obtain the **APNs MDM push certificate** (without push, MDM can't wake devices) and, optionally, to use **DEP / zero-touch** enrollment.
- Full certificate walkthrough: **[Apple Certificates](Apple-Certificates.md)**.

## Macs to manage

- **macOS 14+** to be a useful DDM target; several declarations need macOS 15 or a **supervised** device. Older Macs can still be enrolled for inventory and commands, but won't get the newer declarative policies.
- Supervision comes automatically with **DEP** enrollment; manual enrollments are not supervised.

## The Edict app

- **macOS 14 or later** to run Edict itself.
- Built from this repo (`bash build-app.sh`) or a release build.

## Optional but recommended

- A **private network path** from your Mac to the admin APIs — Tailscale or Headscale is the easiest, but a LAN + firewall rules or any VPN works. This is a recommendation, not a requirement; see the networking page.
- A **secret manager** (Vaultwarden, 1Password, Bitwarden, a sealed `.env` backup) — the stack's `.env` holds every API key and the database passwords. Back it up somewhere that isn't the server.
- **BlueSkyConnect** if you want the SSH/Screen-Sharing remote-support side of Edict, and **MunkiReport** for extra inventory. Both are independent of the MDM stack.
