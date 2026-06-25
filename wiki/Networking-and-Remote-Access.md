# Networking & Remote Access

The single most important security decision is which services face the internet. Get this wrong and you've published a fleet-command API.

## Two planes

| Plane | Services | Exposure |
|---|---|---|
| **Device-facing** | NanoMDM checkin (`:9090`), SCEP (`:9094`) | **Public** HTTPS, trusted cert |
| **Admin** | KMFDDM (`:9093`), enrollments sidecar (`:9095`), NanoDEP | **Private** only — never on the public proxy |

Macs roam, so they must reach checkin + SCEP from anywhere. The admin APIs are only ever called by *you*, from the Edict app — so they never need a public address, and giving them one is a liability (the API key is the only thing between an attacker and `erase device`).

## Device-facing: the public reverse proxy

Put a TLS-terminating reverse proxy in front of NanoMDM and SCEP. Any of nginx, Caddy, Traefik, or Nginx Proxy Manager work. You need:

1. A public DNS record, e.g. `mdm.example.com`, resolving to your proxy.
2. A publicly trusted certificate (Let's Encrypt is fine; **self-signed will not work** — Apple rejects it during enrollment).
3. Two routes:
   - `https://mdm.example.com/mdm`  → `http://<docker-host>:9090`  (NanoMDM)
   - `https://mdm.example.com/scep` → `http://<docker-host>:9094`  (SCEP)

Caddy example (it gets you a Let's Encrypt cert automatically):

```caddyfile
mdm.example.com {
    reverse_proxy /mdm*  <docker-host>:9090
    reverse_proxy /scep* <docker-host>:9094
}
```

These two URLs are what your **enrollment profile** points devices at (see [Connecting Edict](Connecting-Edict.md)). Nothing else is published.

## Admin: keep it private

The app reaches KMFDDM, the enrollments sidecar, and NanoDEP directly. In `compose.yml` these bind to `${ADMIN_BIND}` — a **private** interface, not `0.0.0.0`. You have a few ways to make that private interface reachable from your Mac:

### Option A — Tailscale or Headscale (recommended)

The simplest secure path. Install Tailscale (or self-hosted **Headscale**) on the Docker host and on your Mac; they join the same tailnet. Set `ADMIN_BIND` to the host's **tailnet IP**. The admin ports are then reachable only over the encrypted tailnet, from devices you've authorized — nothing is exposed on the LAN or the internet.

```dotenv
ADMIN_BIND=100.x.y.z      # the Docker host's tailnet address
```

In Edict you'd point at `http://100.x.y.z:9093` etc.

**This is a recommendation, not a requirement.** It's the lowest-effort way to get a private, authenticated path that works off-LAN. Headscale gives you the same thing fully self-hosted if you'd rather not use Tailscale's coordination server.

### Option B — LAN + firewall

If the app only ever runs on the same LAN as the host, bind to the host's LAN IP and firewall the admin ports (`9093`, `9095`) to trusted source addresses. Simpler, but you lose access when you're off-network.

### Option C — any VPN, or local-only

Reach the private interface over WireGuard/OpenVPN/an SSH tunnel, or — if Edict runs **on the Docker host itself** — set `ADMIN_BIND=127.0.0.1` and the admin APIs never leave the box.

Whatever you pick, the rule is the same: **admin APIs are private, device APIs are public.** Don't put `9093`/`9095` behind the public proxy.

## Firewall summary

| Port | Service | Open to |
|---|---|---|
| 443 (proxy) | NanoMDM `/mdm`, SCEP `/scep` | Public internet |
| 9090, 9094 | NanoMDM, SCEP (origin) | The proxy only |
| 9093 | KMFDDM | Private network / tailnet |
| 9095 | enrollments sidecar | Private network / tailnet |
| 9001 (if used) | NanoDEP | Private network / tailnet |
| 3306 | MySQL | Nothing — internal Docker network only |

If you run a homelab inventory or DNS, add the public hostname and the proxy route there too.
