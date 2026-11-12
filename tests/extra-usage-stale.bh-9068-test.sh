#!/bin/bash
# tests/extra-usage-stale.bh-9068-test.sh — BH-9068: bin/extra-usage-track.sh
# says METER DOWN once per outage, after 2 hours with no reading.
#
# DRIVEN, NOT GREPPED. The real script runs in a sandbox against a fixture usage
# endpoint (the rig of tests/extra-usage-loud.bh-3985-test.sh). lane-alert.sh is
# a stub that records EVERY call, so the counts below are the script's own
# dedupe and not the alert state machine's. The clock is pinned through the
# EXTRA_USAGE_NOW_EPOCH seam, so no case reads the wall clock for its age.
#
#   S1  last reading 3h old, no-login poll: one alert
#   S2  last reading 1h old: none
#   S3  edge: 2h00m fires, 1h59m does not (no knob row: the fallback is 2)
#   S4  no reading ever: one alert, and a second poll adds none
#   S5  status=error (not no-login) for 3h: one alert
#   S6  an `ok` row with an empty column 6 is not a reading
#   S7  10 no-login polls over 3h across 00:00Z: exactly one alert
#   S8  an ok poll clears the incident flag; 3h more of no-login: a second alert
#   S9  a failed alert call writes no flag; the next poll alerts
#   S10 6 stale accounts: 6 alerts on the first tick, 0 on the second, rc 0
#   S11 knob: EXTRA_USAGE_STALE_HOURS=4 holds a 3h meter; junk falls back to 2
# Run from anywhere: tests/extra-usage-stale.bh-9068-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
trap 'scratch_cleanup; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null' EXIT
mkdir -p "$T/bin/lib/jobs" "$T/env" "$T/logs" "$T/state" "$T/flags" "$T/fx" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }

cp "$DIR/bin/extra-usage-track.sh" "$T/bin/"
cp "$DIR/bin/jobs-client.sh"       "$T/bin/"
chmod +x "$T/bin/extra-usage-track.sh"
echo "HARNESS_SECRET=test-secret-fixture" > "$T/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/oauth-refresh.sh"; chmod +x "$T/bin/oauth-refresh.sh"
# The lane-alert stub: one line per call, and it fails when $T/fx/alert-fail exists.
cat > "$T/bin/lane-alert.sh" <<'EOF'
#!/bin/bash
[ -f "$HARNESS/fx/alert-fail" ] && exit 1
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
EOF
chmod +x "$T/bin/lane-alert.sh"
for s in bin/extra-usage-track.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$T" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done

cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
printf '{"snapshot":{}}\n200\n'
CURL
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

# The usage endpoint: "live" reads ok, "setup-tok" gets 429 (no-login), anything
# else gets a 500 (status=error).
cat > "$T/server.py" <<'PY'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        tok = (self.headers.get("Authorization") or "").replace("Bearer ", "")
        if tok == "live":
            body = {"five_hour": {"utilization": 10}, "seven_day": {"utilization": 20, "resets_at": "2026-11-08T00:00:00Z"},
                    "extra_usage": {"is_enabled": True, "used_credits": 1393, "monthly_limit": 3500000,
                                    "utilization": 0, "decimal_places": 2, "spend_limit_reached": False}}
            b = json.dumps(body).encode(); code = 200
        elif tok == "setup-tok":
            self.send_error(429, "Too Many Requests"); return
        else:
            b = b'{"type":"error","error":{"type":"api_error","message":"fixture boom"}}'; code = 500
        self.send_response(code); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a):
        pass
s = HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
PY
python3 "$T/server.py" > "$T/port" 2>/dev/null &
SRV_PID=$!
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT=$(cat "$T/port" 2>/dev/null)
[ -n "$PORT" ] && ok || { echo "FAIL: the fixture usage endpoint did not start"; echo "extra-usage-stale: 0 pass, 1 fail"; exit 1; }
OAUTH_USAGE_URL="http://127.0.0.1:$PORT/api/oauth/usage"

HDR='ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,extra_used_usd,spend_limit_reached,in_overage,extra_limit_usd,extra_pct,status'
# The pinned clock: 2026-11-05T23:00:00Z, one hour before a UTC day boundary.
NOW0=$(date -u -d '2026-11-05T23:00:00Z' +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
cred() { # cred <label> <token>
  mkdir -p "$T/cfg-$1"
  printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"r","expiresAt":99999999999999}}\n' "$2" > "$T/cfg-$1/.credentials.json"
}
seed_ok() { # seed_ok <label> <epoch>: a CSV whose last reading is at <epoch>
  { echo "$HDR"; echo "$(iso "$2"),10,20,2026-11-08T00:00:00Z,1,13.93,0,0,35000.00,0,ok"; } > "$T/logs/extra-usage-$1.csv"
}
LOGINS="mk=$T/cfg-mk"
run() { # run <now-epoch> [env=val ...]
  local now="$1"; shift
  env -i PATH="$PATH" HOME="$T" HARNESS="$T" CLAUDE_CONFIG_DIR="$T/cfg-own" \
    OAUTH_USAGE_URL="$OAUTH_USAGE_URL" ALERT_SINK="$T/alerts" \
    EXTRA_USAGE_LOGINS="$LOGINS" EXTRA_USAGE_NOW_EPOCH="$now" "$@" \
    bash "$T/bin/extra-usage-track.sh" hub >"$T/out" 2>"$T/err"
}
reset_state() {
  rm -rf "$T/logs" "$T/state"/* "$T/flags"/* "$T/fx/alert-fail" 2>/dev/null
  mkdir -p "$T/logs"; : > "$T/alerts"; LOGINS="mk=$T/cfg-mk"
}
# Fires only, for one label: a call with --resolve is not a fire.
n_down() { grep -- "--id extra-usage-meter-${1:-mk} " "$T/alerts" 2>/dev/null | grep -vc -- '--resolve'; }

# S1 ---------------------------------------------------------------------------
reset_state; cred mk setup-tok; seed_ok mk $((NOW0 - 3*3600)); run "$NOW0"
[ "$(n_down)" = 1 ] && ok || bad "S1: a 3h-old meter on a no-login poll did not alert once: $(cat "$T/alerts")"
grep -q 'METER DOWN \[mk\]: no successful poll for 3h' "$T/alerts" && ok || bad "S1: the alert does not name the 3h age: $(cat "$T/alerts")"
[ -f "$T/flags/alerted-extra-usage-stale-mk" ] && ok || bad "S1: the per-incident flag (no date) was not written: $(ls "$T/flags")"

# S2 ---------------------------------------------------------------------------
reset_state; cred mk setup-tok; seed_ok mk $((NOW0 - 3600)); run "$NOW0"
[ "$(n_down)" = 0 ] && ok || bad "S2: a 1h-old meter alerted: $(cat "$T/alerts")"

# S3 ---------------------------------------------------------------------------
reset_state; cred mk setup-tok; seed_ok mk $((NOW0 - 7200)); run "$NOW0"
[ "$(n_down)" = 1 ] && ok || bad "S3: a meter exactly 2h00m old did not alert: $(cat "$T/alerts")"
reset_state; cred mk setup-tok; seed_ok mk $((NOW0 - 7140)); run "$NOW0"
[ "$(n_down)" = 0 ] && ok || bad "S3: a meter 1h59m old alerted: $(cat "$T/alerts")"

# S4 ---------------------------------------------------------------------------
reset_state; cred mk setup-tok; run "$NOW0"; run $((NOW0 + 900))
[ "$(n_down)" = 1 ] && ok || bad "S4: a meter with no reading ever did not alert exactly once in 2 polls: $(cat "$T/alerts")"

# S5 ---------------------------------------------------------------------------
reset_state; cred mk boom-fixture; seed_ok mk $((NOW0 - 3*3600)); run "$NOW0"
tail -1 "$T/logs/extra-usage-mk.csv" | grep -q ',error$' && ok || bad "S5: the poll was not status=error: $(tail -1 "$T/logs/extra-usage-mk.csv")"
[ "$(n_down)" = 1 ] && ok || bad "S5: a 3h-old meter on an error poll did not alert: $(cat "$T/alerts")"

# S6 ---------------------------------------------------------------------------
reset_state; cred mk setup-tok; seed_ok mk $((NOW0 - 3*3600))
echo "$(iso $((NOW0 - 600))),,,,,,,,,,ok" >> "$T/logs/extra-usage-mk.csv"
run "$NOW0"
[ "$(n_down)" = 1 ] && ok || bad "S6: an ok row with no reading counted as a reading: $(cat "$T/alerts")"

# S7 ---------------------------------------------------------------------------
reset_state; cred mk setup-tok; seed_ok mk $((NOW0 - 3600))
for i in 0 1 2 3 4 5 6 7 8 9; do run $((NOW0 + i*1200)); done   # 23:00 .. 02:00 next day
[ "$(n_down)" = 1 ] && ok || bad "S7: 10 no-login polls across 00:00Z made $(n_down) alerts, want 1: $(cat "$T/alerts")"

# S8 ---------------------------------------------------------------------------
cred mk live; run $((NOW0 + 10*1200))
[ ! -e "$T/flags/alerted-extra-usage-stale-mk" ] && ok || bad "S8: an ok poll did not clear the incident flag"
grep -q -- '--resolve --id extra-usage-meter-mk ' "$T/alerts" && ok || bad "S8: an ok poll did not resolve the alert: $(cat "$T/alerts")"
OKTS=$(awk -F, 'NR>1 && $6 != "" {t=$1} END{print t}' "$T/logs/extra-usage-mk.csv")
OKE=$(date -u -d "$OKTS" +%s)
cred mk setup-tok; run $((OKE + 3600)); run $((OKE + 3*3600))
[ "$(n_down)" = 2 ] && ok || bad "S8: a second outage after an ok poll did not alert again (fires=$(n_down)): $(cat "$T/alerts")"

# S9 ---------------------------------------------------------------------------
reset_state; cred mk setup-tok; seed_ok mk $((NOW0 - 3*3600))
touch "$T/fx/alert-fail"; mkdir -p "$T/logs/ALERTS.log"   # lane-alert fails and the fallback append fails
run "$NOW0"; RC=$?
[ "$RC" = 0 ] && ok || bad "S9: a failed alert call changed the exit code to $RC"
[ ! -e "$T/flags/alerted-extra-usage-stale-mk" ] && ok || bad "S9: a failed alert call wrote the incident flag"
rm -f "$T/fx/alert-fail"; rmdir "$T/logs/ALERTS.log"; run $((NOW0 + 900))
[ "$(n_down)" = 1 ] && ok || bad "S9: the poll after a failed alert did not alert: $(cat "$T/alerts")"

# S10 --------------------------------------------------------------------------
reset_state; LOGINS=""
for a in a1 a2 a3 a4 a5 a6; do
  cred "$a" setup-tok; seed_ok "$a" $((NOW0 - 5*3600)); LOGINS="${LOGINS:+$LOGINS,}$a=$T/cfg-$a"
done
run "$NOW0"; RC1=$?
F1=$(grep -c -- '--id extra-usage-meter-a[1-6] ' "$T/alerts" | tr -d ' ')
run $((NOW0 + 900)); RC2=$?
F2=$(grep -c -- '--id extra-usage-meter-a[1-6] ' "$T/alerts" | tr -d ' ')
[ "$F1" = 6 ] && [ "$F2" = 6 ] && ok || bad "S10: want 6 alerts on tick 1 and none more on tick 2, got $F1 then $F2"
[ "$RC1" = 0 ] && [ "$RC2" = 0 ] && ok || bad "S10: rc $RC1/$RC2, want 0/0"

# S11 --------------------------------------------------------------------------
reset_state; cred mk setup-tok; seed_ok mk $((NOW0 - 3*3600)); run "$NOW0" EXTRA_USAGE_STALE_HOURS=4
[ "$(n_down)" = 0 ] && ok || bad "S11: a 4h knob alerted on a 3h meter: $(cat "$T/alerts")"
reset_state; cred mk setup-tok; seed_ok mk $((NOW0 - 7200)); run "$NOW0" EXTRA_USAGE_STALE_HOURS=junk
[ "$(n_down)" = 1 ] && ok || bad "S11: a junk knob did not fall back to 2h: $(cat "$T/alerts")"

echo "extra-usage-stale: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
