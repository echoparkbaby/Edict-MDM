# Troubleshooting

The common ways the stack goes sideways, and what actually fixes them.

## Test connection fails / 401 from an admin API

- **401 Unauthorized:** the API key in Edict doesn't match `.env`. Each service has its own key (`NANOMDM_API_KEY`, `KMFDDM_API_KEY`); the username is the service name (`nanomdm`, `kmfddm`). Re-check both.
- **Connection refused / timeout:** the service is bound to `${ADMIN_BIND}` and you're connecting from somewhere that can't reach that interface. If you set it to a tailnet IP, confirm both machines are on the tailnet. If you set `127.0.0.1`, the app must run on the Docker host.
- Confirm from the host: `curl -u nanomdm:$NANOMDM_API_KEY http://<admin-bind>:9090/version`.

## Everything broke after the Docker host rebooted ("Could not connect to the server")

If `ADMIN_BIND` is a **tailnet IP**, Docker can start before Tailscale has brought that address up. The containers that publish ports on it (KMFDDM, the enrollments sidecar) then start **without their network**: `docker compose ps` shows `mdm-kmfddm` stuck in `Restarting`, `mdm-enrollments` lists no ports, and the KMFDDM log repeats a DNS error like `lookup mdm-db ... network is unreachable`. Services bound to `0.0.0.0` (NanoMDM, SCEP) look fine, which makes it confusing.

**Fix now** (once Tailscale is up): `docker compose up -d --force-recreate kmfddm enrollments`

**Stop it happening again:** make Docker wait for the tailnet address at boot. Create `/etc/systemd/system/docker.service.d/wait-tailscale.conf` (replace `100.x.y.z` with your `ADMIN_BIND`):

```ini
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
# Wait up to 90s for the tailnet address, then start Docker regardless.
ExecStartPre=/bin/sh -c "for i in $$(seq 90); do ip -4 -o addr show tailscale0 2>/dev/null | grep -q 100.x.y.z/ && exit 0; sleep 1; done; exit 0"
```

Then `sudo systemctl daemon-reload`. It takes effect on the next boot; running containers aren't touched. (`$$` is how systemd spells a literal `$`.) This assumes Tailscale runs as the `tailscaled` system service, not in a container.

## A Mac won't enroll

- **Public reachability:** the device must reach `https://mdm.example.com/mdm` from wherever it is. Test from off-LAN. DNS must resolve publicly and the route must hit your proxy.
- **Certificate trust:** Apple rejects self-signed certs during enrollment. The proxy must serve a **publicly trusted** cert (Let's Encrypt is fine). Check with `curl -v https://mdm.example.com/mdm` — no TLS warnings.
- **Incomplete TLS chain (the classic "works on my Mac, fails on a fresh one"):** if the proxy serves only the leaf cert and not its intermediates, an already-warmed Mac connects but a freshly-wiped device fails enrollment silently. Serve the **full chain**. Verify from off-network: `openssl s_client -connect mdm.example.com:443 -servername mdm.example.com -showcerts` should show the leaf *and* intermediate(s) with no "unable to get local issuer" error. See [Networking → TLS / SSL certificate](Networking-and-Remote-Access.md#tls--ssl-certificate-device-facing).
- **SCEP challenge mismatch:** the challenge in the enrollment profile must equal `SCEP_CHALLENGE` in `.env`. Rebuild the profile if you rotated it.
- **Profile not approved:** on modern macOS the user must approve the profile in System Settings → Device Management. It won't enroll silently unless it came via DEP.

## Enrolled but no inventory / not in the list

- The enrollments sidecar reads NanoMDM's DB directly. Check it: `curl -u nanomdm:$NANOMDM_API_KEY http://<admin-bind>:9095/v1/enrollments`. If the device is there but Edict isn't showing it, refresh.
- Inventory arrives on the device's first checkin after enrollment — give it a minute, or trigger a push.

## Devices don't respond to commands or declarations

- **Push certificate:** if APNs push isn't working, NanoMDM can't wake devices. Confirm the push cert is loaded and not expired (Edict's Enrollment tab shows the countdown). Re-upload if needed.
- **Topic mismatch:** the push Topic in the enrollment profile must match the uploaded push cert's Topic. Mismatched = silent no-ops.

## Declaration changes don't reach devices

- KMFDDM only triggers a re-sync if something actually changed; an unchanged assign returns `304` and that's normal.
- KMFDDM must be able to reach NanoMDM's enqueue endpoint (`-enqueue http://nanomdm:9000/v1/enqueue/` with `-enqueue-key`). They share the `mdm` Docker network, so this is internal — check `docker compose logs kmfddm` for enqueue errors.
- A configuration with no **activation** never applies. Edict's sets grid flags this; add an activation predicate.

## MySQL: changes to init SQL did nothing

Init scripts in `initdb/` run **only once**, against a fresh data volume. After first start, editing `00-databases.sql` has no effect. To re-init you must stop the stack and delete the `mdm-db-data` volume — which **destroys all enrollments**. Back up first, and prefer fixing data with a direct SQL connection over re-init.

## Push certificate expired

Renew the **same** certificate in the Apple Push Certificates Portal (don't create a new one, or every device unenrolls), then re-upload the new PKCS#12 to NanoMDM. See [Apple Certificates](Apple-Certificates.md).

## Where to look

- `docker compose logs -f nanomdm` / `kmfddm` / `scep` — service-level errors.
- `docker compose ps` — is everything healthy? `mdm-db` has a healthcheck; the others depend on it.
- The reverse proxy's access/error log — for device-facing reachability and TLS.
