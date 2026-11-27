#!/bin/bash
# tests/extra-usage-logins-test.sh — bin/extra-usage-track.sh polls EVERY login
# a box holds, not one, and says so per ACCOUNT.
#
# THE BUG THIS LOCKS DOWN (2026-09-14). The tracker polled exactly one login:
# the box's own /root/.claude, on the doctrine that the account a box reports is
# the account it bills. That held everywhere except the box that spends the
# most. The hub's lanes authenticate with CLAUDE_CODE_OAUTH_TOKEN, which bills
# operator@second.example; its stored login is operator_home@example.com. So for fifteen days
# the hub faithfully polled a meter belonging to an account that was barely
# spending, while the account paying for every lane on the box ran to $23.8K of
# a $35K monthly cap with nobody reading its meter at all.
#
# DRIVEN, NOT GREPPED. Every claim here is about behaviour, and the script is
# run for real against a local HTTP server that answers per CREDENTIAL — which
# is how one run can hold a working login and a refused one at the same time,
# exactly like the hub does:
#
#   1. a box with no catalog entry and no override polls exactly what it polled
#      before: one login, labelled with the box id, unsuffixed CSV
#   2. catalog/cost-accounts.json drives the list — two logins on one box, two
#      labels, two CSVs, two DB rows, and the box's OWN login keeps the legacy
#      file names every other reader already knows
#   3. EXTRA_USAGE_LOGINS overrides the catalog
#   4. a login that cannot read its meter records status=no-login WITH NO
#      NUMBERS — silence and a $0 meter must never look the same
#   5. the env setup-token is a fallback for the box's OWN login only; using it
#      for a NAMED login would file one account's meter under another's name
#   6. the >=98%-of-cap alert fires once per label and dedupes for 6h
#   7. both kill switches stop it dead
# Run from anywhere: tests/extra-usage-logins-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
trap 'scratch_cleanup; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null' EXIT
mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/state" "$T/flags" "$T/catalog" "$T/cfg-own" "$T/cfg-mk" "$T/cfg-none"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }

cp "$DIR/bin/extra-usage-track.sh" "$T/bin/"
cp "$DIR/bin/jobs-client.sh"       "$T/bin/"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
# scratch-closure-allow: BH-4080 the lane under test runs under env -i or in its own harness root, so HARNESS_DEPLOYMENT_FILE does not reach it and bin/lib/deployment.sh must sit beside its copied libs
cp "$DIR/bin/lib/deployment.sh" "$T/bin/lib/"  # BH-4080: req.sh builds the worker URL from it
chmod +x "$T/bin/extra-usage-track.sh"
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"

# oauth-refresh is stubbed: the real one shells out to the claude CLI. What
# matters to THIS test is that every login gets refreshed with its own config
# dir, so the stub records the argument and nothing else.
cat > "$T/bin/oauth-refresh.sh" <<'EOF'
#!/bin/bash
echo "$1" >> "$REFRESH_SINK"
exit 0
EOF
chmod +x "$T/bin/oauth-refresh.sh"

# lane-alert is the one alert path, and since 2026-09-15 it is also where this
# script's DEDUPE lives — the marker files it used to keep for itself are gone
# (see the overage block in bin/extra-usage-track.sh for the microsecond bug
# that ended them). So the REAL lane-alert runs here, against this sandbox's
# $HARNESS, and the stub moves one layer down to beat.sh: an assertion on
# "$T/alerts" therefore reads what would actually have reached the console,
# through the state machine, rather than what this script merely tried to say.
ln -sf "$DIR/bin/lane-alert.sh" "$T/bin/lane-alert.sh"
mkdir -p "$T/bin/lib"; ln -sf "$DIR/bin/lib/alert-state.sh" "$T/bin/lib/alert-state.sh"
ln -sf "$DIR/bin/alert_family.py" "$T/bin/alert_family.py"
cat > "$T/bin/beat.sh" <<'EOF'
#!/bin/bash
jq -r '.line // ""' <<<"${1:-}" >> "$ALERT_SINK"
exit 0
EOF
chmod +x "$T/bin/beat.sh"

# curl is stubbed for the DB push only (jobs-client's transport). The usage
# endpoint is a REAL http server below, because the script's classifier reads an
# HTTP status off a urllib traceback and a stub that cannot produce one would
# test nothing.
mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
printf '{"snapshot":{}}\n200\n'
CURL
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

# ── the usage endpoint, answering per credential ────────────────────────────
# token "live-own"  -> 200, weekly 42%, meter $12 of $35000 (inside credits)
# token "live-mk"   -> 200, weekly 100%, meter $34,300 of $35,000 (98.0% of cap)
# token "setup-tok" -> 429, the permanent answer a setup-token gets
# anything else     -> 403 user:profile
cat > "$T/server.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

BODIES = {
    "live-own": {"five_hour": {"utilization": 10}, "seven_day": {"utilization": 42, "resets_at": "2026-09-21T00:00:00Z"},
                 "extra_usage": {"is_enabled": True, "used_credits": 1200, "monthly_limit": 3500000,
                                 "utilization": 0, "decimal_places": 2, "spend_limit_reached": False}},
    "live-mk":  {"five_hour": {"utilization": 90}, "seven_day": {"utilization": 100, "resets_at": "2026-09-21T00:00:00Z"},
                 "extra_usage": {"is_enabled": True, "used_credits": 3430000, "monthly_limit": 3500000,
                                 "utilization": 98, "decimal_places": 2, "spend_limit_reached": False}},
}

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        tok = (self.headers.get("Authorization") or "").replace("Bearer ", "")
        if tok in BODIES:
            body = json.loads(json.dumps(BODIES[tok]))
            # THE 68-LINE BUG, REPRODUCED. The real endpoint returns resets_at
            # with MICROSECONDS, and they move on every single poll:
            # 2026-09-17T04:00:00.049571+00:00, then ...322755+00:00. The old
            # dedupe marker was keyed on that string, so it never matched what
            # it had just written and "once per weekly window" fired every 15
            # minutes. A fixed timestamp here would let that bug pass.
            body["seven_day"]["resets_at"] = "2026-09-21T00:00:00.%06d+00:00" % (
                int.from_bytes(os.urandom(3), "big") % 1000000)
            b = json.dumps(body).encode()
            self.send_response(200); self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
        elif tok == "setup-tok":
            self.send_error(429, "Too Many Requests")
        else:
            self.send_error(403, "OAuth token does not meet scope requirement user:profile")
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
[ -n "$PORT" ] && ok || { echo "FAIL: the fixture usage endpoint did not start"; echo "extra-usage-logins-test: 0 pass, 1 fail"; exit 1; }
export OAUTH_USAGE_URL="http://127.0.0.1:$PORT/api/oauth/usage"

cred() { # cred <dir> <token>
  printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"r","expiresAt":99999999999999}}\n' "$2" > "$1/.credentials.json"
}
cred "$T/cfg-own" live-own
cred "$T/cfg-mk"  live-mk
# cfg-none deliberately holds no credentials.json at all.

run() { # run [env=val ...] — one tracker run in the sandbox
  : > "$T/reqs"; : > "$T/alerts"; : > "$T/refreshed"
  env -i PATH="$PATH" HOME="$T" HARNESS="$T" CLAUDE_CONFIG_DIR="$T/cfg-own" \
    OAUTH_USAGE_URL="$OAUTH_USAGE_URL" REQ_SINK="$T/reqs" ALERT_SINK="$T/alerts" \
    REFRESH_SINK="$T/refreshed" "$@" bash "$T/bin/extra-usage-track.sh" hub >"$T/out" 2>"$T/err"
}
reset_state() { rm -rf "$T/logs"/*.csv "$T/state"/* "$T/flags"/* 2>/dev/null; : > "$T/logs/ALERTS.log"; : ; }

# ===========================================================================
# 1. NO CATALOG, NO OVERRIDE: byte-identical to the behaviour every box had
# ===========================================================================
# The fallback is the whole reason a box the catalog has never heard of is not
# silently downgraded to polling nothing by this change.
reset_state
run
[ -f "$T/logs/extra-usage.csv" ] \
  && ok || bad "a box with no catalog entry stopped writing the legacy logs/extra-usage.csv"
[ "$(ls "$T"/logs/extra-usage-*.csv 2>/dev/null | wc -l)" = 0 ] \
  && ok || bad "a single-login box wrote a suffixed CSV — every existing reader looks at the unsuffixed path"
grep -q "^$T/cfg-own\$" "$T/refreshed" \
  && ok || bad "the login was not refreshed before it was read"
# The DB row carries the BOX id as its label, which is what every row before
# this change carries.
grep -q '"box":"hub"' "$T/reqs" \
  && ok || bad "the fallback login did not post under the box id: $(cat "$T/reqs")"

# ===========================================================================
# 2. THE CATALOG DRIVES THE LIST: one box, two accounts, two meters
# ===========================================================================
cat > "$T/catalog/cost-accounts.json" <<EOF
{
  "anthropic_runners": ["claude"],
  "accounts": {
    "hub-gmail":         {"login": {"box": "hub", "config_dir": "$T/cfg-own"},
                          "auth_accounts": [], "boxes": {"cost_rows": [], "jobs": []}},
    "project-6-account": {"login": {"box": "hub", "config_dir": "$T/cfg-mk"},
                          "auth_accounts": [], "boxes": {"cost_rows": [], "jobs": []}},
    "elsewhere":         {"login": {"box": "project-3", "config_dir": "$T/cfg-none"},
                          "auth_accounts": [], "boxes": {"cost_rows": [], "jobs": []}}
  }
}
EOF
reset_state
run
# Both logins are refreshed, each with ITS OWN config dir.
grep -q "^$T/cfg-own\$" "$T/refreshed" && grep -q "^$T/cfg-mk\$" "$T/refreshed" \
  && ok || bad "not every catalogued login on this box was refreshed: $(cat "$T/refreshed")"
# ...and the login belonging to ANOTHER box is not touched by this box.
grep -q "cfg-none" "$T/refreshed" \
  && bad "this box polled a login the catalog assigns to another box" || ok
# The box's own login keeps the legacy file name; the second one is suffixed by
# label, so two accounts on one box cannot overwrite each other's series.
[ -f "$T/logs/extra-usage.csv" ] && [ -f "$T/logs/extra-usage-project-6-account.csv" ] \
  && ok || bad "two logins did not produce two CSVs: $(ls "$T/logs")"
grep -q '"box":"hub-gmail"' "$T/reqs" && grep -q '"box":"project-6-account"' "$T/reqs" \
  && ok || bad "the two accounts did not post under their own labels: $(cat "$T/reqs")"
[ "$(grep -c 'metrics/extra-usage' "$T/reqs")" = 2 ] \
  && ok || bad "expected exactly two meter pushes, got $(grep -c 'metrics/extra-usage' "$T/reqs")"
# The numbers are per account, not shared: gmail is inside its credits, the
# project-6 account is at 98% of a $35,000 cap.
jq -es '[.[] | select(.box=="project-6-account")] | .[0] | .extra_used_usd=="34300.00" and .extra_limit_usd=="35000.00" and .weekly_pct=="100" and .status=="ok"' \
   < <(grep -o '{"box".*}' "$T/reqs") >/dev/null 2>&1 \
  && ok || bad "the project-6 account's row does not carry its own meter: $(cat "$T/reqs")"
jq -es '[.[] | select(.box=="hub-gmail")] | .[0] | .extra_used_usd=="12.00" and .weekly_pct=="42"' \
   < <(grep -o '{"box".*}' "$T/reqs") >/dev/null 2>&1 \
  && ok || bad "the hub's own login's row does not carry its own meter: $(cat "$T/reqs")"

# ===========================================================================
# 3. EXTRA_USAGE_LOGINS OVERRIDES THE CATALOG
# ===========================================================================
# One box, one operator decision — the override is what an operator reaches for
# when the catalog has not caught up with a login they just provisioned.
reset_state
run EXTRA_USAGE_LOGINS="only-this=$T/cfg-mk"
[ "$(grep -c 'metrics/extra-usage' "$T/reqs")" = 1 ] && grep -q '"box":"only-this"' "$T/reqs" \
  && ok || bad "EXTRA_USAGE_LOGINS did not replace the catalogued list: $(cat "$T/reqs")"

# ===========================================================================
# 4. A LOGIN THAT CANNOT READ ITS METER WRITES A ROW, NOT SILENCE
# ===========================================================================
# project-2/project-3/project-4 run 1-year setup-tokens: HTTP 429 forever. Until now they
# reported that by writing nothing, which in the DB is indistinguishable from a
# box whose cron is dead — and only one of those is fixed by provisioning a
# login.
cred "$T/cfg-mk" setup-tok
reset_state
run EXTRA_USAGE_LOGINS="dead-login=$T/cfg-mk"
ROW=$(tail -1 "$T/logs/extra-usage-dead-login.csv" 2>/dev/null)
case "$ROW" in *,no-login) ok ;; *) bad "a refused login did not record status=no-login: '$ROW'" ;; esac
# NO NUMBERS. A failed poll is not a $0 meter, and a zero here would be summed
# into a fleet total as if the account had spent nothing.
[ "$(printf '%s' "$ROW" | cut -d, -f6)" = "" ] \
  && ok || bad "a failed poll wrote a meter figure it does not have: '$ROW'"
jq -es '.[0] | .status=="no-login" and .extra_used_usd==""' < <(grep -o '{"box".*}' "$T/reqs") >/dev/null 2>&1 \
  && ok || bad "the no-login row did not reach the DB with an empty meter: $(cat "$T/reqs")"
# The reason is named, not collapsed into "poll failed".
grep -q '429' "$T/logs/agent-rules.log" \
  && ok || bad "the 429 was not named as a credential that cannot read this endpoint"

# A login directory with no credential at all is the THIRD nothing: a permanent
# config gap, and it must not read as a transient failure either.
reset_state
run EXTRA_USAGE_LOGINS="no-cred=$T/cfg-none"
case "$(tail -1 "$T/logs/extra-usage-no-cred.csv" 2>/dev/null)" in
  *,no-login) ok ;;
  *) bad "a login directory with no credentials.json did not record no-login" ;;
esac

# ===========================================================================
# 5. THE ENV TOKEN IS A FALLBACK FOR THE BOX'S OWN LOGIN ONLY
# ===========================================================================
# CLAUDE_CODE_OAUTH_TOKEN belongs to whichever account the LANES bill. Falling
# back to it for a NAMED login would post that account's meter under this
# label — precisely the mislabelling this whole change exists to end.
reset_state
run EXTRA_USAGE_LOGINS="named=$T/cfg-none" CLAUDE_CODE_OAUTH_TOKEN=live-own
case "$(tail -1 "$T/logs/extra-usage-named.csv" 2>/dev/null)" in
  *,no-login) ok ;;
  *) bad "a NAMED login fell back to the env token and filed another account's meter under its label" ;;
esac
# ...while the box's own login still may, which is what keeps a box whose
# credentials.json has gone stale reporting at all.
reset_state
rm -f "$T/cfg-own/.credentials.json"
run CLAUDE_CODE_OAUTH_TOKEN=live-own
case "$(tail -1 "$T/logs/extra-usage.csv" 2>/dev/null)" in
  *,ok) ok ;;
  *) bad "the box's own login lost its env-token fallback: $(tail -1 "$T/logs/extra-usage.csv")" ;;
esac
cred "$T/cfg-own" live-own

# ===========================================================================
# 6. THE CAP ALERT: once per label, deduped for 6h
# ===========================================================================
# At the cap every lane billing the account STOPS, so this is an outage warning
# and not a billing note. It is also the alert the 2026-09-14 project-6 stopgap
# carried, folded in here so removing that script loses nothing.
cred "$T/cfg-mk" live-mk
reset_state
run EXTRA_USAGE_LOGINS="mk=$T/cfg-mk"
grep -q 'EXTRA-USAGE CAP \[mk\]' "$T/alerts" \
  && ok || bad "98% of the extra-usage cap raised no alert: $(cat "$T/alerts")"
grep -q '34300.00 of \$35000.00' "$T/alerts" \
  && ok || bad "the cap alert does not name the meter and the cap: $(cat "$T/alerts")"
# Second run, same hour: the marker is fresh, so nothing is raised.
run EXTRA_USAGE_LOGINS="mk=$T/cfg-mk"
[ ! -s "$T/alerts" ] \
  && ok || bad "the cap alert re-fired inside the 6h dedupe window: $(cat "$T/alerts")"
# ...and the dedupe is PER LABEL: a second account at its cap is a second
# outage, not a duplicate of the first.
run EXTRA_USAGE_LOGINS="mk=$T/cfg-mk,twin=$T/cfg-mk"
grep -q 'EXTRA-USAGE CAP \[twin\]' "$T/alerts" \
  && ok || bad "a different account at its cap was deduped against another account's marker"
grep -q 'EXTRA-USAGE CAP \[mk\]' "$T/alerts" \
  && bad "the first account's alert re-fired inside its own dedupe window" || ok
# An account inside its credits raises nothing at all.
reset_state
run EXTRA_USAGE_LOGINS="own=$T/cfg-own"
[ ! -s "$T/alerts" ] \
  && ok || bad "an account at 0% of its cap raised an alert: $(cat "$T/alerts")"

# ===========================================================================
# 6b. THE OVERAGE ALERT: once while it holds, once more when it ENDS
# ===========================================================================
# 68 identical overage lines in 24h is what got the alert state machine written.
# The condition is the ACCOUNT being over, so it is stated once however many
# times it is observed — and the fixture endpoint above churns resets_at on
# every request, which is precisely what defeated the marker this replaces.
cred "$T/cfg-mk" live-mk
reset_state
for _ in 1 2 3 4; do run EXTRA_USAGE_LOGINS="mk=$T/cfg-mk"; cat "$T/alerts" >> "$T/alerts-all"; done
N=$(grep -c 'account is in overage' "$T/alerts-all" 2>/dev/null || echo 0)
[ "$N" = 1 ] && ok || bad "4 polls of one account in overage raised $N alerts, want 1"
# ...and when the account drops back inside its credits, that is said ONCE.
: > "$T/alerts-all"
cred "$T/cfg-mk" live-own
run EXTRA_USAGE_LOGINS="mk=$T/cfg-mk"
grep -q 'out of overage' "$T/alerts" \
  && ok || bad "leaving overage was never reported: $(cat "$T/alerts")"
run EXTRA_USAGE_LOGINS="mk=$T/cfg-mk"
grep -q 'out of overage' "$T/alerts" \
  && bad "the resolve re-fired on a condition that was already closed" || ok
cred "$T/cfg-mk" live-mk

# ===========================================================================
# 7. THE KILL SWITCHES
# ===========================================================================
reset_state
run EXTRA_USAGE_TRACK=0
[ ! -f "$T/logs/extra-usage.csv" ] \
  && ok || bad "EXTRA_USAGE_TRACK=0 still polled"
reset_state
touch "$T/flags/extra-usage-track-off"
run
[ ! -f "$T/logs/extra-usage.csv" ] \
  && ok || bad "flags/extra-usage-track-off still polled"
rm -f "$T/flags/extra-usage-track-off"

# ===========================================================================
# 8. AN OLD 8-COLUMN CSV IS UPGRADED IN PLACE, ONCE
# ===========================================================================
# A header that does not name every column it carries is how a DictReader
# silently drops one — cost-rollup.sh reads this file by name.
reset_state
OLDHDR='ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,extra_used_usd,spend_limit_reached,in_overage'
printf '%s\n2026-09-01T00:00:00Z,1,2,x,1,3.00,0,0\n' "$OLDHDR" > "$T/logs/extra-usage.csv"
run
head -1 "$T/logs/extra-usage.csv" | grep -q 'in_overage,extra_limit_usd,extra_pct,status$' \
  && ok || bad "an 8-column header was not upgraded: $(head -1 "$T/logs/extra-usage.csv")"
run
[ "$(head -1 "$T/logs/extra-usage.csv" | grep -c 'status')" = 1 ] \
  && ok || bad "the header upgrade ran twice: $(head -1 "$T/logs/extra-usage.csv")"
# The pre-existing row is untouched: this is an additive change to a file other
# scripts have been reading for weeks.
grep -q '^2026-09-01T00:00:00Z,1,2,x,1,3.00,0,0$' "$T/logs/extra-usage.csv" \
  && ok || bad "the upgrade rewrote an existing row"

echo "extra-usage-logins-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
