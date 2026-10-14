#!/bin/bash
# tests/lead-protected-paths-seed.bh-4140-test.sh — the one-time seed of the
# lead_protected_paths rows from catalog/lead-protected-paths.tsv (BH-4146,
# BH-4140.1). Drives the real bin/lead-protected-paths-seed.sh over the real
# transport (bin/jobs-client.sh -> curl) to a loopback stub that keeps a live
# (repo, glob) set and answers like the worker route: 201 on a new add, 200 on
# a repeat, 500 for the one glob it is told to fail.
#
#   S1  first run over the real TSV: `added 31, already 0`, rc 0, 31 PUTs,
#       each op=add, added_by=seed:BH-4140, repo example-org/cromford.
#   S2  second run: `added 0, already 31`, rc 0.
#   S3  one PUT answers 500: rc != 0, `failed 1` in the output, the glob named
#       on stderr, and the other 30 still sent.
#   S4  an empty JOBS_URL: rc 2, no request. A comment-only --tsv, or a
#       malformed line: rc 1, no request.
#   S5  -h prints the header and sends nothing.
# Run from anywhere: tests/lead-protected-paths-seed.bh-4140-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SEED="$DIR/bin/lead-protected-paths-seed.sh"
TSV="$DIR/catalog/lead-protected-paths.tsv"
# TEST-CHANGE (merge of main, 2026-10-04): the expected count is the catalog's
# own glob count, not a literal 31. Main grew the catalog to 35 while this PR
# was open; the assertions are unchanged, only the number is derived.
N=$(grep -v '^#' "$TSV" | grep -cv '^[[:space:]]*$')
[ "$N" -gt 1 ] || { echo "FAIL: catalog holds $N globs"; exit 1; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

REQS="$T/requests.log"; : > "$REQS"
FAILGLOB="$T/fail-glob"; : > "$FAILGLOB"
cat > "$T/server.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
LOG, FAILF = sys.argv[1], sys.argv[2]
LIVE = set()
class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_PUT(self):
        n = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(n).decode("utf-8", "replace")
        with open(LOG, "a") as fh:
            fh.write("%s %s %s\n" % (self.command, self.path, raw.replace("\n", "")))
        if self.headers.get("authorization") != "Bearer test-secret":
            return self._send(401, {"error": "unauthorized"})
        b = json.loads(raw)
        if b["glob"] == open(FAILF).read().strip():
            return self._send(500, {"error": "boom"})
        k = (b["repo"].lower(), b["glob"])
        if k in LIVE:
            return self._send(200, {"created": False})
        LIVE.add(k)
        return self._send(201, {"created": True})
    def log_message(self, *a):
        pass
s = HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
PY
python3 "$T/server.py" "$REQS" "$FAILGLOB" > "$T/port" 2>/dev/null &
SRV_PID=$!
trap 'kill "$SRV_PID" 2>/dev/null; __scratch_exit_trap' EXIT
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT=$(cat "$T/port" 2>/dev/null)
[ -n "$PORT" ] || { echo "FAIL: the loopback worker did not start"; echo "lead-protected-paths-seed: $PASS pass, 1 fail"; exit 1; }
STUB="http://127.0.0.1:$PORT"
mkdir -p "$T/h/logs"
puts() { grep -c '^PUT /api/lead-protected-paths ' "$REQS" 2>/dev/null; }
seed() { HARNESS="$T/h" HARNESS_SECRET=test-secret JOBS_URL="$STUB" JOBS_RETRIES=0 "$SEED" "$@"; }

# S1 ────────────────────────────────────────────────────────────────────────────
OUT=$(seed 2>"$T/err1"); RC=$?
[ "$RC" = 0 ] && ok || bad "S1 rc=$RC (want 0); stderr: $(cat "$T/err1")"
[ "$OUT" = "added $N, already 0" ] && ok || bad "S1 stdout '$OUT' (want 'added $N, already 0')"
[ "$(puts)" = "$N" ] && ok || bad "S1 saw $(puts) PUTs (want $N)"
BAD=$(cut -d' ' -f3- "$REQS" | python3 -c '
import json, sys
bad = 0
for line in sys.stdin:
    b = json.loads(line)
    if not (b.get("op") == "add" and b.get("added_by") == "seed:BH-4140" and b.get("repo") == "example-org/cromford" and b.get("glob")):
        bad += 1
print(bad)')
[ "$BAD" = 0 ] && ok || bad "S1 $BAD PUT bodies were not {repo:example-org/cromford, op:add, added_by:seed:BH-4140}"
SENT=$(cut -d' ' -f3- "$REQS" | python3 -c 'import json,sys; print("\n".join(json.loads(l)["glob"] for l in sys.stdin))')
WANT=$(grep -v '^#' "$TSV" | grep -v '^$' | cut -f2)
[ "$SENT" = "$WANT" ] && ok || bad "S1 the globs sent are not the TSV's, in order"

# S2 ────────────────────────────────────────────────────────────────────────────
OUT=$(seed 2>/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "S2 rc=$RC (want 0)"
[ "$OUT" = "added 0, already $N" ] && ok || bad "S2 stdout '$OUT' (want 'added 0, already $N')"

# S3 ────────────────────────────────────────────────────────────────────────────
: > "$REQS"
printf '%s\n' 'bin/lead-verdict.sh' > "$FAILGLOB"
OUT=$(seed 2>"$T/err3"); RC=$?
[ "$RC" != 0 ] && ok || bad "S3 rc=0 on a 500 (want non-zero)"
[ "$OUT" = "added 0, already $((N-1)), failed 1" ] && ok || bad "S3 stdout '$OUT' (want 'added 0, already $((N-1)), failed 1')"
grep -q 'bin/lead-verdict.sh http=500' "$T/err3" && ok || bad "S3 stderr does not name the failed glob: $(cat "$T/err3")"
[ "$(puts)" = "$N" ] && ok || bad "S3 stopped early: $(puts) PUTs (want $N)"
: > "$FAILGLOB"

# S3b: no worker listening at all is a failure for every line, never 'already'
OUT=$(HARNESS="$T/h" HARNESS_SECRET=test-secret JOBS_URL="http://127.0.0.1:1" JOBS_RETRIES=0 "$SEED" 2>/dev/null); RC=$?
[ "$RC" = 1 ] && ok || bad "S3b rc=$RC on a dead worker (want 1)"
[ "$OUT" = "added 0, already 0, failed $N" ] && ok || bad "S3b stdout '$OUT'"

# S4 ────────────────────────────────────────────────────────────────────────────
: > "$REQS"
OUT=$(HARNESS="$T/h" HARNESS_SECRET=test-secret JOBS_URL= "$SEED" 2>"$T/err4"); RC=$?
[ "$RC" = 2 ] && ok || bad "S4 empty JOBS_URL rc=$RC (want 2)"
grep -q 'JOBS_URL is not configured' "$T/err4" && ok || bad "S4 no 'JOBS_URL is not configured' line"
printf '# only a comment\n\n' > "$T/empty.tsv"
seed --tsv "$T/empty.tsv" >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && ok || bad "S4 comment-only tsv rc=$RC (want 1)"
printf 'example-org/cromford\tok/**\nexample-org/cromford no-tab\n' > "$T/bad.tsv"
seed --tsv "$T/bad.tsv" >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && ok || bad "S4 malformed tsv rc=$RC (want 1)"
seed --tsv "$T/missing.tsv" >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && ok || bad "S4 missing tsv rc=$RC (want 1)"
[ "$(puts)" = 0 ] && ok || bad "S4 sent $(puts) PUTs before refusing (want 0)"

# S5 ────────────────────────────────────────────────────────────────────────────
OUT=$("$SEED" -h 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "S5 -h rc=$RC"
grep -q 'added_by=seed:BH-4140' <<<"$OUT" && ok || bad "S5 -h does not print the header"
[ "$(puts)" = 0 ] && ok || bad "S5 -h sent a request"

echo "lead-protected-paths-seed: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
