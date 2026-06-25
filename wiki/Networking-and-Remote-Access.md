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

## TLS / SSL certificate (device-facing)

This is the ordinary HTTPS certificate on your MDM hostname — not the Apple push cert, not the SCEP CA. It's the single most common reason enrollment "works on my machine but fails on a fresh Mac," so get it right.

**Requirements Apple actually enforces:**

- **Publicly trusted CA.** Let's Encrypt, ZeroSSL, or any commercial CA. **Self-signed will not work** for over-the-air enrollment — the device has no way to trust it yet. (You *can* enroll with a self-signed cert only if you also push its root as a trusted certificate inside the enrollment profile, which is a chicken-and-egg most people shouldn't attempt.)
- **Serve the full chain — leaf + all intermediates.** This is the big one. If your proxy serves only the leaf certificate, *your* Mac may still connect (it already cached the intermediate from browsing) while a freshly-wiped Mac fails enrollment silently. Apple devices do **not** reliably fetch missing intermediates during enrollment. Always serve `fullchain`, never just `cert`.
- **CN / SAN must match** the hostname in the enrollment profile (`mdm.example.com`).
- **TLS 1.2 or newer.**

**Let's Encrypt makes this easy.** Caddy and Traefik fetch and renew automatically and serve the full chain by default. With nginx, point `ssl_certificate` at `fullchain.pem` (not `cert.pem`). Certs last ~90 days and auto-renew; if you issue manually, don't let it lapse — an expired cert stops every device at once.

**Verify before you enroll anything** — check the chain is complete from *outside* your network:

```
openssl s_client -connect mdm.example.com:443 -servername mdm.example.com -showcerts
```

You should see your leaf **and** the intermediate(s) up to a trusted root, with no "unable to get local issuer certificate" error. SSL Labs (`ssllabs.com/ssltest`) flags a broken chain as "Chain issues: incomplete" — fix that before going further.

**Admin APIs and TLS.** The admin services (KMFDDM, the sidecar, NanoDEP) run plain HTTP in this stack — which is fine **only because** the private path carrying them is already encrypted (a tailnet, WireGuard, or an SSH tunnel). If your private path is *not* encrypted (e.g. a flat LAN), either accept LAN-local trust, or put the admin APIs behind their own internal TLS proxy. Never expose them over plain HTTP on an untrusted network.

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
