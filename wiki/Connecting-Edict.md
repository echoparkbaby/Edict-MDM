# Connecting Edict

With the stack up and the push certificate loaded, point the app at it.

## 1. Enter the server details

**Settings → Device Management.** Fill in the admin endpoints (the **private** addresses from [Networking & Remote Access](Networking-and-Remote-Access.md)) and their API keys. Keys are stored in the macOS Keychain, never on disk in plaintext.

| Field | Value | From |
|---|---|---|
| NanoMDM URL | `http://<admin-bind>:9090` | `ADMIN_BIND` + NanoMDM port |
| NanoMDM API key | `NANOMDM_API_KEY` | `.env` |
| KMFDDM URL | `http://<admin-bind>:9093` | `.env` `ADMIN_BIND` |
| KMFDDM API key | `KMFDDM_API_KEY` | `.env` |
| Enrollments URL | `http://<admin-bind>:9095` | sidecar |
| NanoDEP *(optional)* | `http://<admin-bind>:9001` | if you added it |

> The NanoMDM **admin** API (enqueue/push/pushcert) is what the app drives — point it at the private `:9090` admin bind, not the public proxy. The public `/mdm` URL is only for *devices*.

## 2. Test connection

Each server has a **Test connection** button. It calls the service's `/version` endpoint with your key and reports success, an auth failure (wrong key), or an unreachable host. Get a green check on all of them before moving on — every later feature depends on this path.

## 3. Build the enrollment profile

**Enrollment** tab. Edict personalizes and signs the enrollment `.mobileconfig` that devices install. It needs the **public** device-facing values:

- **MDM checkin URL:** `https://mdm.example.com/mdm`
- **SCEP URL:** `https://mdm.example.com/scep`
- **SCEP challenge:** the `SCEP_CHALLENGE` from `.env`
- **Push topic:** the Topic NanoMDM reported when you uploaded the push certificate (`com.apple.mgmt.External.…`)

The tab also shows your **push certificate expiry** countdown — renew before it lapses (see [Apple Certificates](Apple-Certificates.md)).

Sign the profile (with an Apple Developer ID or your organization's signing identity) so it installs without a "unsigned profile" warning, then hand it out — see **[Enrolling Macs](Enrolling-Macs.md)**.

## 4. You're connected

Once a Mac enrolls, it appears in the fleet table joined to its BlueSkyConnect row (if you run BSC) by serial number. From there: live inventory, the DDM status channel, compliance, and remote actions all hang off the same device. Author policy in **[Declarations & DDM](Declarations-and-DDM.md)**.
