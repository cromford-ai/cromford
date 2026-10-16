#!/bin/bash
# tests/merge-queue-reconcile.bh-5008-test.sh — BH-5670 (BH-5008 child 4): the
# hub lane bin/merge-queue-reconcile.sh, run AS SHIPPED against the REAL
# harness-jobs worker (tests/lib/registry-fixture-curl.bh-5650.mjs over a
# SQLite file) and a Mergify stub.
#
# The `curl` on $T/bin answers a Mergify URL (https://mergify.test/v1/...) from
# $T/mergify/<owner>__<name>.json with the code in $T/mergify/<owner>__<name>.code
# (200 when absent), logs its argv to $T/mergify-argv.log and its stdin config
# to $T/mergify-stdin.log, and passes every other call to the worker fixture.
#
#   1 DB `checking` + Mergify `merged` → rc 0, one row
#     `merged (reconcile: was checking)` actor reconcile, one Mergify call
#   2 no active rows → rc 0, zero Mergify calls, `idle` logged
#   3 MERGIFY_API_TOKEN unset (and malformed) → rc 0, zero calls, `not-configured`
#   4 Mergify answers 500 → rc 0, no new row, one `http=500` line, no POST
#   5 three active repos, cap 2 → two calls, `deferred=1` names the third; one
#     tick later the deferred repo is called
#   6 the token is never in any curl argv, and it does reach Mergify on stdin
#   7 the worker is down → rc 1, zero Mergify calls
#   W the node suite worker/jobs/test/merge-queue-reconcile.bh-5008.test.js
#   L the lane registry row, the cron fragment and the env template
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/merge-queue-reconcile.bh-5008-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2', wanted '$3'"; fi; }
command -v jq >/dev/null || { echo "SKIP: jq missing"; exit 0; }
command -v node >/dev/null || { echo "SKIP: node missing"; exit 0; }

LANE="$DIR/bin/merge-queue-reconcile.sh"
REG="$DIR/catalog/lanes.d/merge-queue-reconcile.json"
CRON="$DIR/cron/lanes/728-merge-queue-reconcile.cron"
ENVT="$DIR/env-templates/lanes/382-merge-queue-reconcile.env.example"
ROUTE="$DIR/worker/jobs/src/routes/merge-queue-reconcile.js"
MJS="$DIR/tests/lib/registry-fixture-curl.bh-5650.mjs"
for f in "$LANE" "$REG" "$CRON" "$ENVT" "$ROUTE"; do
  [ -f "$f" ] || { echo "FAIL: $f is missing"; echo "merge-queue-reconcile: PASS=0 FAIL=1"; exit 1; }
done

REPO=Example-Org/example-repo
TOKEN=mergify-token-fixture-1
# 2026-10-10T14:00:00Z, an even 120 s tick
NOW0=1791640800

# ── the scratch harness ─────────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/logs" "$H/flags" "$H/env" "$T/bin" "$T/mergify"
scratch_install_closure bin/merge-queue-reconcile.sh "$H" > /dev/null || bad "setup: scratch_install_closure failed"
scratch_install_closure bin/jobs-client.sh "$H" > /dev/null || bad "setup: scratch_install_closure jobs-client failed"
: > "$H/env/global.env"

cat > "$T/bin/curl" <<SH
#!/bin/bash
for a in "\$@"; do
  case "\$a" in
    https://mergify.test/*)
      printf '%s\n' "\$*" >> "$T/mergify-argv.log"
      cat >> "$T/mergify-stdin.log"
      out=""; i=0; args=("\$@")
      while [ \$i -lt \${#args[@]} ]; do
        [ "\${args[\$i]}" = -o ] && out="\${args[\$((i+1))]}"
        i=\$((i+1))
      done
      slug="\${a#https://mergify.test/v1/repos/}"; slug="\${slug%/merge-queue/status}"
      f="$T/mergify/\${slug/\//__}"
      code=200; [ -f "\$f.code" ] && code=\$(cat "\$f.code")
      if [ -f "\$f.json" ]; then cat "\$f.json" > "\${out:-/dev/stdout}"; else echo '{}' > "\${out:-/dev/stdout}"; fi
      printf '%s' "\$code"; exit 0 ;;
  esac
done
printf '%s\n' "\$*" >> "$T/jobs-argv.log"
[ ! -e "$T/fixture-down" ] || { echo "curl: (7) Failed to connect" >&2; exit 7; }
REGISTRY_FIXTURE_DB="$T/jobs.db" REGISTRY_FIXTURE_LOG="$T/jobs-calls.log" exec node --no-warnings "$MJS" "\$@"
SH
chmod +x "$T/bin/curl"

q() { REGISTRY_FIXTURE_DB="$T/jobs.db" node --no-warnings "$MJS" --query "$1"; }
q 'SELECT 1 AS one' > /dev/null 2>&1; [ $? -ne 3 ] || { echo "SKIP: node:sqlite is not available"; exit 0; }
sql() { REGISTRY_FIXTURE_DB="$T/jobs.db" node --no-warnings --input-type=module -e '
  const { DatabaseSync } = await import("node:sqlite");
  new DatabaseSync(process.env.REGISTRY_FIXTURE_DB).exec(process.argv[1]);' "$1"; }
# the worker's own clock decides the 24 h window, so a seeded row is one hour old
AT=$(date -u -d '1 hour ago' +%FT%TZ) # determinism: ok the route's 24 h window reads the real clock
fresh_db() { scratch_rm "$T/jobs.db" 2>/dev/null; rm -f "$T/jobs.db"; q 'SELECT 1' > /dev/null; }
seed_row() { sql "INSERT INTO pr_state_events (repo, number, state, since, reason, alerted, at, actor) VALUES ('$1', $2, 'queue', 'checks@$2', '$3', '-', '$AT', 'webhook')"; }
seed_batch() { sql "INSERT INTO merge_queue_batches (repo, draft_pr, members_json, started_at, updated_at) VALUES ('$1', $2, '$3', '$AT', '$AT')"; }
mergify() { printf '%s' "$2" > "$T/mergify/${1/\//__}.json"; rm -f "$T/mergify/${1/\//__}.code"; [ -z "${3:-}" ] || printf '%s' "$3" > "$T/mergify/${1/\//__}.code"; }
reset_logs() { : > "$T/mergify-argv.log"; : > "$T/mergify-stdin.log"; : > "$T/jobs-argv.log"; : > "$T/jobs-calls.log"; : > "$H/logs/merge-queue-reconcile.log"; }
mcalls() { wc -l < "$T/mergify-argv.log" | tr -d ' '; }
lastlog() { tail -n 1 "$H/logs/merge-queue-reconcile.log" | cut -d' ' -f2-; }
run_lane() {
  env -i PATH="$T/bin:$PATH" HOME="$T" HARNESS="$H" HARNESS_TEST_SANDBOX=1 \
    JOBS_URL=http://jobs.test HARNESS_SECRET=fixture-secret JOBS_RETRY_SLEEP=0 JOBS_RETRIES=0 \
    MERGIFY_API_URL=https://mergify.test/v1 MQR_NOW="${MQR_NOW:-$NOW0}" "$@" \
    bash "$H/bin/merge-queue-reconcile.sh" > "$T/lane.out" 2> "$T/lane.err"
}
merged_batch() { jq -nc --argjson n "$1" '{batches:[{status:{code:"merged"},pull_requests:[{number:$n}]}],waiting_pull_requests:[]}'; }

# ── 1 checking + Mergify merged → one corrective row ────────────────────────
fresh_db; reset_logs
seed_row "$REPO" 101 checking
seed_batch "$REPO" 9001 '[101]'
mergify "$REPO" "$(merged_batch 101)"
run_lane MERGIFY_API_TOKEN="$TOKEN"; R=$?
eq "1 rc" "$R" 0
eq "1 corrective rows" "$(q "SELECT COUNT(*) AS n FROM pr_state_events WHERE state='queue' AND number=101 AND reason='merged (reconcile: was checking)' AND actor='reconcile'" | jq '.[0].n')" 1
eq "1 queue rows" "$(q "SELECT COUNT(*) AS n FROM pr_state_events WHERE state='queue'" | jq '.[0].n')" 2
eq "1 Mergify calls" "$(mcalls)" 1
grep -q "https://mergify.test/v1/repos/$REPO/merge-queue/status" "$T/mergify-argv.log" && ok || bad "1 the Mergify URL: $(cat "$T/mergify-argv.log")"
grep -q -- "--max-time 20" "$T/mergify-argv.log" && ok || bad "1 no 20 s timeout: $(cat "$T/mergify-argv.log")"
[[ "$(lastlog)" == *"active=1 called=1 ok=1 failed=0 deferred=0 written=1"* ]] && ok || bad "1 summary: $(lastlog)"
grep -c "^POST http://jobs.test/api/merge-queue/reconcile" "$T/jobs-calls.log" | grep -qx 1 && ok || bad "1 one POST: $(cat "$T/jobs-calls.log")"

# ── 6 the token never rides argv; it reaches Mergify on stdin ───────────────
grep -qF -- "$TOKEN" "$T/mergify-argv.log" "$T/jobs-argv.log" && bad "6 the token is in a curl argv" || ok
grep -qF -- "Authorization: Bearer $TOKEN" "$T/mergify-stdin.log" && ok || bad "6 the token did not reach Mergify on stdin"
grep -qF -- "$TOKEN" "$H/logs/merge-queue-reconcile.log" && bad "6 the token is in the lane log" || ok

# ── 2 nothing active → zero Mergify calls ───────────────────────────────────
fresh_db; reset_logs
run_lane MERGIFY_API_TOKEN="$TOKEN"; R=$?
eq "2 rc" "$R" 0
eq "2 Mergify calls" "$(mcalls)" 0
[[ "$(lastlog)" == "idle active=0 mergify_calls=0" ]] && ok || bad "2 summary: $(lastlog)"
grep -q "^POST http://jobs.test/api/merge-queue/reconcile" "$T/jobs-calls.log" && bad "2 a POST was sent" || ok
# a merged PR is not active either
seed_row "$REPO" 101 merged
reset_logs
run_lane MERGIFY_API_TOKEN="$TOKEN"; R=$?
eq "2b rc" "$R" 0
eq "2b Mergify calls" "$(mcalls)" 0

# ── 3 token unset or malformed → not-configured, zero calls ─────────────────
fresh_db; reset_logs
seed_row "$REPO" 101 checking
run_lane; R=$?
eq "3 rc" "$R" 0
eq "3 Mergify calls" "$(mcalls)" 0
[[ "$(lastlog)" == "not-configured active=1" ]] && ok || bad "3 summary: $(lastlog)"
reset_logs
run_lane MERGIFY_API_TOKEN='bad"token'; R=$?
eq "3b rc" "$R" 0
eq "3b Mergify calls" "$(mcalls)" 0
[[ "$(lastlog)" == "not-configured active=1" ]] && ok || bad "3b summary: $(lastlog)"

# ── 4 Mergify 500 → no write, one log line, no POST ─────────────────────────
fresh_db; reset_logs
seed_row "$REPO" 101 checking
mergify "$REPO" '{"message":"fixture upstream error"}' 500
run_lane MERGIFY_API_TOKEN="$TOKEN"; R=$?
eq "4 rc" "$R" 0
eq "4 queue rows" "$(q "SELECT COUNT(*) AS n FROM pr_state_events WHERE state='queue'" | jq '.[0].n')" 1
eq "4 http=500 lines" "$(grep -c "$REPO mergify http=500" "$H/logs/merge-queue-reconcile.log")" 1
grep -q "^POST http://jobs.test/api/merge-queue/reconcile" "$T/jobs-calls.log" && bad "4 a POST was sent" || ok
[[ "$(lastlog)" == *"called=1 ok=0 failed=1"* ]] && ok || bad "4 summary: $(lastlog)"
# a 200 that is not a JSON object is no answer either
reset_logs
mergify "$REPO" 'not json'
run_lane MERGIFY_API_TOKEN="$TOKEN"; R=$?
eq "4b rc" "$R" 0
grep -q "^POST http://jobs.test/api/merge-queue/reconcile" "$T/jobs-calls.log" && bad "4b a POST was sent for a non-JSON answer" || ok

# ── 5 cap 2 of 3 → two calls, the third deferred by name, then called ───────
fresh_db; reset_logs
for r in Example-Org/repo-a Example-Org/repo-b Example-Org/repo-c; do
  seed_row "$r" 101 checking; mergify "$r" '{"batches":[],"waiting_pull_requests":[]}'
done
sql "INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('merge_queue_reconcile_repos','2','test','test','$AT')"
MQR_NOW=$NOW0 run_lane MERGIFY_API_TOKEN="$TOKEN"; R=$?
eq "5 rc" "$R" 0
eq "5 Mergify calls" "$(mcalls)" 2
[[ "$(lastlog)" == *"deferred=1 (Example-Org/repo-"* ]] && ok || bad "5 summary: $(lastlog)"
DEFERRED=$(lastlog | sed -n 's/.*deferred=1 (\([^)]*\)).*/\1/p')
grep -qF "/repos/$DEFERRED/" "$T/mergify-argv.log" && bad "5 the deferred repo $DEFERRED was called" || ok
reset_logs
MQR_NOW=$((NOW0 + 120)) run_lane MERGIFY_API_TOKEN="$TOKEN"; R=$?
eq "5b rc" "$R" 0
grep -qF "/repos/$DEFERRED/" "$T/mergify-argv.log" && ok || bad "5b the deferred repo '$DEFERRED' was not called next tick: $(cat "$T/mergify-argv.log")"

# ── 7 the worker is down → rc 1, zero Mergify calls ─────────────────────────
reset_logs
: > "$T/fixture-down"
run_lane MERGIFY_API_TOKEN="$TOKEN"; R=$?
rm -f "$T/fixture-down"
eq "7 rc" "$R" 1
eq "7 Mergify calls" "$(mcalls)" 0
[[ "$(lastlog)" == "jobs-unreachable"* ]] && ok || bad "7 summary: $(lastlog)"

# ── L the lane registry row, the cron fragment, the env template ────────────
eq "L registry" "$(jq -c '[.id,.scope,.script,.cadence,.boxes,.switch.name,.wired]' "$REG")" \
  '["merge-queue-reconcile","hub","bin/merge-queue-reconcile.sh","*/2 * * * *",["hub"],"lane-off-merge-queue-reconcile",true]'
eq "L no settable token or url" "$(jq -c '[.knobs[]|select(.env=="MERGIFY_API_TOKEN" or .env=="MERGIFY_API_URL")|.settable]' "$REG")" '[false,false]'
grep -qE '^\*/2 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/merge-queue-reconcile.sh ' "$CRON" && ok || bad "L cron line"
grep -q flock "$LANE" && bad "L the lane takes a lock" || ok
grep -qE '^# ?MERGIFY_API_TOKEN=$' "$ENVT" && ok || bad "L env template has no empty MERGIFY_API_TOKEN line"

# ── W the worker routes themselves ──────────────────────────────────────────
if (cd "$DIR/worker/jobs" && node --test test/merge-queue-reconcile.bh-5008.test.js) > "$T/node.out" 2>&1; then ok
else bad "W node --test worker/jobs/test/merge-queue-reconcile.bh-5008.test.js failed: $(grep -m3 '^not ok' "$T/node.out")"; fi

echo "merge-queue-reconcile: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
