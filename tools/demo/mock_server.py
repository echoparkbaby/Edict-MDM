#!/usr/bin/env python3
"""Fake backends for Edict MDM README screenshots. Stdlib only, all data fictional.

Serves every API the main views hit, path-prefixed on one port:
  /bluesky/      BlueSky bs_*.json.php
  /nanomdm/      NanoMDM admin API
  /enroll/       enrollments sidecar
  /kmfddm/       KMFDDM admin API
  /munkireport/  blueconnect_api.php
Any auth is accepted. Unknown paths are logged as UNKNOWN.

  python3 -I mock_server.py [port]           run the server (default 18765)
  python3 -I mock_server.py --seed-library F write the DDM library JSON to F
"""
import base64, json, plistlib, sys, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

NOW = int(time.time())
NS = uuid.UUID("6f1c3d2e-0000-4000-8000-00000000abcd")

def iso(ago):  # seconds ago -> ISO8601 Z
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW - ago))

def local(ago):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(NOW - ago))

# name, full user, short, serial, os, model, model id, filevault, category, bsc id (None = MDM-only), mdm, online, last seen (s ago)
FLEET = [
    ("design-mbp-04",     "Ava Lindqvist",   "ava",     "C02ZK7LMQ6LR", "26.0.1", "MacBook Pro (14-inch, M4 Pro, 2024)", "Mac16,8",   True,  "Design",       101, True,  True,  60),
    ("Ava's MacBook Air", "Ava Lindqvist",   "ava",     "FVHX3QJ2M1TD", "15.6.1", "MacBook Air (13-inch, M3, 2024)",    "Mac15,12",  True,  "Design",       102, True,  True,  240),
    ("design-studio-01",  "Marcus Oyelaran", "marcus",  "J7WQ4RX9PK2C", "26.0.1", "Mac Studio (2025)",                  "Mac16,9",   True,  "Design",       103, True,  True,  30),
    ("design-mbp-07",     "Priya Raman",     "priya",   "K2LD8HV5NQ3W", "15.7",   "MacBook Pro (16-inch, M3 Max, 2023)", "Mac15,9",  False, "Design",       104, True,  False, 3 * 86400),
    ("edit-bay-imac-2",   "Theo Brandt",     "theo",    "D9RF6KT1XW4M", "15.6.1", "iMac (24-inch, M4, 2024)",           "Mac16,3",   True,  "Production",   105, True,  True,  120),
    ("render-mini-03",    "Render Service",  "render",  "G4NB2YC8ZL6P", "26.0.1", "Mac mini (2024)",                    "Mac16,11",  True,  "Production",   106, True,  True,  15),
    ("render-mini-04",    "Render Service",  "render",  "H8TC5WE3VR9J", "14.7.6", "Mac mini (2023)",                    "Mac14,3",   True,  "Production",   107, True,  True,  45),
    ("prod-mbp-11",       "Sofia Marchetti", "sofia",   "M3PV7AQ6DK1Z", "15.6.1", "MacBook Pro (14-inch, M3, 2023)",    "Mac15,3",   True,  "Production",   108, True,  False, 26 * 3600),
    ("frontdesk-imac",    "Front Desk",      "frontdesk","N6XJ1GB4TQ8H", "14.7.6", "iMac (24-inch, M1, 2021)",          "iMac21,1",  False, "Front Office", 109, True,  True,  300),
    ("office-mba-02",     "Jonah Whitfield", "jonah",   "P1KM9ZD7HC5R", "26.0.1", "MacBook Air (15-inch, M4, 2025)",    "Mac16,13",  True,  "Front Office", 110, True,  True,  90),
    ("accounts-mini",     "Dana Kowalczyk",  "dana",    "Q5RW3NF8LB2X", "15.6.1", "Mac mini (2023)",                    "Mac14,12",  True,  "Front Office", 111, True,  True,  600),
    ("loaner-mba-01",     "Loaner",          "loaner",  "R9DT6MJ2VP7K", "15.5",   "MacBook Air (13-inch, M2, 2022)",    "Mac14,2",   False, "Loaners",      112, False, False, 9 * 86400),
    ("kiosk-lobby",       "Kiosk",           "kiosk",   "S2HY8PC5XN4D", "14.7.6", "Mac mini (2020)",                    "Macmini9,1", True, "Loaners",      113, False, True,  200),
    ("Leo's MacBook Pro", "Leo Nakamura",    "leo",     "T7BL4KQ1WR6G", "26.0.1", "MacBook Pro (14-inch, M4, 2024)",    "Mac16,1",   True,  None,           None, True, True,  400),
]
CATEGORIES = ["Design", "Production", "Front Office", "Loaners"]

def eid(serial):
    return str(uuid.uuid5(NS, serial)).upper()

BY_EID = {eid(f[3]): f for f in FLEET if f[10]}
BY_SERIAL = {f[3]: f for f in FLEET}

# ---------- BlueSky ----------
def bs_hosts():
    hosts = []
    for (name, full, short, serial, osv, model, mid, fv, cat, bid, mdm, online, ago) in FLEET:
        if bid is None:
            continue
        hosts.append({
            "blueskyid": bid, "hostname": name, "sharingname": name, "username": "nwadmin",
            "status": "Connection is good" if online else "Offline",
            "lastSeen": local(ago), "timestamp": NOW - ago, "active": online,
            "sshPort": 22000 + bid, "vncPort": 24000 + bid, "category": cat,
            "favorite": name in ("design-studio-01", "frontdesk-imac"),
            "notes": {"render-mini-04": "Due for macOS 26 upgrade", "loaner-mba-01": "Checked out to visiting editor",
                      "frontdesk-imac": "Shared login, reception"}.get(name, ""),
            "serialnum": serial, "notify": False, "alert": False, "email": "",
        })
    return {"hosts": hosts, "serverFqdn": "bluesky.northwind.example",
            "activeCount": sum(1 for h in hosts if h["active"]), "categories": CATEGORIES,
            "blueSkyVersion": "2.5.1", "phpVersion": "7.4.33", "apiVersion": "1.1"}

# ---------- enrollments sidecar ----------
def enrollments():
    out = []
    for e, f in BY_EID.items():
        out.append({"id": e, "type": "Device", "enabled": 1, "last_seen_at": iso(f[12]),
                    "created_at": iso(120 * 86400), "serial_number": f[3],
                    "user_short_name": f[2], "user_long_name": f[1]})
        out.append({"id": e + ":" + str(uuid.uuid5(NS, f[2])).upper(), "type": "User", "enabled": 1,
                    "last_seen_at": iso(f[12]), "created_at": iso(120 * 86400), "serial_number": None,
                    "user_short_name": f[2], "user_long_name": f[1]})
    return out

PUSHCERT = {"topic": "com.apple.mgmt.External.4b1e9c62-2d7f-4a51-9e0b-7c3a5f18d204", "not_after": iso(-247 * 86400)}

# ---------- KMFDDM ----------
def status_values(e):
    f = BY_EID[e]
    t = iso(f[12])
    p = ".StatusItems."
    vals = [
        (p + "device.operating-system.family", "macOS"),
        (p + "device.operating-system.version", f[4]),
        (p + "device.model.marketing-name", f[5]),
        (p + "device.model.identifier", f[6]),
        (p + "device.identifier.serial-number", f[3]),
        (p + "diskmanagement.filevault.enabled", f[7]),
        (p + "softwareupdate.install-state", "downloading" if f[4].startswith("14") else "none"),
    ]
    if f[4] < "26":
        vals.append((p + "softwareupdate.pending-version.os-version", "26.0.1"))
    if f[0] == "render-mini-04":
        vals.append((p + "softwareupdate.failure-reason.reason", "Not enough free disk space to stage the update"))
    return {e: [{"path": a, "value": b, "timestamp": t} for a, b in vals]}

def status_errors(e):
    if BY_EID[e][0] == "design-mbp-07":
        return {e: [{"path": ".StatusItems.management.declarations.configurations", "timestamp": iso(3 * 86400),
                     "reason": "com.northwind.disk-restrictions: requires supervision"}]}
    return {e: []}

def decl(t, ident, payload):
    return {"Type": t, "Identifier": ident, "ServerToken": str(uuid.uuid5(NS, ident))[:8], "Payload": payload}

DECLARATIONS = [  # (declaration, sets)
    (decl("com.apple.configuration.passcode.settings", "com.northwind.passcode",
          {"MinimumLength": 12, "RequireAlphanumericPasscode": True, "MaximumInactivityInMinutes": 10,
           "MaximumFailedAttempts": 10}), ["baseline"]),
    (decl("com.apple.configuration.softwareupdate.settings", "com.northwind.softwareupdate.settings",
          {"AutomaticActions": {"Download": "AlwaysOn", "InstallOSUpdates": "AlwaysOn", "InstallSecurityUpdate": "AlwaysOn"},
           "Deferrals": {"MajorPeriodInDays": 30, "MinorPeriodInDays": 7}, "Notifications": True}), ["baseline"]),
    (decl("com.apple.configuration.softwareupdate.enforcement.specific", "com.northwind.enforce-26.0.1",
          {"TargetOSVersion": "26.0.1", "TargetLocalDateTime": "2026-11-03T18:00:00",
           "DetailsURL": "https://help.northwind.example/updates"}), ["baseline"]),
    (decl("com.apple.configuration.management.status-subscriptions", "com.northwind.status",
          {"StatusItems": [{"Name": n} for n in ("device.operating-system.version", "device.model.marketing-name",
                                                 "diskmanagement.filevault.enabled", "softwareupdate.install-state")]}),
     ["baseline", "design", "front-office", "loaners"]),
    (decl("com.apple.configuration.diskmanagement.settings", "com.northwind.disk-restrictions",
          {"Restrictions": {"ExternalStorage": "ReadOnly", "NetworkStorage": "Allowed"}}), ["front-office", "loaners"]),
    (decl("com.apple.configuration.screensharing.host.settings", "com.northwind.screensharing",
          {"PortOverride": 5900, "MaximumVirtualDisplays": 2}), ["design"]),
    (decl("com.apple.management.organization-info", "com.northwind.org",
          {"Name": "Northwind Studio", "Email": "it@northwind.example"}), ["baseline"]),
    (decl("com.apple.activation.simple", "com.northwind.activation.baseline",
          {"StandardConfigurations": ["com.northwind.passcode", "com.northwind.softwareupdate.settings",
                                      "com.northwind.enforce-26.0.1", "com.northwind.status"]}), ["baseline"]),
    (decl("com.apple.activation.simple", "com.northwind.activation.design",
          {"StandardConfigurations": ["com.northwind.screensharing", "com.northwind.status"]}), ["design"]),
    (decl("com.apple.activation.simple", "com.northwind.activation.shared-macs",
          {"StandardConfigurations": ["com.northwind.disk-restrictions", "com.northwind.status"],
           "Predicate": "(@status(device.model.family) == 'Mac')"}), ["front-office", "loaners"]),
]
DECL_BY_ID = {d["Identifier"]: (d, s) for d, s in DECLARATIONS}

def library_json():
    return [{"id": str(uuid.uuid5(NS, "lib" + d["Identifier"])).upper(),
             "json": base64.b64encode(json.dumps(d, separators=(",", ":")).encode()).decode(),
             "sets": sorted(s)} for d, s in DECLARATIONS]

# ---------- NanoMDM command results ----------
COMMANDS = {}  # uuid -> (enrollment id, request type)

def command_result(cmd_uuid):
    e, rt = COMMANDS[cmd_uuid]
    f = BY_EID.get(e.split(":")[0]) or FLEET[0]
    if rt == "DeviceInformation":
        body = {"QueryResponses": {"DeviceName": f[0], "OSVersion": f[4], "ProductName": f[6], "ModelName": f[5],
                                   "SerialNumber": f[3], "DeviceCapacity": 994.66, "AvailableDeviceCapacity": 512.3,
                                   "BatteryLevel": 0.82, "IsActivationLockEnabled": False,
                                   "WiFiMAC": "02:00:5e:10:00:%02x" % (hash(f[3]) % 255), "BuildVersion": "25A362"}}
    elif rt == "SecurityInfo":
        body = {"SecurityInfo": {"FDE_Enabled": f[7], "SystemIntegrityProtectionEnabled": True,
                                 "FirewallSettings": {"FirewallEnabled": f[0] != "frontdesk-imac", "BlockAllIncoming": False,
                                                      "StealthMode": f[8] == "Design"}}}
    elif rt == "ProfileList":
        body = {"ProfileList": [
            {"PayloadDisplayName": "Northwind MDM Enrollment", "PayloadIdentifier": "com.northwind.mdm.enroll",
             "PayloadUUID": str(uuid.uuid5(NS, "p1")).upper(), "IsManaged": True},
            {"PayloadDisplayName": "Northwind Wi-Fi", "PayloadIdentifier": "com.northwind.wifi",
             "PayloadUUID": str(uuid.uuid5(NS, "p2")).upper(), "IsManaged": True},
            {"PayloadDisplayName": "Privacy Preferences (Zoom, Slack)", "PayloadIdentifier": "com.northwind.pppc",
             "PayloadUUID": str(uuid.uuid5(NS, "p3")).upper(), "IsManaged": True}]}
    elif rt == "InstalledApplicationList":
        apps = [("Adobe Photoshop 2026", "com.adobe.Photoshop", "27.1.0"), ("Figma", "com.figma.Desktop", "125.6.4"),
                ("Google Chrome", "com.google.Chrome", "141.0.7390.66"), ("Slack", "com.tinyspeck.slackmacgap", "4.46.99"),
                ("Microsoft Word", "com.microsoft.Word", "16.102"), ("DaVinci Resolve", "com.blackmagic-design.DaVinciResolve", "20.2"),
                ("1Password", "com.1password.1password", "8.11.12"), ("zoom.us", "us.zoom.xos", "6.6.2")]
        body = {"InstalledApplicationList": [{"Name": n, "Identifier": i, "ShortVersion": v, "Version": v,
                                              "BundleSize": 400000000} for n, i, v in apps]}
    else:
        body = {}
    body.update({"Status": "Acknowledged", "CommandUUID": cmd_uuid, "UDID": e})
    return {"status": "Acknowledged", "result": plistlib.dumps(body).decode()}

# ---------- MunkiReport ----------
def mr_host(serial):
    f = BY_SERIAL.get(serial)
    if not f:
        return None
    major, *rest = (f[4].split(".") + ["0", "0"])[:3]
    osint = int(major) * 10000 + int(rest[0]) * 100 + int(rest[1])
    k = int(uuid.uuid5(NS, serial)) % 100
    total = 994662584320 if "Pro" in f[5] or "Studio" in f[5] else 494384795648
    free = int(total * (0.08 if f[0] == "render-mini-04" else 0.25 + k / 250))
    apps = [("Adobe Photoshop 2026", "27.1.0", True), ("Google Chrome", "141.0.7390.66", True), ("Slack", "4.46.99", True),
            ("Microsoft Office 365", "16.102", True), ("Zoom", "6.6.2", f[0] != "kiosk-lobby"),
            ("Figma", "125.6.4", f[8] == "Design")]
    return {
        "serial": serial,
        "machine": {"serial_number": serial, "computer_name": f[0], "hostname": f[0].lower().replace("'", "").replace(" ", "-") + ".local",
                    "machine_model": f[6], "machine_desc": f[5], "cpu": "Apple M-series", "cpu_arch": "arm64",
                    "number_processors": 12, "os_version": osint, "physical_memory": 36 if "Pro" in f[5] else 16,
                    "machine_name": f[5].split(" (")[0], "buildversion": "25A362"},
        "reportdata": {"timestamp": NOW - f[12], "console_user": f[2], "long_username": f[1], "remote_ip": "192.0.2.%d" % (10 + k),
                       "uptime": 86400 * (1 + k % 9), "machine_group": 0, "reg_timestamp": NOW - 200 * 86400, "uid": 501},
        "munkireport": {"version": "6.7.0", "runtype": "auto", "starttime": local(f[12] + 900), "endtime": local(f[12] + 840),
                        "errors": 1 if f[0] == "render-mini-04" else 0, "warnings": k % 3, "manifestname": "northwind-" + (f[8] or "default").lower().replace(" ", "-")},
        "filevault": {"filevault_status": "On" if f[7] else "Off", "filevault_users": f[2], "has_personal_recovery_key": 1 if f[7] else 0,
                      "has_institutional_recovery_key": 0, "conversion_percent": 100 if f[7] else 0, "conversion_state": "Complete" if f[7] else "Off"},
        "disk_report": {"totalsize": total, "freespace": free, "percentage": 100 - int(free * 100 / total), "smartstatus": "Verified",
                        "volumetype": "APFS", "media_type": "ssd", "volumename": "Macintosh HD", "encrypted": 1 if f[7] else 0},
        "power": {"cycle_count": 40 + k * 3, "condition": "Normal", "max_percent": 92 + k % 8, "current_percent": 70 + k % 30,
                  "externalconnected": "Yes", "ischarging": "No", "manufacturer": "Apple", "temperature": 3050} if ("Book" in f[5]) else None,
        "managed_installs": [{"name": n.replace(" ", ""), "display_name": n, "version": v, "size": 250000, "installed": i, "status": "installed" if i else "pending_install", "type": "munki"} for n, v, i in apps],
        "pending_installs": [],
        "users": [{"uid": 501, "gid": 20, "name": f[2], "username": f[2], "realname": f[1], "home": "/Users/" + f[2], "shell": "/bin/zsh",
                   "admin": False, "ssh_access": False, "last_login_ts": NOW - f[12] - 3600},
                  {"uid": 502, "gid": 20, "name": "nwadmin", "username": "nwadmin", "realname": "Northwind Admin", "home": "/Users/nwadmin",
                   "shell": "/bin/zsh", "admin": True, "ssh_access": True, "last_login_ts": NOW - 20 * 86400}],
        "network": [{"service_name": "Wi-Fi", "service_order": 1, "ipv4ip": "192.0.2.%d" % (10 + k), "ipv4mask": "255.255.255.0",
                     "ipv4router": "192.0.2.1", "ipv4dnsservers": "192.0.2.1", "ipv4searchdomains": "northwind.example",
                     "ipv6ip": "", "ethernet_macaddress": "02:00:5e:10:00:%02x" % k}],
        "wifi": {"service": "Wi-Fi", "ssid": "Northwind-Staff", "bssid": "02:00:5e:aa:00:01", "channel": 149, "security": "WPA3 Personal",
                 "rssi": -48 - k % 20, "noise": -92, "transmit_rate": "864", "country_code": "US"},
        "software_updates": {"recommendedupdates": 0 if f[4].startswith("26") else 1, "lastupdatesavailable": 0 if f[4].startswith("26") else 1,
                             "lastsuccessfuldate": local(5 * 86400), "lastfullsuccessfuldate": local(5 * 86400),
                             "auto_update": True, "auto_update_restart_required": False},
        "profiles": [{"name": "Northwind MDM Enrollment", "identifier": "com.northwind.mdm.enroll", "removaldisallowed": 1,
                      "payload_name": "MDM", "payload_display": "Mobile Device Management"},
                     {"name": "Northwind Wi-Fi", "identifier": "com.northwind.wifi", "removaldisallowed": 0,
                      "payload_name": "WiFi", "payload_display": "Wi-Fi"}],
        "timemachine": {"auto_backup": True, "last_success": local(86400), "server_display_name": "Northwind Backups",
                        "alias_volume_name": "Northwind Backups"} if f[8] == "Design" else None,
        "firewall": {"globalstate": 0 if f[0] == "frontdesk-imac" else 1, "stealthenabled": 1 if f[8] == "Design" else 0, "loggingenabled": 1},
        "security": {"gatekeeper": "Active", "sip": "Active", "activation_lock": "Disabled",
                     "firewall_state": "Off" if f[0] == "frontdesk-imac" else "On"},
    }

# ---------- HTTP ----------
class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        sys.stderr.write("%s %s\n" % (self.command, self.path))

    def send(self, code, obj=None, raw=None):
        body = raw if raw is not None else (b"" if obj is None else json.dumps(obj).encode())
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def unknown(self):
        sys.stderr.write("UNKNOWN %s %s\n" % (self.command, self.path))
        self.send(404, {"error": "not mocked"})

    def route(self):
        u = urlparse(self.path)
        p, q = unquote(u.path), parse_qs(u.query)
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        m = self.command
        if p.startswith("/bluesky/"):
            f = p[len("/bluesky/"):]
            if f == "bs_hosts.json.php": return self.send(200, bs_hosts())
            if f == "bs_blocklist.json.php":
                return self.send(200, {"count": 1, "items": [{"serial": "V3XN8QL2TD5F", "added_at": local(40 * 86400),
                                                               "blueskyid_at_block": 97, "note": "Retired, sold at auction"}]})
            if f == "bs_categories.json.php": return self.send(200, {"ok": True, "categories": CATEGORIES})
            if f in ("bs_host_update.json.php", "bs_host_action.json.php"): return self.send(200, {"ok": True})
            return self.unknown()
        if p.startswith("/nanomdm/"):
            f = p[len("/nanomdm/"):]
            if f == "version": return self.send(200, {"version": "v0.9.0"})
            if f.startswith("v1/push/"): return self.send(200, {"status": {}})
            if f.startswith("v1/enqueue/"):
                ids = f[len("v1/enqueue/"):].split(",")
                pl = None
                try:
                    pl = plistlib.loads(body)
                    for e in ids:
                        COMMANDS[pl["CommandUUID"]] = (e, pl["Command"]["RequestType"])
                except Exception as ex:
                    sys.stderr.write("enqueue parse: %s\n" % ex)
                return self.send(200, {"status": {}, "command_uuid": pl.get("CommandUUID") if isinstance(pl, dict) else None})
            return self.unknown()
        if p.startswith("/enroll/"):
            f = p[len("/enroll/"):]
            if f == "v1/enrollments": return self.send(200, enrollments())
            if f == "v1/pushcert": return self.send(200, PUSHCERT)
            if f.startswith("v1/commandresult/"):
                c = f.split("/")[-1]
                return self.send(200, command_result(c)) if c in COMMANDS else self.send(404, {"error": "no result"})
            if f.startswith("v1/enrollments/") and m == "DELETE": return self.send(409, {"error": "still enrolled"})
            return self.unknown()
        if p.startswith("/kmfddm/"):
            f = p[len("/kmfddm/"):]
            if f == "version": return self.send(200, {"version": "v0.7.0"})
            if f == "v1/declarations":
                return self.send(200, sorted(DECL_BY_ID)) if m == "GET" else self.send(204)
            if f.startswith("v1/declarations/"):
                ident = f[len("v1/declarations/"):]
                if m != "GET": return self.send(204)
                return self.send(200, DECL_BY_ID[ident][0]) if ident in DECL_BY_ID else self.send(404, {"error": "not found"})
            if f.startswith("v1/declaration-sets/"):
                ident = f[len("v1/declaration-sets/"):]
                return self.send(200, DECL_BY_ID.get(ident, (None, []))[1])
            if f.startswith(("v1/set-declarations/", "v1/enrollment-sets/")): return self.send(204)
            if f.startswith("v1/status-values/"):
                e = f.split("/")[-1]
                return self.send(200, status_values(e) if e in BY_EID else {})
            if f.startswith("v1/status-errors/"):
                e = f.split("/")[-1]
                return self.send(200, status_errors(e) if e in BY_EID else {})
            return self.unknown()
        if p.startswith("/munkireport/"):
            a = (q.get("action") or [""])[0]
            if a == "ping": return self.send(200, {"ok": True, "driver": "mysql"})
            if a == "host":
                h = mr_host((q.get("serial") or [""])[0])
                return self.send(200, h) if h else self.send(404, {"error": "serial not found"})
            return self.unknown()
        return self.unknown()

    do_GET = do_POST = do_PUT = do_DELETE = route

def selfcheck():
    assert len(FLEET) == 14 and len(BY_EID) == 12
    json.dumps(bs_hosts()); json.dumps(enrollments())
    for s in BY_SERIAL: json.dumps(mr_host(s))
    for e in BY_EID: json.dumps(status_values(e))
    COMMANDS["X"] = (next(iter(BY_EID)), "DeviceInformation")
    assert "QueryResponses" in command_result("X")["result"]
    for d, _ in DECLARATIONS:
        assert d["Type"] and d["Identifier"]

if __name__ == "__main__":
    selfcheck()
    if len(sys.argv) > 2 and sys.argv[1] == "--seed-library":
        with open(sys.argv[2], "w") as fh:
            json.dump(library_json(), fh)
        sys.exit(0)
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18765
    sys.stderr.write("mock on http://127.0.0.1:%d\n" % port)
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
