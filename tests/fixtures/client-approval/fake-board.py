#!/usr/bin/env python3
"""tests/fixtures/client-approval/fake-board.py — a local fake product board
for the BH-9887 suites. Binds 127.0.0.1 on a free port; nothing leaves the box.

  fake-board.py --dir <d>        serve; writes <d>/port when it listens
  fake-board.py --selftest       start, answer one scripted call, exit 0

Script: <d>/script/<route>, read on EVERY request, so a test changes the
answer between runs. <route> is `request` (POST .../approval-requests) or
`comment` (POST .../comments). The file holds `<status> [<sleep-s>]` on line 1
and the body on the lines after it. No file: 404 with {"error":"not found"}.
Every request is appended to <d>/requests.jsonl as
{method, path, headers (Authorization -> "<redacted len=N>"), body}.
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def route_of(path):
    if path.endswith("/approval-requests"):
        return "request"
    if path.endswith("/comments"):
        return "comment"
    return "other"


def make_handler(d):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _do(self):
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n).decode("utf-8", "replace") if n else ""
            try:
                body = json.loads(raw) if raw else None
            except ValueError:
                body = raw
            hdrs = {}
            for k, v in self.headers.items():
                if k.lower() == "authorization":
                    v = "<redacted len=%d>" % len(v)
                    hdrs["authorization_ok"] = self.headers.get(k) == "Bearer " + os.environ.get("FAKE_BOARD_TOKEN", "tok-fake-board")
                hdrs[k.lower()] = v
            rec = {"method": self.command, "path": self.path, "headers": hdrs, "body": body}
            with open(os.path.join(d, "requests.jsonl"), "a") as f:
                f.write(json.dumps(rec) + "\n")
            status, sleep_s, out = 404, 0.0, '{"error":"not found"}'
            sf = os.path.join(d, "script", route_of(self.path))
            if os.path.isfile(sf):
                with open(sf) as f:
                    lines = f.read().split("\n", 1)
                head = lines[0].split()
                status = int(head[0])
                if len(head) > 1:
                    sleep_s = float(head[1])
                out = lines[1] if len(lines) > 1 else ""
            if sleep_s:
                time.sleep(sleep_s)
            data = out.encode()
            try:
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

        do_GET = _do
        do_POST = _do

    return H


def serve(d):
    os.makedirs(os.path.join(d, "script"), exist_ok=True)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(d))
    srv.daemon_threads = True
    tmp = os.path.join(d, "port.tmp")
    with open(tmp, "w") as f:
        f.write(str(srv.server_address[1]))
    os.replace(tmp, os.path.join(d, "port"))
    return srv


def selftest():
    import tempfile
    import urllib.request
    d = tempfile.mkdtemp(prefix="fake-board-")
    srv = serve(d)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    with open(os.path.join(d, "script", "request"), "w") as f:
        f.write('201\n{"id":"req_1"}')
    port = open(os.path.join(d, "port")).read()
    req = urllib.request.Request("http://127.0.0.1:%s/api/feature-board/tickets/t1/approval-requests" % port,
                                 data=b'{"prNumber":1}', method="POST",
                                 headers={"Authorization": "Bearer x", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as r:
        assert r.status == 201, r.status
        assert json.loads(r.read())["id"] == "req_1"
    rows = [json.loads(x) for x in open(os.path.join(d, "requests.jsonl"))]
    assert len(rows) == 1 and rows[0]["body"] == {"prNumber": 1}, rows
    assert "Bearer x" not in json.dumps(rows), rows
    srv.shutdown()
    print("fake-board selftest: ok")
    return 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    if len(argv) != 3 or argv[1] != "--dir":
        print(__doc__, file=sys.stderr)
        return 64
    srv = serve(argv[2])
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
