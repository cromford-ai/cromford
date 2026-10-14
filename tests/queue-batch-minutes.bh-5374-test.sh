#!/bin/bash
# tests/queue-batch-minutes.bh-5374-test.sh — BH-5374: the conductor records the
# CI minutes every finished Mergify batch draft spent, one worker row per
# (draft, run), so Mission Control can show the minutes wasted on batches that
# never merged.
#
# WHAT IS PINNED.
#   §1  bmin_tick over stubs (bin/lib/mc-batch-minutes.sh sourced on its own):
#       the PUT body and the log line of a reset draft (case 1), a failed PUT
#       retried from the same key and dedup-before-read once it lands (2), an
#       unread timing (3), rate limits (4), no worker token (5), the #5368 reuse
#       seam (6), no opt-in (7), the outcome classifier's adversarial negatives
#       (9, 10, 11), a draft with a run still in progress that is recorded
#       but not marked until every run is in (9), the self-hosted jobs
#       fallback (12) and a timing that is never 0 when it is unreadable (13).
#   §2  THE WIRING (case 8, the REPRO): real bin/merge-conductor.sh ticks over a
#       reset draft. The QUEUE_MINUTES line follows the BATCH_RESET line, and
#       the same tick with the bmin_tick call removed writes none (D2).
# Run from anywhere: tests/queue-batch-minutes.bh-5374-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
NOW=$(date -u +%s)
SLUG=example-org/demo-os
LIB="$DIR/bin/lib/mc-batch-minutes.sh"

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
h40() { printf '%s' "$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1" | cut -c1-40; }

# ============================================================================
# §1. bmin_tick over stubs
# ============================================================================
U="$T/u"
mkdir -p "$U/h/bin/lib" "$U/h/config/mergify/repos" "$U/gh"
[ -f "$LIB" ] && { scratch_install_closure bin/lib/mc-batch-minutes.sh "$U/h" >/dev/null || exit 1; }
printf 'slug=%s\nqueue_mode=serial\n' "$SLUG" > "$U/h/config/mergify/repos/demo-os.conf"

# The stubs the conductor would have defined. gh_rest answers from
# $U/gh/<key>.json (absent = 404, rc 44) unless $U/gh/<key>.rc says otherwise;
# the key is the path with / as _, plus the head_sha when one is passed.
export MC_LOG="$U/merge-conductor.log" MC_ATTEMPTS="$U/attempts.txt"
mc_log() { echo "2026-10-08 00:00:00Z $*" >> "$MC_LOG"; }
mc_attempt_has() { grep -qxF "$1" "$MC_ATTEMPTS" 2>/dev/null; }
mc_attempt_put() { echo "$1" >> "$MC_ATTEMPTS"; }
mc_rest_var() {
  local _o="$1" _f="$2" _t _rc=0 _v=""
  shift 2
  command -v "$_f" >/dev/null 2>&1 || { printf -v "$_o" '%s' ""; return 75; }
  _t=$(mktemp "$U/rest.XXXXXX")
  "$_f" "$@" > "$_t" || _rc=$?
  [ "$_rc" = 0 ] && _v=$(cat "$_t")
  rm -f "$_t"; printf -v "$_o" '%s' "$_v"; return "$_rc"
}
ghkey() { local p="$2" a k; k=$(printf '%s' "$p" | tr '/' '_'); shift 2
  for a in "$@"; do case "$a" in head_sha=*) k="${k}@${a#head_sha=}" ;; esac; done; printf '%s' "$k"; }
gh_rest() {
  local k rc
  printf '%s\n' "$*" >> "$U/gh-calls.txt"
  k=$(ghkey "$@")
  rc=$(cat "$U/gh/$k.rc" 2>/dev/null || echo 0)
  [ "$rc" = 0 ] || return "$rc"
  [ -f "$U/gh/$k.json" ] || return 44
  cat "$U/gh/$k.json"
}
bres_drafts() {
  echo "$*" >> "$U/bres-calls.txt"
  [ -f "$U/bresrc" ] && return "$(cat "$U/bresrc")"
  cat "$U/drafts.tsv"
}
_jobs_req() {
  printf '%s %s %s\n' "$1" "$2" "$3" >> "$U/puts.txt"
  return "$(cat "$U/putrc" 2>/dev/null || echo 0)"
}
setting_get() { return 1; }
export HARNESS="$U/h" HARNESS_SECRET=x JOBS_URL=https://jobs.test
# shellcheck source=/dev/null
[ -r "$U/h/bin/lib/mc-batch-minutes.sh" ] && . "$U/h/bin/lib/mc-batch-minutes.sh"
tick_u() { RC=0; if command -v bmin_tick >/dev/null 2>&1; then bmin_tick "$SLUG" || RC=$?; else RC=127; fi; }

D1=7001; S1=$(h40 a)
C1=$(iso $((NOW-1200))); X1=$(iso $((NOW-600)))
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
runs() { # runs <sha> <id:status:conclusion>... — the runs list for one head
  jq -nc '{total_count:($ARGS.positional|length),workflow_runs:($ARGS.positional|map(split(":")|{id:(.[0]|tonumber),status:.[1],conclusion:.[2],name:"harness-ci"}))}' \
    --args "${@:2}" > "$U/gh/repos_${SLUG/\//_}_actions_runs@$1.json"
}
timing() { printf '%s' "$2" > "$U/gh/repos_${SLUG/\//_}_actions_runs_$1_timing.json"; }
jobs()   { printf '%s' "$2" > "$U/gh/repos_${SLUG/\//_}_actions_runs_$1_jobs.json"; }
ghrc()   { printf '%s' "$2" > "$U/gh/$1.rc"; }
reset_u() {
  scratch_rm "$U/gh"; scratch_rm "$U/bresrc"; scratch_rm "$U/putrc"; mkdir -p "$U/gh"
  : > "$MC_LOG"; : > "$MC_ATTEMPTS"; : > "$U/gh-calls.txt"; : > "$U/puts.txt"; : > "$U/bres-calls.txt"
  unset -f sr_batch_skipped_minutes
  export JOBS_URL=https://jobs.test HARNESS="$U/h"
  printf 'slug=%s\nqueue_mode=serial\n' "$SLUG" > "$U/h/config/mergify/repos/demo-os.conf"
}
one_reset() { # the case-1 world: draft D1 reset, one run 9001 of 18 billed minutes
  row "$D1" closed "$S1" "$C1" "$X1" "101,102" > "$U/drafts.tsv"
  mc_log "$SLUG BATCH_RESET draft=$D1 cause=c0ffee012345 verdict=disjoint"
  runs "$S1" 9001:completed:cancelled
  timing 9001 '{"billable":{"UBUNTU":{"total_ms":1000000,"jobs":2},"MACOS":{"total_ms":80000,"jobs":1}},"run_duration_ms":5}'
}
puts() { grep -c '^PUT /api/queue-batch-minutes ' "$U/puts.txt"; }
body() { sed -n "${1:-1}p" "$U/puts.txt" | cut -d' ' -f3-; }
field() { body "${2:-1}" | jq -r ".$1"; }
qlines() { grep -c 'QUEUE_MINUTES' "$MC_LOG"; }

# --- case 1: one reset draft, one PUT, one log line -------------------------
reset_u; one_reset; tick_u
[ "$RC" = 0 ] && [ "$(puts)" = 1 ] && ok || bad "1 one reset draft: exactly one PUT, rc 0 (rc=$RC puts=$(puts) log: $(cat "$MC_LOG"))"
B=$(body)
WANT="{\"repo\":\"$SLUG\",\"draft_pr\":$D1,\"run_id\":9001,\"outcome\":\"reset\",\"minutes\":18,\"source\":\"billable\",\"reused_min\":0,\"reused_known\":0,\"workflow\":\"harness-ci\",\"head_sha\":\"$S1\",\"closed_at\":\"$X1\"}"
[ "$(jq -c 'del(.box)' <<<"$B" 2>/dev/null)" = "$WANT" ] && ok || bad "1 the PUT body (got $B)"
grep -q "$SLUG QUEUE_MINUTES draft=$D1 outcome=reset minutes=18 reused=0$" "$MC_LOG" && ok \
  || bad "1 the log line QUEUE_MINUTES draft=$D1 outcome=reset minutes=18 reused=0 (log: $(cat "$MC_LOG"))"
[ "$(wc -l < "$U/bres-calls.txt")" = 1 ] && ok || bad "1 the drafts come from bres_drafts, once"
grep -qxF "bmin $SLUG#$D1 ${S1:0:12}:reset" "$MC_ATTEMPTS" && ok || bad "1 the draft is marked after the PUT (marks: $(cat "$MC_ATTEMPTS"))"

# --- case 2: a failed PUT is retried from the same key; then dedup-before-read
reset_u; one_reset; echo 1 > "$U/putrc"; tick_u
[ "$(puts)" = 1 ] && [ ! -s "$MC_ATTEMPTS" ] && ok || bad "2 a failed PUT leaves no mark (marks: $(cat "$MC_ATTEMPTS"))"
grep -q "QUEUE_MINUTES put-failed draft=$D1 run=9001" "$MC_LOG" && ok || bad "2 put-failed line (log: $(cat "$MC_LOG"))"
grep -q "QUEUE_MINUTES draft=$D1 outcome=" "$MC_LOG" && bad "2 no success line on a failed PUT" || ok
K1=$(field draft_pr 1)/$(field run_id 1)/$(field repo 1)
rm -f "$U/putrc"; tick_u
[ "$(puts)" = 2 ] && [ "$(field draft_pr 2)/$(field run_id 2)/$(field repo 2)" = "$K1" ] && ok \
  || bad "2 the next tick re-sends the identical (repo, draft_pr, run_id) (puts=$(puts) $K1 vs $(field draft_pr 2)/$(field run_id 2)/$(field repo 2))"
: > "$U/gh-calls.txt"; tick_u
[ "$(puts)" = 2 ] && ok || bad "2 a third tick after success sends no PUT (puts=$(puts))"
[ ! -s "$U/gh-calls.txt" ] && ok || bad "2 dedup-before-read: no runs or timing call on a marked draft (calls: $(cat "$U/gh-calls.txt"))"

# --- case 3: an unread timing — no PUT, an unread line, no mark -------------
reset_u; one_reset; ghrc "repos_${SLUG/\//_}_actions_runs_9001_timing" 1; tick_u
[ "$(puts)" = 0 ] && [ ! -s "$MC_ATTEMPTS" ] && ok || bad "3 an unread timing: no PUT, no mark (puts=$(puts))"
grep -q "QUEUE_MINUTES unread draft=$D1 run=9001 rc=1" "$MC_LOG" && ok || bad "3 the unread line (log: $(cat "$MC_LOG"))"

# --- case 4: rate limits — rc 75, nothing written ---------------------------
reset_u; one_reset; ghrc "repos_${SLUG/\//_}_actions_runs@$S1" 75; tick_u
[ "$RC" = 75 ] && [ "$(puts)" = 0 ] && [ ! -s "$MC_ATTEMPTS" ] && ok || bad "4 runs list 75: rc 75, no PUT (rc=$RC puts=$(puts))"
reset_u; one_reset; ghrc "repos_${SLUG/\//_}_actions_runs_9001_timing" 75; tick_u
[ "$RC" = 75 ] && [ "$(puts)" = 0 ] && ok || bad "4 timing 75: rc 75, no PUT (rc=$RC puts=$(puts))"
reset_u; one_reset; echo 75 > "$U/bresrc"; tick_u
[ "$RC" = 75 ] && [ "$(puts)" = 0 ] && [ ! -s "$U/gh-calls.txt" ] && ok || bad "4 bres_drafts 75: rc 75 kept, nothing read or written (rc=$RC)"

# --- case 5: no worker configured — skip line, nothing read -----------------
reset_u; one_reset; unset JOBS_URL; tick_u
grep -q "$SLUG QUEUE_MINUTES skip not-configured" "$MC_LOG" && ok || bad "5 skip not-configured line (log: $(cat "$MC_LOG"))"
[ ! -s "$U/gh-calls.txt" ] && [ ! -s "$U/bres-calls.txt" ] && [ "$(puts)" = 0 ] && ok \
  || bad "5 not configured: zero gh_rest calls, no draft read, zero PUTs"
export JOBS_URL=https://jobs.test

# --- case 6: the #5368 reuse seam -------------------------------------------
reset_u; one_reset
sr_batch_skipped_minutes() { [ "$1/$2/$3" = "$SLUG/$D1/$S1" ] && echo 7; }
tick_u
[ "$(field reused_min)" = 7 ] && [ "$(field reused_known)" = 1 ] && ok || bad "6 a reuse record: reused_min 7, reused_known 1 (body: $(body))"
grep -q "QUEUE_MINUTES draft=$D1 outcome=reset minutes=18 reused=7$" "$MC_LOG" && ok || bad "6 the log says reused=7"
reset_u; one_reset
sr_batch_skipped_minutes() { echo x; }
tick_u
[ "$(field reused_min)" = 0 ] && [ "$(field reused_known)" = 0 ] && ok || bad "6 a non-integer reuse answer: reused_known 0 (body: $(body))"

# --- case 7: no opt-in conf — zero calls ------------------------------------
reset_u; one_reset; printf 'slug=%s\n' "$SLUG" > "$U/h/config/mergify/repos/demo-os.conf"; tick_u
[ "$RC" = 0 ] && [ ! -s "$U/gh-calls.txt" ] && [ ! -s "$U/bres-calls.txt" ] && [ "$(puts)" = 0 ] && ok \
  || bad "7 not opted in: zero calls (rc=$RC)"
reset_u; one_reset; export HARNESS=""; H="" tick_u
[ ! -s "$U/bres-calls.txt" ] && [ "$(puts)" = 0 ] && ok || bad "7 no root: not opted in"
export HARNESS="$U/h"

# --- case 9: a merged draft with a failed run stays merged ------------------
reset_u
row "$D1" merged "$S1" "$C1" "$X1" "101" > "$U/drafts.tsv"
runs "$S1" 9001:completed:failure
timing 9001 '{"billable":{"UBUNTU":{"total_ms":60000}}}'
tick_u
[ "$(field outcome)" = merged ] && ok || bad "9 a merged draft with a failed run is merged, never red (body: $(body))"
# and the same draft closed, not reset: red.
reset_u
row "$D1" closed "$S1" "$C1" "$X1" "101" > "$U/drafts.tsv"
runs "$S1" 9001:completed:failure
timing 9001 '{"billable":{"UBUNTU":{"total_ms":60000}}}'
tick_u
[ "$(field outcome)" = red ] && ok || bad "9 a closed draft with a failed run is red (body: $(body))"
reset_u
row "$D1" closed "$S1" "$C1" "$X1" "101" > "$U/drafts.tsv"
runs "$S1" 9001:completed:cancelled
timing 9001 '{"billable":{"UBUNTU":{"total_ms":60000}}}'
tick_u
[ "$(field outcome)" = closed ] && ok || bad "9 a closed draft with no reset line and no failure is closed (body: $(body))"
# a run still in progress is not recorded and the draft is not marked
reset_u
row "$D1" closed "$S1" "$C1" "$X1" "101" > "$U/drafts.tsv"
runs "$S1" 9001:in_progress:
tick_u
[ "$(puts)" = 0 ] && [ ! -s "$MC_ATTEMPTS" ] && ok || bad "9 no completed run: nothing recorded, no mark"
# one run completed, a sibling still running: the completed one is recorded,
# the draft is not marked, and the next tick records the sibling once it ends
reset_u
row "$D1" closed "$S1" "$C1" "$X1" "101" > "$U/drafts.tsv"
runs "$S1" 9001:completed:failure 9002:in_progress:
timing 9001 '{"billable":{"UBUNTU":{"total_ms":60000}}}'
tick_u
[ "$RC" = 0 ] && [ "$(puts)" = 1 ] && [ "$(field run_id 1)" = 9001 ] && ok || bad "9 mixed: the completed run is PUT (rc=$RC puts=$(puts))"
[ ! -s "$MC_ATTEMPTS" ] && ok || bad "9 mixed: a run still in progress holds the mark back (marks: $(cat "$MC_ATTEMPTS"))"
grep -q "$SLUG QUEUE_MINUTES pending draft=$D1 run=9002$" "$MC_LOG" && ok || bad "9 mixed: the pending line (log: $(cat "$MC_LOG"))"
runs "$S1" 9001:completed:failure 9002:completed:cancelled
timing 9002 '{"billable":{"UBUNTU":{"total_ms":600000}}}'
tick_u
[ "$(puts)" = 3 ] && [ "$(field run_id 3)" = 9002 ] && [ "$(field minutes 3)" = 10 ] && ok \
  || bad "9 mixed: the next tick PUTs the sibling's 10 minutes (puts=$(puts) body3: $(body 3))"
grep -qxF "bmin $SLUG#$D1 ${S1:0:12}:closed" "$MC_ATTEMPTS" && ok || bad "9 mixed: marked once every run is in (marks: $(cat "$MC_ATTEMPTS"))"
tick_u
[ "$(puts)" = 3 ] && ok || bad "9 mixed: no PUT after the mark (puts=$(puts))"

# --- case 10: bisect = a strict subset of an EARLIER draft's members --------
D2=7002; S2=$(h40 b)
reset_u
{ row "$D1" closed "$S1" "$(iso $((NOW-2000)))" "$(iso $((NOW-1500)))" "1,2,3,4"
  row "$D2" closed "$S2" "$(iso $((NOW-1400)))" "$(iso $((NOW-900)))" "1,2"; } > "$U/drafts.tsv"
runs "$S1"; runs "$S2" 9002:completed:failure
timing 9002 '{"billable":{"UBUNTU":{"total_ms":60000}}}'
tick_u
[ "$(field outcome)" = bisect ] && [ "$(field draft_pr)" = "$D2" ] && ok || bad "10 {1,2} under an earlier {1,2,3,4} is bisect, even with a failed run (body: $(body))"
reset_u
{ row "$D1" closed "$S1" "$(iso $((NOW-2000)))" "$(iso $((NOW-1500)))" "1,2"
  row "$D2" closed "$S2" "$(iso $((NOW-1400)))" "$(iso $((NOW-900)))" "1,2"; } > "$U/drafts.tsv"
runs "$S1"; runs "$S2" 9002:completed:cancelled
timing 9002 '{"billable":{"UBUNTU":{"total_ms":60000}}}'
tick_u
[ "$(field outcome)" = closed ] && ok || bad "10 equal member sets are not bisect (body: $(body))"
reset_u
{ row "$D1" closed "$S1" "$(iso $((NOW-1400)))" "$(iso $((NOW-900)))" "1,2,3,4"
  row "$D2" closed "$S2" "$(iso $((NOW-2000)))" "$(iso $((NOW-1500)))" "1,2"; } > "$U/drafts.tsv"
runs "$S1"; runs "$S2" 9002:completed:cancelled
timing 9002 '{"billable":{"UBUNTU":{"total_ms":60000}}}'
tick_u
[ "$(field outcome)" = closed ] && ok || bad "10 a subset of a LATER draft is not bisect (body: $(body))"

# --- case 11: BATCH_RESET for draft=123 does not make draft 12 reset --------
reset_u
row 12 closed "$S1" "$C1" "$X1" "101" > "$U/drafts.tsv"
mc_log "$SLUG BATCH_RESET draft=123 cause=c0ffee012345 verdict=disjoint"
runs "$S1" 9001:completed:cancelled
timing 9001 '{"billable":{"UBUNTU":{"total_ms":60000}}}'
tick_u
[ "$(field outcome)" = closed ] && ok || bad "11 draft=123's reset line does not make draft 12 reset (body: $(body))"

# --- case 12: self-hosted — billable {} falls back to measured job time -----
reset_u; one_reset
timing 9001 '{"billable":{},"run_duration_ms":91000}'
jobs 9001 '{"total_count":2,"jobs":[{"started_at":"2026-10-08T00:00:00Z","completed_at":"2026-10-08T00:01:01Z"},{"started_at":"2026-10-08T00:00:00Z","completed_at":"2026-10-08T00:00:30Z"}]}'
tick_u
[ "$(field minutes)" = 3 ] && [ "$(field source)" = jobs ] && ok || bad "12 billable {} + jobs of 61 s and 30 s: minutes 3, source jobs (body: $(body))"

# --- case 13: unreadable is never 0 -----------------------------------------
reset_u; one_reset; timing 9001 '{"run_duration_ms":91000}'; tick_u
[ "$(puts)" = 0 ] && grep -q "QUEUE_MINUTES unread draft=$D1 run=9001" "$MC_LOG" && ok || bad "13 billable missing: unread, no PUT (puts=$(puts))"
reset_u; one_reset; timing 9001 '{"billable":{}}'
jobs 9001 '{"total_count":2,"jobs":[{"started_at":"2026-10-08T00:00:00Z","completed_at":"2026-10-08T00:01:01Z"},{"started_at":"2026-10-08T00:00:00Z","completed_at":null}]}'
tick_u
[ "$(puts)" = 0 ] && [ ! -s "$MC_ATTEMPTS" ] && grep -q "QUEUE_MINUTES unread draft=$D1 run=9001" "$MC_LOG" && ok \
  || bad "13 a job with no completed_at: unread, never partial (puts=$(puts) body: $(body))"
reset_u; one_reset; timing 9001 '{"billable":{"UBUNTU":{"jobs":1}}}'; tick_u
[ "$(puts)" = 0 ] && ok || bad "13 a billable entry with no total_ms: unread, never 0 (body: $(body))"

# ============================================================================
# §2. THE WIRING (case 8, the REPRO): real conductor ticks
# ============================================================================
export HARNESS="$T/h"
unset MC_LOG MC_ATTEMPTS
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/h/config/mergify/repos" "$T/fakebin" "$T/repos"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || exit 1
[ -f "$DIR/bin/lib/mc-batch-reset.sh" ] && { scratch_install_closure bin/lib/mc-batch-reset.sh "$T/h" >/dev/null || exit 1; }
[ -f "$LIB" ] && { scratch_install_closure bin/lib/mc-batch-minutes.sh "$T/h" >/dev/null || exit 1; }
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/" || exit 1
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
: > "$T/h/env/global.env"
printf 'demo-os %s - - 2 box-d\n' "$SLUG" > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
printf 'slug=%s\nqueue_mode=serial\n' "$SLUG" > "$T/h/config/mergify/repos/demo-os.conf"
for s in beat.sh deploy-request.sh pre-arm-guards.sh codegraph-ensure.sh deploy-verify.sh prod-url.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s"; chmod +x "$T/h/bin/$s"
done
printf '#!/bin/bash\nprintf "VERDICT: APPROVE\\n" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
chmod +x "$T/h/bin/agent-call.sh"
# The worker side: every PUT body lands in jobs-puts.txt.
cat > "$T/h/bin/jobs-client.sh" <<EOF
job_verdict_rebind() { return 0; }
job_ledger_put() { return 0; }
_jobs_req() { printf '%s %s %s\n' "\$1" "\$2" "\${3:-}" >> "$T/jobs-puts.txt"; return 0; }
EOF
cat > "$T/h/bin/test-impact.sh" <<'EOF'
#!/bin/bash
ch=""; while [ $# -gt 0 ]; do [ "$1" = --changed ] && ch="$2"; shift; done
printf 'tests/always-test.sh\talways\n'
while IFS= read -r f; do
  case "$f" in
    bin/foo.sh)  printf 'tests/foo-test.sh\tself\n' ;;
    bin/bar.sh)  printf 'tests/bar-test.sh\tself\n' ;;
  esac
done < "$ch"
EOF
chmod +x "$T/h/bin/test-impact.sh"

A=5001; HA=$(h40 a); CS=c0ffee0123456789abcdef0123456789abcdef01
CA=$(iso $((NOW-1200))); XA=$(iso $((NOW-600)))
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: merge\n' | base64 | tr -d '\n')
{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\nSLUG=%s\nHA=%s\n' "$T" "$MGFY_YML" "$SLUG" "$HA"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
file() { if [ -f "$1" ]; then restpr --raw 200 "$(cat "$1")"; else restpr --raw 404 '{"message":"Not Found"}'; fi; }
case "$*" in
  *"auth token"*) echo faketoken ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"api -i -X GET repos/$SLUG/actions/runs/9001/timing"*)
    restpr --raw 200 '{"billable":{"UBUNTU":{"total_ms":1080000,"jobs":3}},"run_duration_ms":1}' ;;
  *"api -i -X GET repos/$SLUG/actions/runs -f head_sha=$HA "*)
    restpr --raw 200 '{"total_count":1,"workflow_runs":[{"id":9001,"status":"completed","conclusion":"cancelled","name":"harness-ci"}]}' ;;
  *"api -i -X GET repos/$SLUG/actions/runs -f head_sha="*) restpr --raw 200 '{"total_count":0,"workflow_runs":[]}' ;;
  *"api -i -X GET repos/$SLUG/pulls "*"state=closed"*) file "$T/closed.json" ;;
  *"api -i -X GET repos/$SLUG/pulls -f"*|*"api -i -X GET repos/$SLUG/pulls?"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/commits?"*)
    case "$*" in *"page=1"*) file "$T/commits.json" ;; *) restpr --raw 200 '[]' ;; esac ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"/files"*)
    N=$(sed -n 's|.*/pulls/\([0-9]*\)/files.*|\1|p' <<<"$*")
    case "$*" in *"page=1"*) file "$T/files-$N.json" ;; *) restpr --raw 200 '[]' ;; esac ;;
  *"api -i -X GET repos/$SLUG/pulls/"*)
    N=$(sed -n 's|.*/pulls/\([0-9]*\).*|\1|p' <<<"$*"); file "$T/pr-$N.json" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf '"'"'{"error":"not found"}\\n404\\n'"'"'\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

jq -nc --argjson n "$A" --arg s "$HA" --arg c "$CA" --arg x "$XA" \
  '[{number:$n,title:"merge queue: checking #101 + #102 together on main (abc1234)",state:"closed",merged_at:null,
     created_at:$c,closed_at:$x,updated_at:$x,head:{ref:("mergify/merge-queue/"+($n|tostring)),sha:$s},base:{ref:"main"},body:"x"}]' \
  > "$T/closed.json"
jq -nc --arg s "$CS" --arg at "$(iso $((NOW-900)))" --arg p1 "$(h40 8)" --arg p2 "$(h40 c)" \
  '[{sha:$s,commit:{message:"Merge pull request #200 from example-org/ticket/bh-200\n\ny",committer:{date:$at}},parents:[{sha:$p1},{sha:$p2}]}]' \
  > "$T/commits.json"
for n in 101 102; do jq -nc --argjson n "$n" '{number:$n,head:{sha:("h"+($n|tostring))}}' > "$T/pr-$n.json"; done
jq -nc '[{filename:"bin/foo.sh"}]' > "$T/files-101.json"
jq -nc '[{filename:"docs/x.md"}]' > "$T/files-102.json"
jq -nc '[{filename:"bin/bar.sh"}]' > "$T/files-200.json"

LOG="$T/h/logs/merge-conductor.log"
CONDUCTOR="$T/h/bin/merge-conductor.sh"
tick() {
  : > "$LOG"; : > "$T/gh-calls.txt"; : > "$T/jobs-puts.txt"
  [ -d "$T/h/state/merge-conductor" ] && : > "$T/h/state/merge-conductor/attempts.txt"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=https://jobs.test MC_REPOS="$T/repos" \
    MC_RR_PATH="$T/fakebin:$PATH" MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 \
    MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MERGE_TREE=0 MC_LAND_REBASE=0 \
    bash "$CONDUCTOR" >/dev/null 2>"$T/tick.err" ); TICK_RC=$?
}
tick
RL=$(grep -n "$SLUG BATCH_RESET draft=$A " "$LOG" | head -1 | cut -d: -f1)
QL=$(grep -n "$SLUG QUEUE_MINUTES draft=$A outcome=reset minutes=18 reused=0$" "$LOG" | head -1 | cut -d: -f1)
[ -n "$RL" ] && [ -n "$QL" ] && [ "$QL" -gt "$RL" ] && ok \
  || bad "8 the conductor tick logs QUEUE_MINUTES draft=$A outcome=reset minutes=18 reused=0 after its BATCH_RESET line (rc=$TICK_RC, log: $(grep -E 'BATCH_RESET|QUEUE_MINUTES' "$LOG"); err: $(tail -3 "$T/tick.err"))"
[ "$(grep -c '^PUT /api/queue-batch-minutes ' "$T/jobs-puts.txt")" = 1 ] \
  && [ "$(grep '^PUT /api/queue-batch-minutes ' "$T/jobs-puts.txt" | cut -d' ' -f3- | jq -c '[.draft_pr,.run_id,.outcome,.minutes]')" = "[$A,9001,\"reset\",18]" ] && ok \
  || bad "8 the conductor tick PUTs one row [draft, run, reset, 18] (puts: $(cat "$T/jobs-puts.txt"))"
[ "$TICK_RC" = 0 ] && grep -q ' TICK demo-os tick=' "$LOG" && ok || bad "8 the tick ends normally (rc=$TICK_RC)"

# D2: the call site is what writes the line.
sed '/bmin_tick "\$SLUG"/d' "$T/h/bin/merge-conductor.sh" > "$T/h/bin/mc-nocall.sh"
if cmp -s "$T/h/bin/merge-conductor.sh" "$T/h/bin/mc-nocall.sh"; then
  bad "8 the conductor carries a bmin_tick \"\$SLUG\" call to remove"
else
  CONDUCTOR="$T/h/bin/mc-nocall.sh"; tick
  grep -q 'QUEUE_MINUTES' "$LOG" && bad "8 without the call no QUEUE_MINUTES line is written" || ok
  grep -q "BATCH_RESET draft=$A " "$LOG" && ok || bad "8 without the call the BATCH_RESET line is still written"
fi

# ============================================================================
# §3. The worker route and the console section, through their node suites
# ============================================================================
# This suite is the door for both, as well as their own CI jobs: the worker
# suite needs nothing installed, the console one says so and skips without deps.
ROUTE="$DIR/worker/jobs/src/routes/queue-batch-minutes.js"
WASTE="$DIR/console-ui/src/lib/queue-waste.js"
[ -f "$ROUTE" ] && grep -q '"/api/queue-batch-minutes/daily"' "$ROUTE" && ok || bad "§3 the worker route family exists"
[ -f "$WASTE" ] && ok || bad "§3 console-ui/src/lib/queue-waste.js exists"
if NOUT=$(cd "$DIR/worker/jobs" && node --test test/queue-batch-minutes.bh-5374.test.js 2>&1); then ok
else bad "§3 worker/jobs/test/queue-batch-minutes.bh-5374.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "queue-batch-minutes: console node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
elif NOUT=$(cd "$DIR/console-ui" && node --test tests/queue-waste.bh-5374.test.js 2>&1); then ok
else bad "§3 console-ui/tests/queue-waste.bh-5374.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "queue-batch-minutes.bh-5374: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
