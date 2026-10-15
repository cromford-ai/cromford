#!/bin/bash
# tests/deploy-verify-smoke.bh-6786-test.sh — the post-merge prod smoke check
# must look like a page load, and may probe a per-project path.
#
# THE INCIDENT (2026-10-14 17:00Z). project-6-os `/` now redirects to `/os`,
# and Clerk answers a signed-out request that is not a page load with 404. The
# bare `curl -L` in bin/deploy-verify.sh sent no Accept / Sec-Fetch-Dest and
# the curl User-Agent, read 404 and paged deployfail:project-6-os:d33bbe7e.
#
# THE FIX. bin/lib/smoke-probe.sh:
#   smoke_code <url>        curl with browser document headers
#   smoke_url <proj> <base> <base> + the settings row deploy.<proj>.smoke_path,
#                           or <base> unchanged (no row, outage, invalid value)
#
# Driven through the real bin/deploy-verify.sh with the REAL curl against a
# local stub server that logs every request's path and headers. gh, beat.sh and
# bin/jobs-client.sh are stubbed. The helper is copied by the closure only when
# deploy-verify sources it, so at the merge base the suite goes red on its
# assertions, not on a missing file.
# Run from anywhere: bash tests/deploy-verify-smoke.bh-6786-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v curl >/dev/null || { echo "curl missing — skipping"; exit 0; }

# ── the stub server: Clerk-shaped answers, every request logged ──────────────
mkdir -p "$T/srv"
cat > "$T/srv/stub.py" <<'PY'
import http.server, json, os, sys
T = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_GET(self):
        with open(os.path.join(T, "req.log"), "a") as f:
            f.write(json.dumps({"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}}) + "\n")
        try:
            mode = open(os.path.join(T, "srvmode")).read().strip()
        except OSError:
            mode = "clerk"
        p = self.path.split("?")[0]
        doc = "text/html" in self.headers.get("Accept", "") and self.headers.get("Sec-Fetch-Dest", "") == "document"
        if mode == "dead":
            return self.answer(500)
        if mode == "all404":
            return self.answer(404)
        if mode == "ok":
            return self.answer(200)
        if p == "/sign-in":
            return self.answer(200)
        if p in ("/", "/os") and doc:
            return self.answer(307, "/os" if p == "/" else "/sign-in?redirect_url=%2Fos")
        return self.answer(404)
    def answer(self, code, loc=None):
        self.send_response(code)
        if loc:
            self.send_header("Location", loc)
        self.send_header("Content-Length", "0")
        self.end_headers()
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(T, "port"), "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 -I "$T/srv/stub.py" "$T" >/dev/null 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null' EXIT
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
[ -s "$T/port" ] || { echo "FAIL: stub server did not start"; exit 1; }
BASE="http://127.0.0.1:$(cat "$T/port")"

# ── the scratch harness: real scripts, stubbed edges ─────────────────────────
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/env" "$T/fakebin" "$T/build" "$T/settings"
# The settings client: setting_get answers from $T/settings/<key>.
#   absent file -> rc 2 (no row)   "OUTAGE" -> rc 1   anything else -> rc 0, the value
cat > "$H/bin/jobs-client.sh" <<EOF
setting_get() {
  printf '%s\n' "\$1" >> "$T/keys.txt"
  [ -f "$T/settings/\$1" ] || return 2
  local v; v=\$(cat "$T/settings/\$1")
  [ "\$v" = OUTAGE ] && return 1
  printf '%s' "\$v"
}
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> '"$T"'/beat.txt\nexit 0\n' > "$H/bin/beat.sh"
scratch_install_closure bin/deploy-verify.sh "$H" >/dev/null || { echo "FAIL: closure install"; exit 1; }
cp "$DIR/bin/prod-url.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
chmod +x "$H/bin/"*.sh
printf 'tproj o/tproj %s - 2 box-t 192.0.2.9\n' "$BASE" > "$H/fleet.conf"
: > "$H/env/global.env"; : > "$H/env/tproj.env"

# gh: the deployments API is readable and the production deployment succeeded.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *deployments/*statuses*) echo success ;;
  *deployments/77*) echo "" ;;
  *deployments*) echo '[{"id":77,"environment":"production","created_at":"2026-10-15T00:00:00Z"}]' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

RESET() {
  : > "$T/build/pipeline.log"; : > "$H/logs/ALERTS.log"; : > "$T/beat.txt"; : > "$T/req.log"; : > "$T/keys.txt"
  rm -f "$T/settings/"*
}
ROW() { printf '%s' "$2" > "$T/settings/$1"; }
MODE() { printf '%s' "$1" > "$T/srvmode"; }
DV() { # DV -> rc of the real deploy-verify; stderr kept in $T/dv.err
  ( PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" CONSOLE_URL="" HARNESS_SECRET="" \
      bash "$H/bin/deploy-verify.sh" tproj o/tproj deadbeefdeadbeef "$T/build" >/dev/null 2>"$T/dv.err" )
}
PIPE() { cat "$T/build/pipeline.log"; }
REQ1() { head -n 1 "$T/req.log" | jq -r "$1"; }

# ============================================================================
# A1. Clerk-shaped prod, no smoke_path row, github path: healthy.
# ============================================================================
RESET; MODE clerk
DV; RC=$?
[ "$RC" = 0 ] && ok || bad "A1: a Clerk prod that 307s documents to 200 must verify (rc=$RC, alerts: $(cat "$H/logs/ALERTS.log"))"
[ -s "$H/logs/ALERTS.log" ] && bad "A1: no ALERTS line expected ($(cat "$H/logs/ALERTS.log"))" || ok
[ -s "$T/beat.txt" ] && bad "A1: no beat expected ($(cat "$T/beat.txt"))" || ok
[ "$(REQ1 '.headers["sec-fetch-dest"] // ""')" = document ] && ok || bad "A1: the probe must send Sec-Fetch-Dest: document (got: $(head -n1 "$T/req.log"))"
[ "$(REQ1 '.headers["sec-fetch-mode"] // ""')" = navigate ] && ok || bad "A1: the probe must send Sec-Fetch-Mode: navigate"
[ "$(REQ1 '.headers.accept // ""')" = 'text/html,application/xhtml+xml' ] && ok || bad "A1: the probe must send Accept: text/html,application/xhtml+xml"
case "$(REQ1 '.headers["user-agent"] // ""')" in Mozilla/5.0*) ok ;; *) bad "A1: the probe must send a browser User-Agent (got: $(REQ1 '.headers["user-agent"]'))" ;; esac
[ "$(REQ1 .path)" = / ] && ok || bad "A1: with no row the probe must ask the bare prod URL (got: $(REQ1 .path))"
grep -q "deploy-verify OK: prod deployed deadbeef, $BASE -> 200" <<<"$(PIPE)" && ok || bad "A1: the OK line must name the URL and 200 (got: $(PIPE))"
grep -qx 'deploy.tproj.smoke_path' "$T/keys.txt" && ok || bad "A1: the row read must be deploy.tproj.smoke_path (asked: $(cat "$T/keys.txt"))"

# ============================================================================
# A2. Row /sign-in: the probe asks that path first, and the OK line names it.
# ============================================================================
RESET; MODE clerk; ROW deploy.tproj.smoke_path /sign-in
DV; RC=$?
[ "$RC" = 0 ] && ok || bad "A2: row /sign-in on a healthy prod must verify (rc=$RC)"
[ "$(REQ1 .path)" = /sign-in ] && ok || bad "A2: the first request must be /sign-in (got: $(REQ1 .path))"
grep -q "/sign-in -> 200" <<<"$(PIPE)" && ok || bad "A2: pipeline.log must carry '/sign-in -> 200' (got: $(PIPE))"

# ============================================================================
# A3. A dead prod with a smoke path still pages.
# ============================================================================
RESET; MODE dead; ROW deploy.tproj.smoke_path /sign-in
DV; RC=$?
[ "$RC" = 1 ] && ok || bad "A3: a 500 prod must FAIL (rc=$RC)"
[ "$(grep -c 'DEPLOY-VERIFY FAILED' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "A3: exactly one ALERTS line expected ($(cat "$H/logs/ALERTS.log"))"
grep -q "prod smoke check $BASE/sign-in returned HTTP 500" "$H/logs/ALERTS.log" && ok || bad "A3: the ALERTS line must name the probed URL and 500 ($(cat "$H/logs/ALERTS.log"))"
[ "$(grep -c '"akey":"deployfail:tproj:' "$T/beat.txt")" = 1 ] && ok || bad "A3: one deployfail:tproj: beat expected ($(cat "$T/beat.txt"))"

# ============================================================================
# A4. A real 404 (documents too, no row) still pages on the github path.
# ============================================================================
RESET; MODE all404
DV; RC=$?
[ "$RC" = 1 ] && ok || bad "A4: a prod that 404s documents must FAIL (rc=$RC)"
grep -q "returned HTTP 404" "$H/logs/ALERTS.log" && ok || bad "A4: the ALERTS line must say 404 ($(cat "$H/logs/ALERTS.log"))"

# ============================================================================
# A5. A plain healthy prod, no row: unchanged URL, still OK.
# ============================================================================
RESET; MODE ok
DV; RC=$?
[ "$RC" = 0 ] && ok || bad "A5: a 200 prod must verify (rc=$RC)"
[ "$(REQ1 .path)" = / ] && ok || bad "A5: the first request must be / (got: $(REQ1 .path))"

# ============================================================================
# A6. kind=smoke-only: the smoke-only probe sends the same document headers.
# ============================================================================
RESET; MODE clerk; ROW deploy.tproj.kind smoke-only
DV; RC=$?
[ "$RC" = 0 ] && ok || bad "A6: smoke-only on a Clerk prod must verify (rc=$RC)"
grep -q 'smoke-only (deploy.kind=smoke-only)' <<<"$(PIPE)" && ok || bad "A6: the smoke-only branch must run (got: $(PIPE))"
grep -q 'prod answers 200' <<<"$(PIPE)" && ok || bad "A6: the smoke-only probe must read 200 (got: $(PIPE))"
[ "$(REQ1 '.headers["sec-fetch-dest"] // ""')" = document ] && ok || bad "A6: the smoke-only probe must send Sec-Fetch-Dest: document"

# ============================================================================
# P1-P6. smoke_url decision rule, through the helper directly.
# ============================================================================
SU() { # SU <project> <base> -> stdout in $T/su.out, stderr in $T/su.err
  ( HARNESS="$H" bash -c '. "$1/bin/lib/smoke-probe.sh" && smoke_url "$2" "$3"' _ "$H" "$1" "$2" \
      > "$T/su.out" 2> "$T/su.err" )
}
B=https://x.example
[ -f "$DIR/bin/lib/smoke-probe.sh" ] && ok || bad "P0: bin/lib/smoke-probe.sh must exist"
if [ -f "$H/bin/lib/smoke-probe.sh" ]; then
  RESET; ROW deploy.tproj.smoke_path /sign-in; SU tproj "$B"
  [ "$(cat "$T/su.out")" = "$B/sign-in" ] && ok || bad "P1: row /sign-in -> $B/sign-in (got: $(cat "$T/su.out"))"
  RESET; SU tproj "$B"
  [ "$(cat "$T/su.out")" = "$B" ] && ok || bad "P2: no row -> the bare base (got: $(cat "$T/su.out"))"
  [ -s "$T/su.err" ] && bad "P2: no row must say nothing on stderr ($(cat "$T/su.err"))" || ok
  RESET; ROW deploy.tproj.smoke_path OUTAGE; SU tproj "$B"
  [ "$(cat "$T/su.out")" = "$B" ] && ok || bad "P3: an outage -> the bare base (got: $(cat "$T/su.out"))"
  for V in sign-in '/a b' '//evil.example/x' "/$(printf 'a%.0s' $(seq 1 201))"; do
    RESET; ROW deploy.tproj.smoke_path "$V"; SU tproj "$B"
    [ "$(cat "$T/su.out")" = "$B" ] && ok || bad "P4[$V]: an invalid value -> the bare base (got: $(cat "$T/su.out"))"
    grep -q 'deploy.tproj.smoke_path' "$T/su.err" && ok || bad "P4[$V]: an invalid value must name the key on stderr (got: $(cat "$T/su.err"))"
  done
  RESET; ROW deploy.tproj.smoke_path /sign-in; SU tproj "$B/"
  [ "$(cat "$T/su.out")" = "$B/sign-in" ] && ok || bad "P5: a trailing slash on the base is dropped (got: $(cat "$T/su.out"))"
  RESET; ROW deploy.tproj.smoke_path /sign-in; SU TProj "$B"
  [ "$(cat "$T/su.out")" = "$B/sign-in" ] && ok || bad "P6: TProj reads the lowercase row (got: $(cat "$T/su.out"))"
  grep -qx 'deploy.tproj.smoke_path' "$T/keys.txt" && ok || bad "P6: the key must be lowercased (asked: $(cat "$T/keys.txt"))"
  RESET; ROW deploy.tproj.smoke_path /; SU tproj "$B"
  [ "$(cat "$T/su.out")" = "$B/" ] && ok || bad "P1b: row / -> $B/ (got: $(cat "$T/su.out"))"
else
  bad "P1-P6: bin/lib/smoke-probe.sh is not in deploy-verify's closure"
fi

# ============================================================================
# S1. The seed: the composed schema stores /sign-in for project-6-os, and
#     smoke_url over the stored value gives the prod sign-in page.
# ============================================================================
DB="$T/s1.sqlite"
python3 -I - "$DIR/worker/jobs/schema.sql" "$DB" > "$T/s1.err" 2>&1 <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[2])
db.executescript(open(sys.argv[1]).read())
db.commit()
PY
[ "$?" = 0 ] && ok || bad "S1: the composed schema did not apply to a fresh database: $(head -3 "$T/s1.err")"
V=$(python3 -I -c 'import sqlite3, sys; r = sqlite3.connect(sys.argv[1]).execute("SELECT value FROM settings WHERE key=?", ("deploy.project-6-os.smoke_path",)).fetchone(); print(r[0] if r else "")' "$DB" 2>/dev/null)
[ "$V" = /sign-in ] && ok || bad "S1: the composed schema must seed deploy.project-6-os.smoke_path=/sign-in (got: '$V')"
if [ -f "$H/bin/lib/smoke-probe.sh" ]; then
  RESET; ROW deploy.project-6-os.smoke_path "$V"; SU project-6-os https://os.example.com
  [ "$(cat "$T/su.out")" = https://os.example.com/sign-in ] && ok || bad "S1: smoke_url over the seeded value (got: $(cat "$T/su.out"))"
fi

echo "deploy-verify-smoke.bh-6786-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
