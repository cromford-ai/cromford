#!/bin/bash
# tests/triage-state-client-test.sh — TRIAGE-STATE slice 1: the jobs-client verbs
# for the per-ticket triage_state table, against the REAL worker route.
#
# _jobs_req is stubbed onto worker.fetch over ONE file-backed node:sqlite DB (the
# driver tests/file-claims-lib.bh-2524-test.sh uses), so every triage_state_*
# call below goes through the real router and the real SQL of
# worker/jobs/src/routes/triage-state.js:
#   C1. triage_state_put (one row) + triage_state_get -> the row, compact JSON
#   C2. an unknown key: triage_state_get rc 2, nothing on stdout
#   C3. triage_state_put with {rows:[...]} + triage_state_list (array) and due=1
#   C4. the CLI verbs of bin/jobs-client.sh name the three functions
#   C5. the REAL bin/lib/jobs/req.sh against a dead port: every verb rc != 0 and
#       no stdout (the client's fail-open contract)
# Run from anywhere: tests/triage-state-client-test.sh   (exit 0 = all pass)
# BH-6578: triaged_at is one hour before the run, never a fixed date. A
# client-turn verdict comes back after triaged_at + the nudge (14 days), so a
# fixed date made this fixture go red on the day the nudge ran out.
TRIAGED_AT=$(date -u -d "@$(( $(date -u +%s) - 3600 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || date -u -r "$(( $(date -u +%s) - 3600 ))" '+%Y-%m-%dT%H:%M:%SZ')
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

ROUTE="$DIR/worker/jobs/src/routes/triage-state.js"
[ -f "$ROUTE" ] && ok || bad "missing $ROUTE"

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "triage-state-client: SKIPPED, this node has no node:sqlite (CI's worker/jobs job runs the route suite)"
  echo "triage-state-client: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
# core.js imports the GENERATED, git-ignored catalog/lanes.json statically.
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >"$T/lb.out" 2>&1 \
  || bad "catalog/lanes.json could not be composed: $(cat "$T/lb.out")"

export HARNESS="$T" JOBS_HARNESS="$T" NODE_OPTIONS=--no-warnings
DB="$T/d1.sqlite"
cat >"$T/drv.mjs" <<EOF
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import worker from '$DIR/worker/jobs/src/index.js';
import { d1 } from '$DIR/worker/jobs/test/lib/d1-sqlite.bh-1030.js';
const db = new DatabaseSync('$DB');
db.exec(readFileSync('$DIR/worker/jobs/schema.sql', 'utf8'));
const [method, path, body] = process.argv.slice(2);
const res = await worker.fetch(new Request('https://jobs.test' + path, {
  method, headers: { authorization: 'Bearer s', 'content-type': 'application/json' },
  body: body ? body : undefined,
}), { DB: d1(db), HARNESS_SECRET: 's' });
process.stdout.write((await res.text()) + '\n' + res.status);
EOF
# The same rc mapping as bin/lib/jobs/req.sh's _jobs_req.
_jobs_req() {
  local out code
  out=$(node "$T/drv.mjs" "$1" "$2" "${3:-}") || return 1
  code=${out##*$'\n'}; out=${out%$'\n'*}
  case "$code" in
    2*) printf '%s' "$out"; return 0 ;;
    409) printf '%s' "$out"; return 9 ;;
    404) return 2 ;;
    *) return 1 ;;
  esac
}
# The verbs live in the queue module; load it alone so the stub above is the
# transport (the module never defines _jobs_req itself).
# shellcheck source=/dev/null
. "$DIR/bin/lib/jobs/queue.sh" || { bad "bin/lib/jobs/queue.sh did not source"; }
for f in triage_state_get triage_state_list triage_state_put; do
  command -v "$f" >/dev/null 2>&1 && ok || bad "C0 $f is not defined by bin/lib/jobs/queue.sh"
done
H=$(printf 'a%.0s' $(seq 64)); H2=$(printf 'b%.0s' $(seq 64))

# --- C1 -------------------------------------------------------------------------
jq -n --arg ta "$TRIAGED_AT" --arg h "$H" '{project:"cromford",ticket_key:"2657",ticket_label:"BH-2657",input_hash:$h,
  verdict:"buildable",verdict_hash:$h,triaged_at:$ta,next_recheck_at:"2099-01-01T00:00:00Z",
  reason:"DECISION launch",last_decision:"llm new",last_mode:"shadow"}' > "$T/one.json"
out=$(triage_state_put "$T/one.json"); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.upserted' 2>/dev/null)" = 1 ] && ok \
  || bad "C1 triage_state_put rc=$rc out=[$out]"
row=$(triage_state_get cromford 2657); rc=$?
[ "$rc" = 0 ] && ok || bad "C1 triage_state_get rc=$rc"
[ "$(printf '%s' "$row" | jq -r '.verdict + " " + .ticket_label + " " + (.verdict_hash == "'"$H"'" | tostring)')" = "buildable BH-2657 true" ] \
  && ok || bad "C1 the row read back is not the row written: [$row]"
[ "$(printf '%s' "$row" | wc -l | tr -d ' ')" = 0 ] && ok || bad "C1 the row must be ONE compact JSON object with no newline: [$row]"

# --- C2 -------------------------------------------------------------------------
out=$(triage_state_get cromford 9999); rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && ok || bad "C2 an unknown key must be rc 2 with no stdout (rc=$rc out=[$out])"
out=$(triage_state_get cromford); rc=$?
[ "$rc" != 0 ] && [ -z "$out" ] && ok || bad "C2 a missing key argument must be rc != 0 with no stdout (rc=$rc)"

# --- C3 -------------------------------------------------------------------------
jq -n --arg h "$H" --arg h2 "$H2" '{project:"cromford",rows:[
  {ticket_key:"1",input_hash:$h,last_decision:"skip unchanged"},
  {ticket_key:"2",input_hash:$h2,verdict:"triaged",verdict_hash:$h2,next_recheck_at:"2020-01-01T00:00:00Z"}]}' > "$T/batch.json"
out=$(triage_state_put "$T/batch.json"); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.upserted')" = 2 ] && ok || bad "C3 batch put rc=$rc out=[$out]"
list=$(triage_state_list cromford); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$list" | jq -r 'map(.ticket_key) | sort | join(",")')" = "1,2,2657" ] && ok \
  || bad "C3 triage_state_list must print the project's rows as a JSON array (rc=$rc out=[$list])"
due=$(triage_state_list cromford due); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$due" | jq -r 'map(.ticket_key) | join(",")')" = "2" ] && ok \
  || bad "C3 triage_state_list <p> due must print only the due row (rc=$rc out=[$due])"
lim=$(triage_state_list cromford "" 1); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$lim" | jq 'length')" = 1 ] && ok || bad "C3 limit 1 must print one row (rc=$rc out=[$lim])"
: > "$T/empty.json"
triage_state_put "$T/empty.json" >/dev/null 2>&1 && bad "C3 an empty body file must be rc != 0" || ok
echo '{"project":"cromford","ticket_key":"bad key","input_hash":"x"}' > "$T/bad.json"
triage_state_put "$T/bad.json" >/dev/null 2>&1 && bad "C3 a refused row (400) must be rc != 0" || ok

# --- C4 -------------------------------------------------------------------------
for v in 'triage-state-get)' 'triage-state-list)' 'triage-state-put)'; do
  grep -qF -- "$v" "$DIR/bin/jobs-client.sh" && ok || bad "C4 bin/jobs-client.sh has no '$v' verb"
done
grep -qF 'triage-state-get <project> <key>' "$DIR/bin/jobs-client.sh" && ok || bad "C4 the usage line does not name triage-state-get"

# --- C5 -------------------------------------------------------------------------
unset -f _jobs_req
(
  export JOBS_URL="http://127.0.0.1:9" HARNESS_SECRET=s JOBS_TIMEOUT=2 JOBS_RETRIES=0 JOBS_ALERT=0
  # shellcheck source=/dev/null
  . "$DIR/bin/jobs-client.sh" || exit 3
  o1=$(triage_state_get cromford 2657); r1=$?
  o2=$(triage_state_list cromford); r2=$?
  o3=$(triage_state_put "$T/one.json"); r3=$?
  [ "$r1" = 1 ] && [ "$r2" = 1 ] && [ "$r3" = 1 ] && [ -z "$o1$o2$o3" ] || { echo "rc=$r1/$r2/$r3 out=[$o1$o2$o3]"; exit 1; }
) >"$T/c5.out" 2>&1 && ok || bad "C5 a dead worker must answer rc 1 with no stdout on every verb: $(cat "$T/c5.out")"

echo "triage-state-client: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
