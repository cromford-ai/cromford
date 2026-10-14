#!/bin/bash
# tests/split-watchdog-client.bh-1806-test.sh — the split-watchdog ledger verbs
# (BH-1806, BH-1793.1) through the REAL bin/jobs-client.sh and its real
# _jobs_req, with a fake `curl` on PATH that hands each request to the real
# worker (worker/jobs/src/routes/split-watchdog.js via worker.fetch) over ONE
# file-backed node:sqlite DB. So every sw_* call below runs the shipped shell,
# the shipped transport, the shipped router and the shipped SQL.
#   S1. sw_record -> `first`, rc 0
#   S2. sw_record again -> `repeat 2`, rc 0
#   S3. sw_seen -> the outcome; an unrecorded reason -> nothing, rc 0
#   S4. a reason with spaces, `&`, `#` and `=` round-trips through the query string
#   S5. outage (503, transport down, 200 without the key): every verb rc 1, no stdout
#   S6. sw_list -> one 11-field TSV line per row; the family argument filters
#   S7. sw_actions_today -> acted rows with today's last_at only; the request
#       carries outcome=acted and since=<UTC date>
#   S8. every request the verbs made went to /api/split-watchdog
# Run from anywhere: tests/split-watchdog-client.bh-1806-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

JLIB="$DIR/bin/lib/jobs/split-watchdog.sh"
ROUTE="$DIR/worker/jobs/src/routes/split-watchdog.js"
for f in "$JLIB" "$ROUTE"; do [ -f "$f" ] && ok || bad "missing $f"; done

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "split-watchdog-client: SKIPPED, this node has no node:sqlite (CI's worker/jobs job runs the route suite)"
  echo "split-watchdog-client.bh-1806: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
# core.js imports the GENERATED, git-ignored catalog/lanes.json statically.
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >"$T/lb.out" 2>&1 \
  || bad "catalog/lanes.json could not be composed: $(cat "$T/lb.out")"

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$H/bin/" && cp "$DIR"/bin/lib/*.sh "$H/bin/lib/" 2>/dev/null
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"

DB="$T/d1.sqlite"
cat >"$T/drv.mjs" <<EOF
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import worker from '$DIR/worker/jobs/src/index.js';
import { d1 } from '$DIR/worker/jobs/test/lib/d1-sqlite.bh-1030.js';
const db = new DatabaseSync('$DB');
db.exec(readFileSync('$DIR/worker/jobs/schema.sql', 'utf8'));
const [method, url, body] = process.argv.slice(2);
const res = await worker.fetch(new Request(url, {
  method, headers: { authorization: 'Bearer s', 'content-type': 'application/json' },
  body: body ? body : undefined,
}), { DB: d1(db), HARNESS_SECRET: 's' });
process.stdout.write((await res.text()) + '\n' + res.status);
EOF
# The fake curl: `-X M`, `--data-binary B` (or @file), URL last — _jobs_req's shape.
cat >"$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
[ -n "${REQ_SINK:-}" ] && printf '%s %s\n' "$M" "$URL" >> "$REQ_SINK"
case "${CURL_MODE:-up}" in
  down) exit 7 ;;
  503) printf '{"error":"split_watchdog_actions unavailable"}\n503'; exit 0 ;;
  empty) printf '{}\n200'; exit 0 ;;
esac
exec node "$DRV" "$M" "$URL" "$BODY"
STUB
chmod +x "$T/fakebin/curl"

# sw <mode> <verb args...> — one verb through the real client, in a subshell.
# Stdout is the verb's stdout; the last line of $T/rc is its rc.
sw() {
  local mode="$1"; shift
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=s JOBS_URL=https://jobs.test \
           JOBS_BOX=box-a JOBS_RETRIES=0 JOBS_RETRY_SLEEP=0 JOBS_TIMEOUT=10 JOBS_ALERT=0 \
           CURL_MODE="$mode" REQ_SINK="$T/req.txt" DRV="$T/drv.mjs" NODE_OPTIONS=--no-warnings
    # shellcheck source=/dev/null
    . "$H/bin/jobs-client.sh" || exit 3
    "$@"; echo "$?" > "$T/rc" )
}
rc() { cat "$T/rc"; }
: > "$T/req.txt"

# --- S1 / S2 -------------------------------------------------------------------
out=$(sw up sw_record cromford BH-1793 BH-1806 enqueue PLAN_STALE acted)
[ "$(rc)" = 0 ] && [ "$out" = first ] && ok || bad "S1 sw_record rc=$(rc) out=[$out], want rc 0 and first"
out=$(sw up sw_record cromford BH-1793 BH-1806 enqueue PLAN_STALE acted)
[ "$(rc)" = 0 ] && [ "$out" = "repeat 2" ] && ok || bad "S2 sw_record rc=$(rc) out=[$out], want rc 0 and 'repeat 2'"
row=$(node --no-warnings -e "const {DatabaseSync}=require('node:sqlite');const d=new DatabaseSync('$DB');console.log(JSON.stringify(d.prepare('SELECT actor,repeats FROM split_watchdog_actions').all()))")
[ "$row" = '[{"actor":"box-a","repeats":2}]' ] && ok || bad "S2 the ledger row is not one row with actor box-a, repeats 2: $row"

# --- S3 ------------------------------------------------------------------------
out=$(sw up sw_seen cromford BH-1806 enqueue PLAN_STALE)
[ "$(rc)" = 0 ] && [ "$out" = acted ] && ok || bad "S3 sw_seen rc=$(rc) out=[$out], want rc 0 and acted"
out=$(sw up sw_seen cromford BH-1806 enqueue NEVER_RECORDED)
[ "$(rc)" = 0 ] && [ -z "$out" ] && ok || bad "S3 sw_seen on an unrecorded reason rc=$(rc) out=[$out], want rc 0 and nothing"

# --- S4 ------------------------------------------------------------------------
R='plan  stale & #2 = x?'
out=$(sw up sw_record cromford BH-1793 BH-1807 reenqueue "$R" failed)
[ "$(rc)" = 0 ] && [ "$out" = first ] && ok || bad "S4 sw_record with a hostile reason rc=$(rc) out=[$out]"
out=$(sw up sw_seen cromford BH-1807 reenqueue "$R")
[ "$(rc)" = 0 ] && [ "$out" = failed ] && ok || bad "S4 sw_seen did not find the hostile reason: rc=$(rc) out=[$out]"

# --- S5: outage is rc 1 and silent, never an empty answer ------------------------
for mode in 503 down; do
  for call in "sw_record cromford F C enqueue r acted" "sw_seen cromford BH-1806 enqueue PLAN_STALE" \
              "sw_list cromford" "sw_actions_today cromford"; do
    # shellcheck disable=SC2086
    out=$(sw "$mode" $call)
    [ "$(rc)" = 1 ] && [ -z "$out" ] && ok || bad "S5 ($mode) $call rc=$(rc) out=[$out], want rc 1 and nothing"
  done
done
for call in "sw_seen cromford BH-1806 enqueue PLAN_STALE" "sw_record cromford F C enqueue r acted" \
            "sw_list cromford" "sw_actions_today cromford"; do
  # shellcheck disable=SC2086
  out=$(sw empty $call)
  [ "$(rc)" = 1 ] && [ -z "$out" ] && ok || bad "S5 (200 {}) $call rc=$(rc) out=[$out], want rc 1 and nothing"
done
out=$(sw up sw_record cromford "" C enqueue r acted)
[ "$(rc)" = 1 ] && [ -z "$out" ] && ok || bad "S5 a refused record (400, empty family) rc=$(rc) out=[$out], want rc 1"

# --- S6 ------------------------------------------------------------------------
sw up sw_record cromford BH-9000 BH-9001 enqueue 'tab	in reason' acted >/dev/null
out=$(sw up sw_list cromford)
n=$(printf '%s\n' "$out" | grep -c .)
[ "$(rc)" = 0 ] && [ "$n" = 3 ] && ok || bad "S6 sw_list rc=$(rc) lines=$n, want 3: [$out]"
bad_fields=$(printf '%s\n' "$out" | awk -F'\t' 'NF!=11' | wc -l | tr -d ' ')
[ "$bad_fields" = 0 ] && ok || bad "S6 every sw_list line must carry 11 fields: [$out]"
printf '%s\n' "$out" | awk -F'\t' '$3=="BH-1806" && $4=="enqueue" && $6=="acted" && $7=="2" && $10=="box-a" && $11=="PLAN_STALE" {f=1} END{exit !f}' \
  && ok || bad "S6 the BH-1806 line is not in column order project family child step reason_fp outcome repeats first_at last_at actor reason: [$out]"
out=$(sw up sw_list cromford BH-9000)
[ "$(rc)" = 0 ] && [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] && [ "$(printf '%s' "$out" | cut -f3)" = BH-9001 ] \
  && ok || bad "S6 sw_list <p> BH-9000 must print only that family's row: [$out]"

# --- S7 ------------------------------------------------------------------------
# Today: BH-1806/enqueue (acted), BH-1807/reenqueue (failed), BH-9001 (acted).
# Add one acted row last seen yesterday and one skipped today.
sw up sw_record cromford BH-1793 BH-1808 enqueue old acted >/dev/null
sw up sw_record cromford BH-1793 BH-1809 enqueue skip skipped >/dev/null
node --no-warnings -e "const {DatabaseSync}=require('node:sqlite');const d=new DatabaseSync('$DB');d.prepare(\"UPDATE split_watchdog_actions SET last_at=? WHERE child='BH-1808'\").run(new Date(Date.now()-86400000).toISOString())"
: > "$T/req.txt"
out=$(sw up sw_actions_today cromford)
[ "$(rc)" = 0 ] && [ "$out" = 2 ] && ok || bad "S7 sw_actions_today rc=$(rc) out=[$out], want 2"
grep -q "outcome=acted" "$T/req.txt" && grep -q "since=$(date -u +%F)" "$T/req.txt" \
  && ok || bad "S7 the request did not carry outcome=acted and since=$(date -u +%F): $(cat "$T/req.txt")"
out=$(sw up sw_actions_today cromford BH-9000)
[ "$(rc)" = 0 ] && [ "$out" = 1 ] && ok || bad "S7 sw_actions_today <p> BH-9000 rc=$(rc) out=[$out], want 1"

# --- S8 ------------------------------------------------------------------------
: > "$T/req.txt"
sw up sw_record cromford F C enqueue r acted >/dev/null
sw up sw_seen cromford C enqueue r >/dev/null
sw up sw_list cromford >/dev/null
sw up sw_actions_today cromford >/dev/null
other=$(grep -vE '^(GET|POST) https://jobs\.test/api/split-watchdog(\?|$)' "$T/req.txt")
[ "$(grep -c . "$T/req.txt")" = 4 ] && [ -z "$other" ] && ok \
  || bad "S8 the four verbs must make exactly four /api/split-watchdog requests: $(cat "$T/req.txt")"

echo "split-watchdog-client.bh-1806: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
