#!/bin/bash
# tests/extra-usage-loud.bh-3985-test.sh — BH-3985: bin/extra-usage-track.sh
# is LOUD about a meter that fails or freezes, and a failed poll carries the
# vendor's answer instead of a blank.
#
# DRIVEN, NOT GREPPED. The real script runs in a sandbox against a fixture usage
# endpoint, the REAL lane-alert + alert-state machine (the stub is one layer down
# at beat.sh), and a curl stub that logs every jobs request and answers
# GET /api/metrics/account-usage?window=12h from a fixture file. Same rig as
# tests/extra-usage-xcheck.bh-167-test.sh.
#
#   L1   a 500 from the vendor: the error row posts the vendor body, scrubbed
#        of the token, and the CSV keeps its 11 columns
#   L2   3 `error` polls in a row: one alert, after the third and not before
#   L3   a 4th the same day: still one; recovery then 3 more: still one (per day)
#   L4   error, no-login, error, error: no alert (the streak is broken)
#   L4b  the streak knob moves the threshold; 0 / junk fall back and say so
#   L5   meter flat 13h, $7.50 of priced rows in 12h: one FLAT alert
#   L6   flat, usd null (nothing priced): none
#   L7   flat, usd 4 / exactly 5 / knob 10 at 7.50: none
#   L8   flat only 11h, or moved a cent inside 12h: none, and no 12h read
#   L9   the L5 run again the same day: still one; moved, then frozen again: still one
#   L10  account-usage answers 500 / label absent: none, and the run log says why
#   L11  flat 13h at $7.50 but INSIDE weekly credits (wk 29, not in overage): none,
#        no 12h read, and the run log says why; in overage only the last 6h of a
#        13h-flat run: none; a firing flat alert resolves when overage ends
# Run from anywhere: tests/extra-usage-loud.bh-3985-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 68 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
trap 'scratch_cleanup; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null' EXIT
mkdir -p "$T/bin/lib/jobs" "$T/env" "$T/logs" "$T/state" "$T/flags" "$T/cfg-mk" "$T/fx" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }

cp "$DIR/bin/extra-usage-track.sh" "$T/bin/"
cp "$DIR/bin/jobs-client.sh"       "$T/bin/"
chmod +x "$T/bin/extra-usage-track.sh"
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/oauth-refresh.sh"; chmod +x "$T/bin/oauth-refresh.sh"

ln -sf "$DIR/bin/lane-alert.sh" "$T/bin/lane-alert.sh"
ln -sf "$DIR/bin/lib/alert-state.sh" "$T/bin/lib/alert-state.sh"
ln -sf "$DIR/bin/alert_family.py" "$T/bin/alert_family.py"
cat > "$T/bin/beat.sh" <<'EOF'
#!/bin/bash
jq -r '.line // ""' <<<"${1:-}" >> "$ALERT_SINK"
exit 0
EOF
chmod +x "$T/bin/beat.sh"
# Every bin/lib file the two scripts source (BH-4552), after the links and
# stubs above: the install never overwrites a file already there.
for s in bin/extra-usage-track.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$T" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done

cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  *'/api/metrics/account-usage?window=12h')
    cat "$FLAT_FIXTURE"; printf '\n%s\n' "${FLAT_STATUS:-200}"; exit 0 ;;
esac
printf '{"snapshot":{}}\n200\n'
CURL
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

# The usage endpoint. The meter value comes from $T/fx/used (cents) and the
# weekly utilization from $T/fx/wk on every request, so a case can pin both
# (wk 100 = in overage, the only state in which the meter is expected to move). A token starting sk-ant-boom gets a 500 whose
# body ECHOES the token, which is the worst case for a body we now store.
cat > "$T/server.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
USED = sys.argv[1]
WK = sys.argv[2]
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        tok = (self.headers.get("Authorization") or "").replace("Bearer ", "")
        if tok == "live":
            body = {"five_hour": {"utilization": 10}, "seven_day": {"utilization": int(open(WK).read().strip()), "resets_at": "2026-10-08T00:00:00Z"},
                    "extra_usage": {"is_enabled": True, "used_credits": int(open(USED).read().strip()),
                                    "monthly_limit": 3500000, "utilization": 0, "decimal_places": 2,
                                    "spend_limit_reached": False}}
            b = json.dumps(body).encode(); code = 200
        elif tok.startswith("sk-ant-boom"):
            b = json.dumps({"type": "error", "error": {"type": "api_error",
                 "message": "boom-3985 for %s (Authorization: Bearer %s)" % (tok, tok)}}).encode()
            code = 500
        elif tok == "setup-tok":
            self.send_error(429, "Too Many Requests"); return
        else:
            self.send_error(403, "OAuth token does not meet scope requirement user:profile"); return
        self.send_response(code); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a):
        pass
s = HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
PY
echo 1393 > "$T/fx/used"; echo 100 > "$T/fx/wk"
python3 "$T/server.py" "$T/fx/used" "$T/fx/wk" > "$T/port" 2>/dev/null &
SRV_PID=$!
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT=$(cat "$T/port" 2>/dev/null)
[ -n "$PORT" ] && ok || { echo "FAIL: the fixture usage endpoint did not start"; echo "extra-usage-loud: 0 pass, 1 fail"; exit 1; }
OAUTH_USAGE_URL="http://127.0.0.1:$PORT/api/oauth/usage"

# sk-""ant split so the share-mirror leakcheck does not read this fake as a key (same idiom as share-leakguard-classes)
BOOM_TOK="sk-""ant-boom-SECRET3985xyz"
cred() { printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"r","expiresAt":99999999999999}}\n' "$1" > "$T/cfg-mk/.credentials.json"; }
CSV="$T/logs/extra-usage-mk.csv"
HDR='ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,extra_used_usd,spend_limit_reached,in_overage,extra_limit_usd,extra_pct,status'

run() { # run [env=val ...] — one tracker run; sinks ACCUMULATE until reset_state
  env -i PATH="$PATH" HOME="$T" HARNESS="$T" CLAUDE_CONFIG_DIR="$T/cfg-own" \
    OAUTH_USAGE_URL="$OAUTH_USAGE_URL" REQ_SINK="$T/reqs" ALERT_SINK="$T/alerts" \
    FLAT_FIXTURE="$T/fx/12h.json" EXTRA_USAGE_LOGINS="mk=$T/cfg-mk" "$@" \
    bash "$T/bin/extra-usage-track.sh" hub >"$T/out" 2>"$T/err"
}
reset_state() {
  rm -rf "$T/logs"/*.csv "$T/state"/* "$T/flags"/* 2>/dev/null
  : > "$T/logs/ALERTS.log"; : > "$T/logs/agent-rules.log"; : > "$T/reqs"; : > "$T/alerts"
}
# Fires only: a resolve line carries RESOLVED and is not a second alert.
n_err()  { grep 'EXTRA-USAGE METER ERRORS \[mk\]' "$T/alerts" 2>/dev/null | grep -vc RESOLVED; }
n_flat() { grep 'EXTRA-USAGE METER FLAT \[mk\]' "$T/alerts" 2>/dev/null | grep -vc RESOLVED; }

# ===========================================================================
# L1. the vendor's error body reaches the DB row, scrubbed
# ===========================================================================
reset_state; cred "$BOOM_TOK"; run
POST=$(grep '^POST .*/api/metrics/extra-usage ' "$T/reqs" | tail -1 | cut -d' ' -f3-)
[ "$(printf '%s' "$POST" | jq -r '.status' 2>/dev/null)" = error ] \
  && ok || bad "L1: no error row was posted: $(cat "$T/reqs")"
printf '%s' "$POST" | jq -r '.error_body' 2>/dev/null | grep -q 'boom-3985' \
  && ok || bad "L1: the posted error_body does not carry the vendor body: $POST"
printf '%s' "$POST" | jq -r '.error_body' 2>/dev/null | grep -q 'HTTP Error 500' \
  && ok || bad "L1: the posted error_body lost the HTTP status: $POST"
grep -q 'SECRET3985' "$T/reqs" && bad "L1: the token reached the jobs request: $(grep SECRET3985 "$T/reqs")" || ok
[ "$(tail -1 "$CSV" | awk -F, '{print NF}')" = 11 ] && tail -1 "$CSV" | grep -q ',error$' \
  && ok || bad "L1: the CSV row is not the 11-column error row: $(tail -1 "$CSV")"

# ===========================================================================
# L2. three error polls in a row raise one alert, after the third
# ===========================================================================
reset_state; cred "$BOOM_TOK"
run; A1=$(n_err); run; A2=$(n_err); run; A3=$(n_err)
[ "$A1" = 0 ] && [ "$A2" = 0 ] && [ "$A3" = 1 ] \
  && ok || bad "L2: expected 0,0,1 error alerts after runs 1-3, got $A1,$A2,$A3: $(cat "$T/alerts")"
grep 'EXTRA-USAGE METER ERRORS \[mk\]' "$T/alerts" | grep -q '3 failed polls in a row (status=error).*boom-3985' \
  && ok || bad "L2: the alert does not name the streak and the vendor answer: $(cat "$T/alerts")"
grep -q 'SECRET3985' "$T/alerts" "$T/logs/ALERTS.log" && bad "L2: the token reached an alert" || ok
ls "$T/flags"/alerted-extra-usage-errors-mk-"$(date -u +%Y%m%d)" >/dev/null 2>&1 \
  && ok || bad "L2: the per-day flag was not written"

# ===========================================================================
# L3. a 4th error the same day: no second alert; recovery then 3 more: still one
# ===========================================================================
run
[ "$(n_err)" = 1 ] && ok || bad "L3: a 4th error re-alerted: $(cat "$T/alerts")"
cred live; run
grep -q 'RESOLVED.*EXTRA-USAGE METER ERRORS \[mk\]' "$T/alerts" \
  && ok || bad "L3: an ok poll did not resolve the error streak: $(cat "$T/alerts")"
cred "$BOOM_TOK"; run; run; run
[ "$(n_err)" = 1 ] && ok || bad "L3: a second streak the same day re-alerted: $(cat "$T/alerts")"

# ===========================================================================
# L4. a no-login poll breaks the streak
# ===========================================================================
reset_state
cred "$BOOM_TOK"; run; cred setup-tok; run; cred "$BOOM_TOK"; run; run
[ "$(n_err)" = 0 ] && ok || bad "L4: error,no-login,error,error alerted: $(cat "$T/alerts")"
tail -3 "$CSV" | cut -d, -f11 | tr '\n' ' ' | grep -q '^no-login error error $' \
  && ok || bad "L4: the CSV tail is not no-login,error,error: $(tail -3 "$CSV")"

# ===========================================================================
# L4b. the streak knob
# ===========================================================================
reset_state; cred "$BOOM_TOK"
run EXTRA_USAGE_ERROR_STREAK=2; run EXTRA_USAGE_ERROR_STREAK=2
[ "$(n_err)" = 1 ] && ok || bad "L4b: a streak knob of 2 did not fire after 2: $(cat "$T/alerts")"
grep -q 'error streak 2 (env/settings)' "$T/logs/agent-rules.log" \
  && ok || bad "L4b: the knob is not logged with its source: $(cat "$T/logs/agent-rules.log")"
reset_state; run EXTRA_USAGE_ERROR_STREAK=0; run EXTRA_USAGE_ERROR_STREAK=0
[ "$(n_err)" = 0 ] && ok || bad "L4b: a streak knob of 0 fired on 2 errors: $(cat "$T/alerts")"
grep -q "error streak 3 (code default (rejected '0' from env/settings))" "$T/logs/agent-rules.log" \
  && ok || bad "L4b: a 0 knob did not fall back to 3 and say so: $(cat "$T/logs/agent-rules.log")"

# ===========================================================================
# Flat meter. seed_flat <hours> [<older-value>] [<wk>] writes hourly ok readings
# at $13.93 reaching <hours> back (plus, optionally, one older reading 14h back
# at a different value). They are IN OVERAGE (wk 100, in_overage 1) unless <wk>
# is under 100. The run's own poll adds the newest $13.93 reading at $T/fx/wk.
# ===========================================================================
NOW=$(date -u +%s)
iso_ago() { date -u -d "@$((NOW - $1))" +%Y-%m-%dT%H:%M:%SZ; }
seed_flat() {
  local hrs="$1" older="${2:-}" wk="${3:-100}" ov=1 h
  [ "$wk" -lt 100 ] && ov=0
  echo "$HDR" > "$CSV"
  [ -n "$older" ] && echo "$(iso_ago $((14 * 3600))),10,$wk,2026-10-08T00:00:00Z,1,$older,0,$ov,35000.00,0,ok" >> "$CSV"
  for h in $(seq "$hrs" -1 1); do
    echo "$(iso_ago $((h * 3600))),10,$wk,2026-10-08T00:00:00Z,1,13.93,0,$ov,35000.00,0,ok" >> "$CSV"
  done
}
fx12() { # fx12 <label> <usd-json>
  jq -nc --arg l "$1" --argjson u "$2" '{window:"12h", from:"x", to:"y",
    accounts:[{account:"claude:operator@example.com", calls:40, usd:$u, unpriced_calls:0,
      meter:{label:$l, session_pct:10, weekly_pct:100, weekly_resets_at:null, extra_used_usd:13.93, polls:48},
      cross_check:{state:"unmeasured", reason:"fixture"}}],
    totals:{calls:40, usd:$u}, truncated:{groups:false, projects:false, snapshots:false}}' > "$T/fx/12h.json"
}
n_12h() { grep -c 'account-usage?window=12h' "$T/reqs"; }

# L5. flat 13h, $7.50 billed in 12h -> one alert
reset_state; cred live; seed_flat 13; fx12 mk 7.5; run
[ "$(n_flat)" = 1 ] && ok || bad "L5: a 13h-flat meter with \$7.50 of rows did not alert once: $(cat "$T/alerts")"
grep 'EXTRA-USAGE METER FLAT \[mk\]' "$T/alerts" | grep -q 'meter stuck at \$13.93 since .*while cost rows billed \$7.50 to this account in the last 12h' \
  && ok || bad "L5: the alert text is wrong: $(cat "$T/alerts")"
[ "$(n_12h)" = 1 ] && ok || bad "L5: expected one 12h account-usage read: $(cat "$T/reqs")"

# L9. the same run again the same day: still one
run
[ "$(n_flat)" = 1 ] && ok || bad "L9: a second flat run the same day re-alerted: $(cat "$T/alerts")"
# L9b. the meter moves (one resolve), then freezes again the same day: still one
echo 1394 > "$T/fx/used"; run; echo 1393 > "$T/fx/used"
grep -q 'RESOLVED.*EXTRA-USAGE METER FLAT \[mk\]' "$T/alerts" \
  && ok || bad "L9b: a meter that moved did not resolve the flat alert: $(cat "$T/alerts")"
seed_flat 13; run
[ "$(n_flat)" = 1 ] && ok || bad "L9b: a second freeze the same day re-alerted: $(cat "$T/alerts")"

# L6. flat, nothing priced (usd null) -> none
reset_state; seed_flat 13; fx12 mk null; run
[ "$(n_flat)" = 0 ] && ok || bad "L6: a flat meter with no priced rows alerted: $(cat "$T/alerts")"
grep -q 'flat\[mk\].*no priced rows' "$T/logs/agent-rules.log" \
  && ok || bad "L6: the run log does not say why: $(cat "$T/logs/agent-rules.log")"

# L7. under or at the threshold -> none
for U in 4 5; do
  reset_state; seed_flat 13; fx12 mk "$U"; run
  [ "$(n_flat)" = 0 ] && ok || bad "L7: usd $U alerted (strict > 5): $(cat "$T/alerts")"
done
reset_state; seed_flat 13; fx12 mk 7.5; run EXTRA_USAGE_FLAT_MIN_USD=10
[ "$(n_flat)" = 0 ] && ok || bad "L7: \$7.50 alerted under a \$10 knob: $(cat "$T/alerts")"
grep -q 'flat min \$10 (env/settings)' "$T/logs/agent-rules.log" \
  && ok || bad "L7: the flat knob is not logged with its source: $(cat "$T/logs/agent-rules.log")"

# L8. flat only 11h, or the meter moved a cent 12h+ back -> none, and no read
reset_state; seed_flat 11; fx12 mk 7.5; run
[ "$(n_flat)" = 0 ] && [ "$(n_12h)" = 0 ] \
  && ok || bad "L8: an 11h-flat meter alerted or read account-usage: $(cat "$T/alerts") $(cat "$T/reqs")"
reset_state; seed_flat 11 13.92; fx12 mk 7.5; run
[ "$(n_flat)" = 0 ] && [ "$(n_12h)" = 0 ] \
  && ok || bad "L8: a meter that moved a cent inside 12h alerted: $(cat "$T/alerts")"
reset_state; seed_flat 13; echo 1394 > "$T/fx/used"; fx12 mk 7.5; run; echo 1393 > "$T/fx/used"
[ "$(n_flat)" = 0 ] && ok || bad "L8: a meter that moved on THIS poll alerted: $(cat "$T/alerts")"

# L10. the read fails, or the label is absent -> none, and the log says why
reset_state; seed_flat 13; fx12 mk 7.5; run FLAT_STATUS=500
[ "$(n_flat)" = 0 ] && ok || bad "L10: a failed account-usage read alerted: $(cat "$T/alerts")"
grep -q 'flat\[mk\].*account-usage read unusable' "$T/logs/agent-rules.log" \
  && ok || bad "L10: the failed read is not in the run log: $(cat "$T/logs/agent-rules.log")"
reset_state; seed_flat 13; fx12 other 7.5; run
[ "$(n_flat)" = 0 ] && ok || bad "L10: an absent label alerted: $(cat "$T/alerts")"
grep -q 'flat\[mk\].*not in the account-usage answer' "$T/logs/agent-rules.log" \
  && ok || bad "L10: the absent label is not in the run log: $(cat "$T/logs/agent-rules.log")"

# L11. the meter is still because the account is inside its weekly credits:
# that is the normal state (the meter only moves in overage), never an alert.
reset_state; seed_flat 13 "" 29; echo 29 > "$T/fx/wk"; fx12 mk 7.5; run
[ "$(n_flat)" = 0 ] && [ "$(n_12h)" = 0 ] \
  && ok || bad "L11: a flat meter inside weekly credits alerted or read account-usage: $(cat "$T/alerts") $(cat "$T/reqs")"
grep -q 'flat\[mk\].*no alert: not in overage for the last 12h' "$T/logs/agent-rules.log" \
  && ok || bad "L11: the run log does not say the account is not in overage: $(cat "$T/logs/agent-rules.log")"
# L11b. flat 13h, but in overage only for the last 6h of it -> none
reset_state; seed_flat 13 "" 42; echo 100 > "$T/fx/wk"
awk -F, -v OFS=, -v cut="$(iso_ago $((6 * 3600)))" 'NR>1 && $1 >= cut {$3=100; $8=1} {print}' "$CSV" > "$CSV.tmp" && mv "$CSV.tmp" "$CSV"
fx12 mk 7.5; run
[ "$(n_flat)" = 0 ] && [ "$(n_12h)" = 0 ] \
  && ok || bad "L11b: 6h of overage inside a 13h-flat run alerted: $(cat "$T/alerts") $(cat "$T/reqs")"
# L11c. a firing flat alert resolves when the account leaves overage
reset_state; seed_flat 13; fx12 mk 7.5; run
[ "$(n_flat)" = 1 ] && ok || bad "L11c: the in-overage flat setup did not alert: $(cat "$T/alerts")"
echo 29 > "$T/fx/wk"; run; echo 100 > "$T/fx/wk"
grep -q 'RESOLVED.*EXTRA-USAGE METER FLAT \[mk\]' "$T/alerts" \
  && ok || bad "L11c: leaving overage did not resolve the flat alert: $(cat "$T/alerts")"

echo "extra-usage-loud: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
