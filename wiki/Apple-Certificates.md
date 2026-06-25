# Apple Certificates

Three pieces of cryptographic identity are in play. Only the first is unavoidable.

| What | Who issues it | Needed for | Renewal |
|---|---|---|---|
| **APNs MDM push certificate** | Apple (via a vendor-signed CSR) | Waking devices — without it nothing works | **Yearly** |
| **SCEP CA** | Self-generated on the host | Device identity during enrollment | Set your own lifetime |
| **DEP / ABM server token** | Apple Business Manager | Zero-touch enrollment (optional) | Yearly |

## 1. APNs MDM push certificate (required)

This is the step people get stuck on. Apple only issues MDM push certificates to **approved MDM vendors**. Self-hosters aren't vendors, so you get your Certificate Signing Request **counter-signed by a vendor** first, then Apple's portal accepts it.

The community route for the open-source MDM stack is **[mdmcert.download](https://mdmcert.download)** — a free service run by the MicroMDM community that signs your CSR so the Apple Push Certificates Portal will take it. (It is a third-party service; read its page and decide if you trust it. If your organization is itself an Apple-approved MDM vendor, you can sign your own CSR and skip it.)

The flow:

1. **Generate a private key and CSR** for push. Any standard OpenSSL CSR works, for example:
   ```
   openssl req -new -newkey rsa:2048 -nodes -keyout push.key -out push.csr -subj "/CN=Edict MDM Push"
   ```
   Keep `push.key` safe — you need it for the life of the certificate.
2. **Get the CSR signed** by mdmcert.download (or your vendor). It returns a signed request artifact.
3. **Upload to Apple.** Sign in to the **Apple Push Certificates Portal** at [identity.apple.com](https://identity.apple.com) with your organization's Managed Apple ID, choose *Create a Certificate*, and upload the signed request. Download the resulting **`.pem` push certificate**.
4. **Combine cert + key for NanoMDM.** NanoMDM wants the push identity as a **PKCS#12**:
   ```
   openssl pkcs12 -export -inkey push.key -in push.pem -out push.p12
   ```
5. **Load it into NanoMDM.** Upload the PKCS#12 through NanoMDM's push-certificate API (HTTP Basic auth, the `NANOMDM_API_KEY` from your `.env`). The exact endpoint and `-cert`/storage options are in NanoMDM's [operations guide](https://github.com/micromdm/nanomdm/blob/main/docs/operations-guide.md#push-certificate). The certificate's **Topic** (the `UID`/push topic, like `com.apple.mgmt.External.xxxx`) is what your enrollment profile must reference — NanoMDM reports it back after upload.

**Renewal:** push certificates expire after one year. **Renew the same certificate** in the Apple portal (don't create a new one) so enrolled devices keep working, then re-upload. Edict's **Enrollment** tab shows a live expiry countdown so this doesn't surprise you.

## 2. SCEP CA (self-generated)

SCEP issues each enrolling Mac a client identity certificate. You don't get this from Apple — the `scep` service **generates its own CA** in its depot directory on first start.

- On first `docker compose up`, `scep` writes `ca.pem` / `ca.key` into `./depot`. NanoMDM is pointed at `/depot/ca.pem` to validate enrolling clients.
- The **SCEP challenge** is a shared secret in `.env` (`SCEP_CHALLENGE`) that the enrollment profile presents. Pick a strong value.
- Back up the `./depot` directory. Losing the CA means re-enrolling every device.

Nothing else to do here — it's covered by the [Server Stack](Server-Stack.md) page.

## 3. DEP / ABM server token (optional)

Only needed for **zero-touch** enrollment of devices in Apple Business Manager. This drives the optional **NanoDEP** service and has its own page: **[server/mdm/nanodep-setup.md](../server/mdm/nanodep-setup.md)**.

In short: NanoDEP generates a keypair, you upload its public key to ABM as a new MDM Server, ABM hands back an encrypted server token, and you load that token into NanoDEP. Edict's **Auto-Enroll (DEP)** view then lists and assigns ABM devices.

## Keep these secret

The push private key, the SCEP CA key, the SCEP challenge, and the ABM token are the keys to your fleet. They live on the host and in your `.env` / depot — back them up to a secret manager, never commit them, and keep file modes tight (`.env` should be `600`).
