#!/bin/bash
# tests/metrics-ledger-test.sh — the four metrics series, driven for real.
#
# THE PROPERTIES UNDER TEST, in the order they matter:
#
#  1. THE FILE STILL WINS. Every producer writes its CSV first and pushes
#     second, and a worker that is down, slow or wrong must leave the CSV byte
#     for byte what it would have been. The whole point of moving metrics into
#     the DB is being able to READ them from somewhere other than the hub; if
#     the move can stop the MEASURING, it is a downgrade wearing an upgrade's
#     name.
#  2. ONE ROW PER DAY, from a producer whose local clock is NOT UTC. This is
#     the bug: logs/orchestrator-burn.csv carried six identical rows a day for
#     as long as it existed, because the python read `date.today()` (local) and
#     the shell dedupe read `date -u +%F`. On a UTC-5 box the two disagree for
#     five hours a night, so five ticks appended a duplicate of YESTERDAY. The
#     test runs the real script under TZ=America/Chicago at 02:00 UTC, which is
#     inside that window, and demands one row.
#  3. THE PUSH CARRIES THE ROW'S OWN DAY, not a second clock reading — the same
#     property one layer up. A row keyed on a day nobody measured is worse than
#     no row.
#  4. THE METER FAILS LOUDLY. bin/extra-usage-track.sh polled and failed 120
#     times between 2026-08-24 and 2026-08-29 and wrote every one of them to a
#     run log. Once the meter is stale it must reach ALERTS.log, once a day.
#
# Driven, not grepped: it runs the REAL bin/ scripts against a stubbed curl and
# reads back the CSVs and the request bodies. A grep would pass on a version
# that pushes the row and forgets to write the file.
# Run from anywhere: tests/metrics-ledger-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
# BH-3223: scratch.sh blanks JOBS_URL; this suite's fake curl answers a worker URL.
export JOBS_URL=https://jobs.invalid
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/state" "$T/flags" "$T/bin" "$T/env" "$T/fakebin" "$T/state/cost"
cp "$DIR/bin/jobs-client.sh"        "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/orchestrator-burn.sh"  "$T/bin/orchestrator-burn.sh"
cp "$DIR/bin/extra-usage-track.sh"  "$T/bin/extra-usage-track.sh"
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Stub curl: records every request so bodies can be read back, and can be told
# to be down. Nothing here talks to a network.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in down) exit 7 ;; esac
printf '{"ok":true}\n200\n'
EOF
chmod +x "$T/fakebin/curl"

client() { # client <verb> [args...]
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid REQ_SINK="$T/req.log" BOX_NAME=testbox ${EXTRA_ENV:-}
    bash "$T/bin/jobs-client.sh" "$@" >/dev/null 2>&1 )
}

# --- 1. each helper posts to its own route with the row's own key ------------
rm -f "$T/req.log"
client metric-burn 2026-08-28 429 858 441727 19418261 3858722 134.62 65858 45264
grep -q 'POST .*/api/metrics/burn .*"day":"2026-08-28"' "$T/req.log" \
  && ok || bad "metric-burn did not post the day it was given: $(head -1 "$T/req.log")"
grep -q '"usd_equiv":"134.62"' "$T/req.log" \
  && ok || bad "metric-burn dropped usd_equiv"

rm -f "$T/req.log"
client metric-extra-usage hub 2026-08-29T23:45:24Z 14 71 2026-09-03T03:59:59Z 1 19792.21 0 0
grep -q 'POST .*/api/metrics/extra-usage .*"box":"hub"' "$T/req.log" \
  && ok || bad "metric-extra-usage lost the box"
# The BOX is the account it bills, so a caller's own name must outrank the one
# jobs-client resolves for itself.
grep -q '"box":"testbox"' "$T/req.log" \
  && bad "metric-extra-usage overwrote the caller's box with its own name" || ok

rm -f "$T/req.log"
client metric-outcome project-3 https://github.com/x/y/pull/9 reverted 2026-08-29 "revert abc123"
grep -q 'POST .*/api/metrics/outcomes .*"outcome":"reverted"' "$T/req.log" \
  && ok || bad "metric-outcome did not post the outcome"

# --- 2. a pr-costs sweep goes in ONE request, commas and all -----------------
# stage_breakdown carries "execute:110.77;review:10.72" and build_dirs carries a
# ";"-joined list; both sit inside quoted CSV fields that contain commas in the
# real file. A line-splitter would silently shear the columns.
rm -f "$T/req.log"
cat > "$T/state/cost/cost-per-pr.csv" <<'EOF'
pr_url,cost_usd,input_toks,output_toks,cache_read,cache_write,stage_breakdown,build_dirs
https://github.com/example-org/project-3/pull/262,136.80,232,117415,7450640,471688,execute:110.77;review:10.72,pool-project-3-TK-107
https://github.com/example-org/project-4/pull/9,4.10,10,20,30,40,"plan:4.10,fix:0.00",dir-a;dir-b
EOF
client metric-pr-costs "$T/state/cost/cost-per-pr.csv"
[ "$(grep -c 'POST .*/api/metrics/pr-costs' "$T/req.log")" = 1 ] \
  && ok || bad "the sweep did not go in exactly one request"
grep -q '"stage_breakdown": "plan:4.10,fix:0.00"' "$T/req.log" \
  && ok || bad "the embedded comma was split instead of parsed: $(head -c 400 "$T/req.log")"
grep -q 'pull/262' "$T/req.log" && grep -q 'pull/9' "$T/req.log" \
  && ok || bad "the sweep lost a row"

# --- 3. fail-open: every helper is silent and harmless when the worker is down
for v in "metric-burn 2026-08-28 1 1 1 1 1 1 1 1" \
         "metric-extra-usage hub 2026-08-29T00:00:00Z 1 1 x 1 1 0 0" \
         "metric-outcome r p reverted 2026-08-29 e" \
         "metric-pr-costs $T/state/cost/cost-per-pr.csv"; do
  OUT=$( ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
             JOBS_URL=https://jobs.invalid CURL_MODE=down
           bash "$T/bin/jobs-client.sh" $v ) 2>&1 )
  RC=$?
  [ "$RC" != 0 ] && [ -z "$OUT" ] \
    && ok || bad "'$v' was not fail-open on an outage (rc=$RC, out='$OUT')"
done

# ═══ orchestrator-burn: one row per day, on a box whose clock is not UTC ═════
# One transcript, two usage blocks, both stamped on 2026-08-28 UTC.
BURNDIR="$T/claude/projects/-root-orchestrator"; mkdir -p "$BURNDIR"
cat > "$BURNDIR/a.jsonl" <<'EOF'
{"timestamp":"2026-08-28T10:00:00Z","message":{"usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":5000,"cache_creation_input_tokens":50}}}
{"timestamp":"2026-08-28T22:00:00Z","message":{"usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":9000,"cache_creation_input_tokens":50}}}
EOF
# The script hardcodes the transcript path, so the test points the whole run at
# a fake root by rewriting that one literal. Everything else is the real script.
sed "s#/root/.claude/projects/-root-orchestrator#$BURNDIR#" \
  "$DIR/bin/orchestrator-burn.sh" > "$T/bin/burn.sh"
sed -i "s#^H=/root/harness#H=\"\${HARNESS:-/root/harness}\"#" "$T/bin/burn.sh"

# There is no libfaketime on these boxes, so the clock is moved the only way
# that is honest here: the test asserts the property on the REAL clock for the
# UTC day, and separately proves the dedupe key comes from the ROW rather than
# from a second reading of the clock — which is the thing that made the two
# disagree. See tests 4 and 5.
rm -f "$T/logs/orchestrator-burn.csv" "$T/req.log"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" TZ=America/Chicago REQ_SINK="$T/req.log"
  for _ in 1 2 3 4 5 6; do bash "$T/bin/burn.sh" >/dev/null 2>&1; done )

# --- 4. six ticks, one row -------------------------------------------------
ROWS=$(($(grep -c '' "$T/logs/orchestrator-burn.csv" 2>/dev/null || echo 1) - 1))
DAYS=$(tail -n +2 "$T/logs/orchestrator-burn.csv" | cut -d, -f1 | sort -u | wc -l)
[ "$ROWS" = "$DAYS" ] \
  && ok || bad "six hourly ticks left $ROWS rows across $DAYS days — the day is not the key"

# --- 5. the row's day and the UTC day are the SAME day ----------------------
# The regression in one line: on a UTC-5 box the producer used to write a row
# dated in local time while the dedupe stripped rows dated in UTC.
CSVDAY=$(tail -1 "$T/logs/orchestrator-burn.csv" | cut -d, -f1)
[ "$CSVDAY" = "$(TZ=UTC date -u +%F)" ] \
  && ok || bad "the row is dated $CSVDAY under TZ=America/Chicago, UTC says $(date -u +%F)"

# --- 6. the push carries that same day, and the CSV is written either way ----
grep -q "POST .*/api/metrics/burn .*\"day\":\"$CSVDAY\"" "$T/req.log" \
  && ok || bad "the burn push did not carry the row's own day"
rm -f "$T/logs/orchestrator-burn.csv"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" TZ=America/Chicago CURL_MODE=down
  bash "$T/bin/burn.sh" >/dev/null 2>&1 )
[ -s "$T/logs/orchestrator-burn.csv" ] \
  && ok || bad "a worker outage cost the CSV row — the file must be written first"

# ═══ extra-usage: the meter fails LOUDLY once it is stale ═══════════════════
EU="$T/bin/eu.sh"
sed "s#^H=/root/harness#H=\"\${HARNESS:-/root/harness}\"#" \
  "$DIR/bin/extra-usage-track.sh" > "$EU"
# python3 is stubbed so the poll fails without touching the network. It writes
# the shape of a real refusal onto stderr, which is the only thing the
# classifier is allowed to read.
cat > "$T/fakebin/python3" <<'EOF'
#!/bin/bash
cat >/dev/null 2>&1
echo "urllib.error.HTTPError: HTTP Error 429: Too Many Requests" >&2
exit 1
EOF
chmod +x "$T/fakebin/python3"
eu_run() { ( export PATH="$T/fakebin:$PATH" HARNESS="$T" ${EXTRA_ENV:-}
             bash "$EU" hub >/dev/null 2>&1 ); }

# A CSV whose last row is five days old: the meter has stopped.
printf 'ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,extra_used_usd,spend_limit_reached,in_overage\n' > "$T/logs/extra-usage.csv"
printf '%s,27,100,x,1,18861.90,0,1\n' "$(date -u -d '5 days ago' +%Y-%m-%dT%H:%M:%SZ)" >> "$T/logs/extra-usage.csv"
: > "$T/logs/ALERTS.log"
eu_run

# --- 7. a 429 is its own named state, not "transient" -----------------------
grep -qi '429' "$T/state/extra-usage-unavailable" \
  && ok || bad "a 429 was filed as something else: $(cat "$T/state/extra-usage-unavailable" 2>/dev/null)"

# --- 8. ...and a stale meter reaches ALERTS.log -----------------------------
grep -q 'EXTRA-USAGE METER DOWN' "$T/logs/ALERTS.log" \
  && ok || bad "a five-day-dead meter never reached ALERTS.log"

# --- 9. ...exactly once a day, not once per hourly tick ---------------------
eu_run; eu_run
[ "$(grep -c 'EXTRA-USAGE METER DOWN' "$T/logs/ALERTS.log")" = 1 ] \
  && ok || bad "the stale alert fired $(grep -c 'EXTRA-USAGE METER DOWN' "$T/logs/ALERTS.log") times in one day"

# --- 10. a FRESH failure is not an alert -----------------------------------
# One blip is not news. The alarm is on the meter having stopped, not on a poll
# having missed, or it becomes the alarm that always rings.
rm -f "$T/flags/alerted-extra-usage-stale-"*
: > "$T/logs/ALERTS.log"
printf '%s,27,100,x,1,18861.90,0,1\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$T/logs/extra-usage.csv"
eu_run
grep -q 'EXTRA-USAGE METER DOWN' "$T/logs/ALERTS.log" \
  && bad "a single miss on a live meter raised an alert" || ok

echo "metrics-ledger-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
