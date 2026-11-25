# owner: BH-9786.6
# The health handler of the perf probe fake server
# (tests/fixtures/perf-probe-fake-server.bh-9786.py), filled by BH-9792 for
# the warm-up preflight of bin/perf-probe-warm.sh. It answers a request whose
# path is state["health_path"] (default /api/health) with
# state["health"]["status"] (default 200). Any other path: None.


def handle(req, state):
    if req.get("path") != state.get("health_path", "/api/health"):
        return None
    status = (state.get("health") or {}).get("status", 200)
    return {"status": status, "body": "ok" if status == 200 else "down"}
