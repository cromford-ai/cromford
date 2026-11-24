#!/usr/bin/env python3
"""tests/fixtures/perf-probe-fake-server.bh-9786.py: the fake app the perf
probe suites drive (BH-9786). python3 stdlib only.

  python3 -I perf-probe-fake-server.bh-9786.py --port-file F --log L --state S
                                                [--handlers DIR]

It binds 127.0.0.1 on port 0 and writes the port to F. Each request appends
one JSON line to L: {t_ms, method, path, host, auth, cookie, body}. host is the
peer address. auth and cookie say only whether the header was sent; the value
of an Authorization header is never written.

S is a JSON file, read again on every request, so a test changes an answer
between runs without a restart:
  {"paths": {"<path>": {"status": 200, "body": "...", "json": {...},
                        "size": <n>, "delay_ms": <n>, "location": "<url>",
                        "set_cookie": "<cookie>"}}}
size pads the body to n bytes. json is sent as the body with a JSON type.
Before its 404, the server calls handle(req, state) of every module in DIR
(default: the perf-probe-fake.d directory next to this file), in name order.
The first answer that is not None wins: {"status", "body", "headers"}.
"""
import argparse
import importlib.util
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()


def load_handlers(d):
    mods = []
    if not os.path.isdir(d):
        return mods
    for name in sorted(os.listdir(d)):
        if not name.endswith(".py"):
            continue
        spec = importlib.util.spec_from_file_location("ppfake_" + name[:-3], os.path.join(d, name))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        if callable(getattr(mod, "handle", None)):
            mods.append(mod)
    return mods


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--handlers", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf-probe-fake.d"))
    a = ap.parse_args()
    handlers = load_handlers(a.handlers)

    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def _state(self):
            try:
                with open(a.state) as f:
                    return json.load(f)
            except (OSError, ValueError):
                return {}

        def _answer(self):
            n = int(self.headers.get("content-length") or 0)
            body = self.rfile.read(n).decode("utf-8", "replace") if n else ""
            path = self.path.split("?", 1)[0]
            rec = {
                "t_ms": int(time.time() * 1000),
                "method": self.command,
                "path": path,
                "host": self.client_address[0],
                "auth": self.headers.get("authorization") is not None,
                "cookie": self.headers.get("cookie") is not None,
                "body": body,
            }
            with LOCK:
                with open(a.log, "a") as f:
                    f.write(json.dumps(rec) + "\n")
            state = self._state()
            spec = (state.get("paths") or {}).get(path)
            if spec is not None:
                return self._send_spec(spec)
            req = {"method": self.command, "path": path, "headers": dict(self.headers), "body": body}
            for mod in handlers:
                out = mod.handle(req, state)
                if out is not None:
                    return self._send(out.get("status", 200), str(out.get("body", "")).encode(), out.get("headers") or {})
            return self._send(404, b"not found", {})

        def _send_spec(self, spec):
            if spec.get("delay_ms"):
                time.sleep(spec["delay_ms"] / 1000.0)
            headers = {}
            if "json" in spec:
                data = json.dumps(spec["json"]).encode()
                headers["content-type"] = "application/json"
            else:
                data = str(spec.get("body", "ok")).encode()
                headers["content-type"] = "text/html"
            if spec.get("size") is not None:
                data = (data + b" " * spec["size"])[: spec["size"]]
            if spec.get("location"):
                headers["location"] = spec["location"]
            if spec.get("set_cookie"):
                headers["set-cookie"] = spec["set_cookie"]
            return self._send(spec.get("status", 200), data, headers)

        def _send(self, status, data, headers):
            self.send_response(status)
            for k, v in headers.items():
                self.send_header(k, v)
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)

        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = _answer

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    tmp = a.port_file + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(srv.server_address[1]))
    os.replace(tmp, a.port_file)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
