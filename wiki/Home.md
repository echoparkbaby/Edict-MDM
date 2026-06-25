# Edict MDM — Server Setup Wiki

Edict is a **client**. It does not host MDM; it drives open-source servers that *you* run. This wiki is the end-to-end guide to standing those servers up: the Docker stack, the certificates you get from Apple, the network layout, and connecting the app.

If you only want to use the app against a stack someone already runs, skip to **[Connecting Edict](Connecting-Edict.md)**.

## What you're building

```
                          ┌───────────────────────────┐
   Macs (anywhere) ──TLS──▶  reverse proxy (public)    │  device-facing, internet-reachable
                          │  mdm.example.com           │
                          └───────────┬───────────────┘
                                      │  /mdm  /scep
              ┌───────────────────────┼────────────────────────────┐
              │   Docker host (private)                             │
              │                                                     │
              │   nanomdm ──▶ kmfddm ──▶ (DeclarativeManagement)    │
              │      │           │                                  │
              │     scep      enrollments sidecar    nanodep (opt)  │
              │      │           │                       │          │
              │      └───────────┴──── MySQL ────────────┘          │
              └─────────────────────────────────────────────────────┘
                                      ▲
                       admin APIs (private network only)
                                      │
                          ┌───────────┴───────────┐
                          │   Edict MDM (your Mac) │
                          └───────────────────────┘
```

Two planes, and keeping them separate is the whole security model:

- **Device-facing (public):** Macs must reach the **NanoMDM checkin** and **SCEP** endpoints over public HTTPS with a trusted certificate, from wherever they roam. Only these two paths are exposed.
- **Admin-facing (private):** the app talks to **KMFDDM**, the **enrollments sidecar**, and **NanoDEP** over a private network. These never touch the public proxy. See **[Networking & Remote Access](Networking-and-Remote-Access.md)**.

## The components

| Service | Project | Role |
|---|---|---|
| **NanoMDM** | [micromdm/nanomdm](https://github.com/micromdm/nanomdm) | Core MDM: enrollment checkin, command queue, APNs push |
| **KMFDDM** | [jessepeterson/kmfddm](https://github.com/jessepeterson/kmfddm) | Declarative Device Management: declarations, sets, enrollment associations |
| **SCEP** | [micromdm/scep](https://github.com/micromdm/scep) | Issues device identity certificates during enrollment |
| **MySQL 8** | — | Shared storage for the above |
| **enrollments sidecar** | ships with Edict | Small read-only API; NanoMDM has no "list enrollments" endpoint, so this reads its DB |
| **NanoDEP** *(optional)* | [micromdm/nanodep](https://github.com/micromdm/nanodep) | Apple Business Manager zero-touch enrollment |

## Pages

1. **[Prerequisites](Prerequisites.md)** — what you need before you start.
2. **[Apple Certificates](Apple-Certificates.md)** — the APNs push certificate, SCEP CA, and the ABM token. The one unavoidable Apple step.
3. **[Server Stack](Server-Stack.md)** — the Docker Compose stack, `.env`, and database init.
4. **[Networking & Remote Access](Networking-and-Remote-Access.md)** — public proxy vs. private admin APIs; Tailscale/Headscale.
5. **[Connecting Edict](Connecting-Edict.md)** — point the app at your servers.
6. **[Enrolling Macs](Enrolling-Macs.md)** — manual profiles and DEP.
7. **[Declarations & DDM](Declarations-and-DDM.md)** — the declaration library and status channel.
8. **[Troubleshooting](Troubleshooting.md)** — the common ways it goes wrong.

## What to expect

Plan on an evening. A small fleet runs comfortably on a 2-core / 2 GB Linux host with Docker. The work is mostly waiting on Apple (the push certificate) and getting one public HTTPS hostname pointed at the proxy. Everything in this wiki uses placeholders — `example.com`, `your-server`, `<tailnet-ip>` — substitute your own.
