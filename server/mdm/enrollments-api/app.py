"""Read-only enrollments listing + guarded purge for Edict MDM.

NanoMDM (v0.7.0) has no list-enrollments admin endpoint; this sidecar
reads its MySQL directly. GET /v1/enrollments lists everything;
DELETE /v1/enrollments/<device_id> purges an unenrolled device's rows
(409 while still enabled). HTTP Basic auth, same key as nanomdm's API.
"""
import base64
import json
import os
import re
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pymysql
from cryptography import x509

DB = dict(
    host=os.environ["DB_HOST"],
    user=os.environ["DB_USER"],
    password=os.environ["DB_PASS"],
    database=os.environ["DB_NAME"],
)
API_KEY = os.environ["API_KEY"]
AUTH_OK = "Basic " + base64.b64encode(f"nanomdm:{API_KEY}".encode()).decode()

LIST_QUERY = """
SELECT e.id, e.type, e.enabled, e.last_seen_at, e.created_at,
       d.serial_number,
       (SELECT u.user_short_name FROM users u WHERE u.device_id = e.device_id ORDER BY u.updated_at DESC LIMIT 1) AS user_short_name,
       (SELECT u.user_long_name  FROM users u WHERE u.device_id = e.device_id ORDER BY u.updated_at DESC LIMIT 1) AS user_long_name
FROM enrollments e
LEFT JOIN devices d ON e.device_id = d.id
ORDER BY e.last_seen_at DESC
"""

# Deletion order respects the FK graph:
#   command_results.id -> enrollments.id
#   enrollment_queue.id -> enrollments.id
#   enrollments.device_id -> devices.id
#   enrollments.user_id -> users.id
#   users.device_id -> devices.id
# cert_auth_associations has no FK but is keyed by enrollment id.
# Orphaned commands (no queue/result rows left) are swept afterwards.


def fetch_list():
    conn = pymysql.connect(**DB)
    try:
        with conn.cursor() as cur:
            cur.execute(LIST_QUERY)
            cols = [c[0] for c in cur.description]
            rows = [dict(zip(cols, r)) for r in cur.fetchall()]
    finally:
        conn.close()
    for r in rows:
        for k, v in r.items():
            if isinstance(v, datetime):
                r[k] = v.strftime("%Y-%m-%dT%H:%M:%SZ")
    return rows


def fetch_pushcert():
    conn = pymysql.connect(**DB)
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT topic, cert_pem FROM push_certs LIMIT 1")
            row = cur.fetchone()
    finally:
        conn.close()
    if not row:
        return None
    topic, pem = row
    cert = x509.load_pem_x509_certificate(pem.encode())
    return {
        "topic": topic,
        "not_after": cert.not_valid_after_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def fetch_command_result(command_uuid):
    conn = pymysql.connect(**DB)
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, status, result FROM command_results "
                "WHERE command_uuid=%s ORDER BY updated_at DESC LIMIT 1",
                (command_uuid,),
            )
            row = cur.fetchone()
    finally:
        conn.close()
    if not row:
        return None
    enrollment_id, status, result = row
    return {"enrollment_id": enrollment_id, "status": status, "result": result}


def purge_device(device_id):
    """Returns (http_status, payload_dict)."""
    conn = pymysql.connect(**DB)
    try:
        with conn.cursor() as cur:
            # Lock the device and its enrollment rows (InnoDB next-key locks
            # also block new enrollment inserts for this device_id) so a Mac
            # that re-enrolls between this check and the DELETEs waits for
            # the purge instead of being wiped mid-reactivation.
            cur.execute("SELECT id FROM devices WHERE id=%s FOR UPDATE", (device_id,))
            cur.execute(
                "SELECT id, enabled FROM enrollments WHERE device_id=%s FOR UPDATE",
                (device_id,),
            )
            rows = cur.fetchall()
            if not rows:
                return 404, {"error": "unknown device id"}
            if any(enabled for (_id, enabled) in rows):
                return 409, {"error": "device still has enabled enrollments — unenroll first"}
            ids = [r[0] for r in rows]
            ph = ",".join(["%s"] * len(ids))
            deleted = {}
            cur.execute(f"DELETE FROM command_results WHERE id IN ({ph})", ids)
            deleted["command_results"] = cur.rowcount
            cur.execute(f"DELETE FROM enrollment_queue WHERE id IN ({ph})", ids)
            deleted["enrollment_queue"] = cur.rowcount
            cur.execute(f"DELETE FROM cert_auth_associations WHERE id IN ({ph})", ids)
            deleted["cert_auth_associations"] = cur.rowcount
            cur.execute("DELETE FROM enrollments WHERE device_id=%s", (device_id,))
            deleted["enrollments"] = cur.rowcount
            cur.execute("DELETE FROM users WHERE device_id=%s", (device_id,))
            deleted["users"] = cur.rowcount
            cur.execute("DELETE FROM devices WHERE id=%s", (device_id,))
            deleted["devices"] = cur.rowcount
            cur.execute(
                """DELETE c FROM commands c
                   LEFT JOIN enrollment_queue q ON c.command_uuid = q.command_uuid
                   LEFT JOIN command_results r ON c.command_uuid = r.command_uuid
                   WHERE q.command_uuid IS NULL AND r.command_uuid IS NULL"""
            )
            deleted["commands"] = cur.rowcount
        conn.commit()
        return 200, {"purged": device_id, "deleted": deleted}
    finally:
        conn.close()


class Handler(BaseHTTPRequestHandler):
    server_version = "edict-enrollments/2"

    def _authed(self):
        if self.headers.get("Authorization", "") != AUTH_OK:
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="enrollments"')
            self.end_headers()
            return False
        return True

    def _json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self._authed():
            return
        path = self.path.split("?")[0]
        m = re.fullmatch(r"/v1/commandresult/([0-9a-fA-F-]+)", path)
        if m:
            try:
                info = fetch_command_result(m.group(1))
                if info is None:
                    self._json(404, {"error": "no result yet"})
                else:
                    self._json(200, info)
            except Exception as e:
                self._json(502, {"error": str(e)})
            return
        if path == "/v1/pushcert":
            try:
                info = fetch_pushcert()
                if info is None:
                    self._json(404, {"error": "no push certificate stored"})
                else:
                    self._json(200, info)
            except Exception as e:
                self._json(502, {"error": str(e)})
            return
        if path != "/v1/enrollments":
            self._json(404, {"error": "not found"})
            return
        try:
            self._json(200, fetch_list())
        except Exception as e:
            self._json(502, {"error": str(e)})

    def do_DELETE(self):
        if not self._authed():
            return
        m = re.fullmatch(r"/v1/enrollments/([A-Za-z0-9:-]+)", self.path.split("?")[0])
        if not m:
            self._json(404, {"error": "not found"})
            return
        try:
            status, payload = purge_device(m.group(1))
            self._json(status, payload)
        except Exception as e:
            self._json(502, {"error": str(e)})

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("", 8080), Handler).serve_forever()
