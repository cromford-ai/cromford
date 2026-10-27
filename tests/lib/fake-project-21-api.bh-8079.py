#!/usr/bin/env python3
# tests/lib/fake-project-21-api.bh-8079.py <dir> — a local stand-in for the project-21
# API (POST /v1/check), for the BH-8079 suites. No network beyond 127.0.0.1.
#
# <dir>/port   written at start: the port the server listens on (bound to 0).
# <dir>/mode   read per request: affected | clean | partial | zero | 500 | 429
#              | html | noarray | slow. A missing file reads as clean.
# <dir>/req.log  one line per request: `<METHOD> <path> <field>,<field>,...`
#              (the multipart field names, in order).
#
# The affected answer copies the shape of the live probe of
# https://project-21.example/v1/check made on 2026-10-23 (see the BH-8079 plan).
import json
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

DIR = sys.argv[1]

AFFECTED = {
    "checked": 2,
    "affected": [
        {
            "dependency": {"ecosystem": "npm", "name": "lodash", "version": "4.17.15"},
            "advisory_id": "GHSA-p6mc-m468-83gw",
            "cve_ids": ["CVE-2020-8203"],
            "severity": {"label": "high", "score": 7.4},
            "exploited": False,
            "fixed_in": "4.17.21",
            "action": "Upgrade lodash to 4.17.21 or later.",
            "url": "https://osv.dev/vulnerability/GHSA-p6mc-m468-83gw",
        },
        {
            "dependency": {"ecosystem": "npm", "name": "lodash", "version": "4.17.15"},
            "advisory_id": "GHSA-35jh-r3h4-6jhm",
            "cve_ids": ["CVE-2021-23337"],
            "severity": {"label": "high", "score": 7.2},
            "exploited": False,
            "fixed_in": "4.17.21",
            "action": "Upgrade lodash to 4.17.21 or later.",
            "url": "https://osv.dev/vulnerability/GHSA-35jh-r3h4-6jhm",
        },
    ],
    "skipped": [],
    "feed_cursor": 1182,
}


def mode():
    try:
        with open(os.path.join(DIR, "mode")) as f:
            return f.read().strip() or "clean"
    except OSError:
        return "clean"


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json", extra=None):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        fields = re.findall(rb'Content-Disposition: form-data; name="([^"]*)"', raw)
        with open(os.path.join(DIR, "req.log"), "a") as f:
            f.write("%s %s %s\n" % ("POST", self.path, ",".join(x.decode() for x in fields)))
        m = mode()
        if self.path != "/v1/check":
            return self._send(404, '{"error":"not found"}')
        if m == "slow":
            time.sleep(12)
            return self._send(200, json.dumps({"checked": 1, "affected": [], "skipped": []}))
        if m == "500":
            return self._send(500, '{"error":"internal"}')
        if m == "429":
            return self._send(429, '{"error":"rate limited"}', extra={"Retry-After": "60"})
        if m == "html":
            return self._send(200, "<html><body>maintenance</body></html>", "text/html")
        if m == "noarray":
            return self._send(200, json.dumps({"checked": 2, "skipped": []}))
        if m == "affected":
            return self._send(200, json.dumps(AFFECTED))
        if m == "partial":
            return self._send(200, json.dumps({"checked": 3, "affected": [],
                                               "skipped": [{"file": "go.sum", "reason": "partial_coverage"}],
                                               "feed_cursor": 1182}))
        if m == "zero":
            return self._send(200, json.dumps({"checked": 0, "affected": [], "skipped": [], "feed_cursor": 1182}))
        return self._send(200, json.dumps({"checked": 2, "affected": [], "skipped": [], "feed_cursor": 1182}))


srv = HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(DIR, "port.tmp"), "w") as f:
    f.write(str(srv.server_address[1]))
os.replace(os.path.join(DIR, "port.tmp"), os.path.join(DIR, "port"))
srv.serve_forever()
