#!/bin/bash
# tests/conductor-head-lag-cost.bh-6462-test.sh — BH-6462: what a merge-conductor
# worker's head-lag step costs, the call trace at a deadline kill, the per-tick
# refs pin, and a stage that is never `unknown` when the step is known.
#
# Sentry CROMFORD-HARNESS-C: a project-4 worker was killed at ~199 s, and the
# step trail said head-lag took 86 s and 91 s. The trail named the step but not
# the calls in it. "$DIR/bin/lib/call-trace.sh" now records one line per GitHub
# REST call (gh_rest) and per jobs-worker call (_jobs_req) of a bounded worker,
# and "$DIR/bin/lib/pr-snapshot-refs.sh" pins the refs once per tick
# (prs_refs_pin) so the workers' head-lag reads cost no GET.
#
#   H1  a full tick (the real bin/merge-conductor.sh), 4 same-repo PRs, a cold
#       refs cache, a gh stub that takes 3 s per refs/branches read: exactly 1
#       matching-refs read, 0 branches/ reads, no WORKER_DEADLINE
#   H2  a kill in step diff-scan with no log line: the stage is diff-scan, not
#       unknown; table: a log line wins, an empty trail is start, an old mark
#       with no stage still reads unknown
#   H3  two PRs in one tick after the pin, the cache aged past its TTL: 0
#       matching-refs and 0 branches/ reads, both tips right
#   H4  the trace round-trip through the real gh_rest and _jobs_req, the
#       negatives, and call_trace_summary over fixed files
#   H5  the ` | calls:` segment at a kill, extra.calls, the .calls lifetime
#   H6  the pin decision table through prs_branch_tip and prs_refs_pin
#   H7  the 1-day sweep of old .calls files
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/conductor-head-lag-cost.bh-6462-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
NOW=$(date +%s)
hd() { printf '%02d%038d' "$1" 0; }
UL="$T/u"; mkdir -p "$UL"

# ============================================================================
# H4 — call_trace_summary over fixed files, then the round-trip through the
# real gh_rest and _jobs_req with stub gh/curl.
# ============================================================================
CT="$DIR/bin/lib/call-trace.sh"
TAB=$'\t'
printf 'head-lag\tgh\tGET repos/o/r/branches/x\t1000\t200\nhead-lag\tjobs\tGET /api/pr-attempts\t100\t200\nhead-lag\tjobs\tGET /api/settings\t200\t200\n' > "$UL/s1"
S1=$( ( . "$CT"; call_trace_summary "$UL/s1" ) 2>&1)
[ "$S1" = 'head-lag gh=1/1.0s jobs=2/0.3s; slowest: gh GET repos/o/r/branches/x 1.0s (head-lag)' ] && ok || bad "H4 summary of a fixed file ($S1)"
printf 'start\tjobs\tGET /api/settings\t50\t200\nhead-lag\tgh\tGET repos/o/r/git/matching-refs/heads/ticket/\t2500\t200\nbroken line\nhead-lag\tgh\tGET x\tabc\t200\nstart\tjobs\tPUT /api/pr-attempts\t150\tcurl_rc=28\n' > "$UL/s2"
S2=$( ( . "$CT"; call_trace_summary "$UL/s2" ) 2>&1)
[ "$S2" = 'start jobs=2/0.2s; head-lag gh=1/2.5s; slowest: gh GET repos/o/r/git/matching-refs/heads/ticket/ 2.5s (head-lag)' ] && ok || bad "H4 steps in first-seen order, malformed lines skipped ($S2)"
: > "$UL/s3"
[ "$( ( . "$CT"; call_trace_summary "$UL/s3" ) 2>&1)" = none ] && ok || bad "H4 an empty file is none"
[ "$( ( . "$CT"; call_trace_summary "$UL/nope" ) 2>&1)" = none ] && ok || bad "H4 a missing file is none"
i=0; while [ "$i" -lt 200 ]; do printf 'step-%s\tgh\tGET repos/o/r/pulls/%s\t%s\t200\n' "$i" "$i" "$((i + 10))"; i=$((i + 1)); done > "$UL/s4"
S4=$( ( . "$CT"; call_trace_summary "$UL/s4" ) 2>&1)
[ -n "$S4" ] && [ "${#S4}" -le 300 ] && [[ "$S4" == *" +"*" more; slowest: gh GET repos/o/r/pulls/199 0.2s (step-199)" ]] && ok || bad "H4 200 steps: 300 bytes or less, +N more, the slowest named (${#S4}: $S4)"

# The stub gh: a branches/ read takes 1 s; every call is logged.
mkdir -p "$UL/bin"
cat > "$UL/bin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$UL/gh-calls"
case "\$*" in *branches/*) sleep 1 ;; esac   # determinism: ok the stub IS the slow call the trace must measure
printf 'HTTP/2.0 200 OK\r\n\r\n{"name":"x","commit":{"sha":"abc"}}\n'
EOF
chmod +x "$UL/bin/gh"
cat > "$UL/bin/curl" <<EOF
#!/bin/bash
[ -e "$UL/curl-fail" ] && exit 7
printf '{"rows":[]}\n200'
EOF
chmod +x "$UL/bin/curl"
h4() { ( unset -f gh curl; export PATH="$UL/bin:$PATH" HARNESS="$UL/h4h" GH_ETAG=0 GH_TOKEN=tok-fixture-h4; mkdir -p "$HARNESS/logs"
  unset GH_REST_LIB GH_REST_AUTH_FAIL_FILE
  . "$DIR/bin/lib/gh-rest.sh"; . "$DIR/bin/lib/jobs/req.sh"; . "$CT"
  JOBS_URL=http://worker.test HARNESS_SECRET=x-fixture JOBS_RETRIES=0 JOBS_HARNESS=""
  eval "$1" ) 2>&1; }
rm -f "$UL/trace1"
O=$(h4 'HARNESS_CALL_TRACE_FILE='"$UL"'/trace1; MC_STEP_NAME=head-lag
  gh_rest GET "repos/o/r/branches/x?per_page=1" > "$UL/out-on"; echo "rc=$?"
  _jobs_req GET "/api/pr-attempts?repo=o/r" > /dev/null; echo "jrc=$?"
  : > "$UL/curl-fail"; _jobs_req PUT /api/pr-attempts "{}" > /dev/null; echo "frc=$?"; rm -f "$UL/curl-fail"')
# Selected by content, not by position: a quota-gate settings read inside
# gh_rest is a real jobs request and is traced too.
[ "$(grep -c "${TAB}gh${TAB}" "$UL/trace1" 2>/dev/null)" = 1 ] && [ "$(grep -c "${TAB}jobs${TAB}GET /api/pr-attempts${TAB}" "$UL/trace1" 2>/dev/null)" = 1 ] \
  && [ "$(grep -c "${TAB}jobs${TAB}PUT /api/pr-attempts${TAB}" "$UL/trace1" 2>/dev/null)" = 1 ] && ok || bad "H4 each request writes one line ($O / $(cat "$UL/trace1" 2>/dev/null))"
L1=$(grep "${TAB}gh${TAB}" "$UL/trace1" 2>/dev/null)
IFS=$'\t' read -r a b c d e <<<"$L1"
[ "$a|$b|$c|$e" = "head-lag|gh|GET repos/o/r/branches/x|200" ] && [[ "$d" =~ ^[0-9]+$ ]] && [ "$d" -ge 1000 ] && ok || bad "H4 the gh line: step, kind, path without query, ms >= 1000, status 200 ($L1)"
L2=$(grep "${TAB}jobs${TAB}GET /api/pr-attempts" "$UL/trace1" 2>/dev/null)
[[ "$L2" =~ ^head-lag${TAB}jobs${TAB}GET\ /api/pr-attempts${TAB}[0-9]+${TAB}200$ ]] && ok || bad "H4 the jobs line, query cut ($L2)"
L3=$(grep "${TAB}jobs${TAB}PUT /api/pr-attempts" "$UL/trace1" 2>/dev/null)
[[ "$L3" =~ ^head-lag${TAB}jobs${TAB}PUT\ /api/pr-attempts${TAB}[0-9]+${TAB}curl_rc=7$ ]] && ok || bad "H4 a transport failure is curl_rc=7 ($L3)"
grep -qx 'frc=1' <<<"$O" && grep -qx 'jrc=0' <<<"$O" && ok || bad "H4 _jobs_req return codes unchanged ($O)"
# Off: no var, no file. Same stdout and rc as with the trace on.
O=$(h4 'unset HARNESS_CALL_TRACE_FILE; MC_STEP_NAME=head-lag; gh_rest GET "repos/o/r/branches/x?per_page=1" > "$UL/out-off"; echo "rc=$?"')
grep -qx 'rc=0' <<<"$O" && cmp -s "$UL/out-on" "$UL/out-off" && ok || bad "H4 gh_rest stdout and rc are the same with the trace off ($O)"
[ -z "$(find "$UL" -maxdepth 1 -name 'trace-off*')" ] && ok || bad "H4 setup"
rm -f "$UL/trace2"
h4 'HARNESS_CALL_TRACE_FILE='"$UL"'/trace2; unset HARNESS_CALL_TRACE_FILE; gh_rest GET repos/o/r/branches/x > /dev/null' > /dev/null
[ ! -e "$UL/trace2" ] && ok || bad "H4 the variable unset: no file"
h4 'HARNESS_CALL_TRACE_FILE='"$UL"'/trace2; ( unset EPOCHREALTIME; gh_rest GET repos/o/r/branches/x > /dev/null )' > /dev/null
[ ! -s "$UL/trace2" ] && ok || bad "H4 EPOCHREALTIME unset: no line ($(cat "$UL/trace2" 2>/dev/null))"
: > "$UL/gh-calls"
O=$(h4 'HARNESS_CALL_TRACE_FILE='"$UL"'/trace2; _gh_auth_gate() { return 1; }; gh_rest GET repos/o/r/pulls/1 > /dev/null; echo "rc=$? st=$GH_REST_STATUS"')
[ ! -s "$UL/trace2" ] && [ ! -s "$UL/gh-calls" ] && grep -qx 'rc=75 st=401' <<<"$O" && ok || bad "H4 a gate refusal: no request, no line ($O / $(cat "$UL/trace2" 2>/dev/null))"
O=$(h4 'HARNESS_CALL_TRACE_FILE='"$UL"'/trace3; unset MC_STEP_NAME; _jobs_req GET /api/settings > /dev/null; cut -f1,2 "$HARNESS_CALL_TRACE_FILE"')
[ "$O" = "start${TAB}jobs" ] && ok || bad "H4 no step set: the step is start ($O)"

# ============================================================================
# H2, H5, H7 — mc_worker_bounded and mc_fanin_outcome on the repo's own libs.
# ============================================================================
mkdir -p "$UL/hh/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$UL" > "$UL/hh/bin/lane-alert.sh"; chmod +x "$UL/hh/bin/lane-alert.sh"
# wb <case> <deadline> <log line or -> <worker body> — one bounded worker for
# PR #<n> (n from the case), then its outcome. Out: $UL/<case>/{out,log,sentry}.
wb() { local c="$1" dl="$2" ll="$3" body="$4" n="$5"
  mkdir -p "$UL/$c/state"
  ( unset -f gh; export PATH="$UL/bin:$PATH" GH_ETAG=0; unset GH_REST_LIB
    . "$DIR/bin/lib/gh-rest.sh"; . "$DIR/bin/lib/fanin.sh"
    SLUG=example-org/demo MC_STATE_DIR="$UL/$c/state" MC_TICK_ID="$c" MC_LOG="$UL/$c/mclog" MC_WORKER_DEADLINE_S="$dl" MC_FANIN_T0=0 HARNESS="$UL/hh"
    if [ "$ll" = - ]; then : > "$MC_LOG"; else printf '2026-10-13 00:00:00Z example-org/demo#%s %s\n' "$n" "$ll" > "$MC_LOG"; fi
    mc_handoff_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    mc_log() { printf '%s\n' "$*" >> "$UL/$c/log"; }
    mc_attempt_has() { return 1; }; mc_attempt_put() { :; }; mc_row_field() { echo READY; }
    sentry_report() { printf '%s\n' "$@" > "$UL/$c/sentry"; }
    eval "pr_worker() { $body; }"
    mc_worker_bounded "$n"$'\t'"x"$'\t'"$(hd "$n")"; echo "rc=$?"
    m=$(_mc_deadline_mark "example-org/demo#$n")
    [ -e "$m.calls" ] && echo "calls-before=y" || echo "calls-before=n"
    echo "word=$(mc_fanin_outcome 0 "$n"$'\t'"x"$'\t'"$(hd "$n")"$'\t'"b"$'\t'"false"$'\t'"CLEAN")"
    [ -e "$m.calls" ] && echo "calls-after=y" || echo "calls-after=n"
    ls "$MC_STATE_DIR/worker-deadline" 2>/dev/null | sed 's/^/left=/'
  ) > "$UL/$c/out" 2>&1; }

# H2 — a kill in diff-scan with no log line: the stage is the step.
wb h2 2 - 'mc_step diff-scan; sleep 30' 61   # determinism: ok the stub worker IS the stall the deadline kills
DL=$(grep 'WORKER_DEADLINE' "$UL/h2/log" 2>/dev/null)
grep -q 'at stage: diff-scan | step: diff-scan (' <<<"$DL" && ok || bad "H2 the stage is diff-scan ($DL)"
! grep -q 'stage: unknown' <<<"$DL" && ok || bad "H2 no stage: unknown ($DL)"
[ "$(sed -n 5p "$UL/h2/sentry" 2>/dev/null | jq -r '.stage' 2>/dev/null)" = diff-scan ] && ok || bad "H2 extra.stage is diff-scan ($(sed -n 5p "$UL/h2/sentry" 2>/dev/null))"
# H2 table: a log line for the PR wins; an empty trail is start.
wb h2b 2 'merge deferred — budget' 'mc_step diff-scan; sleep 30' 62   # determinism: ok the stub worker IS the stall the deadline kills
grep -q 'at stage: 2026-10-13 00:00:00Z example-org/demo#62 merge deferred — budget | step: diff-scan (' "$UL/h2b/log" 2>/dev/null && ok || bad "H2 a log line for the PR is the stage ($(cat "$UL/h2b/log" 2>/dev/null))"
wb h2c 2 - ': > "$MC_STEP_FILE"; sleep 30' 63   # determinism: ok the stub worker IS the stall the deadline kills
grep -q 'at stage: start | step: start (' "$UL/h2c/log" 2>/dev/null && ok || bad "H2 an empty trail: stage start ($(cat "$UL/h2c/log" 2>/dev/null))"
# An old mark with no stage field (written before BH-6346): still unknown.
# Its step is unknown too: BH-6351 reads a mark with no step field as step
# `unknown` (its S4 pins the Sentry tag), so the line says the same.
mkdir -p "$UL/h2d/state/worker-deadline"
( . "$DIR/bin/lib/fanin.sh"
  SLUG=example-org/demo MC_STATE_DIR="$UL/h2d/state" MC_TICK_ID=h2d HARNESS="$UL/hh"
  mc_handoff_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
  mc_log() { printf '%s\n' "$*" >> "$UL/h2d/log"; }
  mc_attempt_has() { return 1; }; mc_attempt_put() { :; }; sentry_report() { :; }
  printf '2\t\n' > "$(_mc_deadline_mark "example-org/demo#64")"
  mc_fanin_outcome 0 "64"$'\t'"x"$'\t'"$(hd 64)"$'\t'"b"$'\t'"false"$'\t'"CLEAN" ) > /dev/null 2>&1
grep -q 'at stage: unknown | step: unknown' "$UL/h2d/log" 2>/dev/null && ok || bad "H2 an old mark with no stage reads unknown ($(cat "$UL/h2d/log" 2>/dev/null))"

# H5 — the calls segment at a kill.
: > "$UL/alerts"
wb h5 3 - 'mc_step head-lag; gh_rest GET "repos/o/r/branches/x?per_page=1" > /dev/null; sleep 30' 71   # determinism: ok the stub worker IS the stall the deadline kills
DL=$(grep 'WORKER_DEADLINE' "$UL/h5/log" 2>/dev/null)
[[ "$DL" =~ \|\ calls:\ head-lag\ gh=1/[0-9]+\.[0-9]s\;\ slowest:\ gh\ GET\ repos/o/r/branches/x\ [0-9]+\.[0-9]s\ \(head-lag\)$ ]] && ok || bad "H5 the WORKER_DEADLINE line ends with the calls segment ($DL)"
[ "$(grep -c 'WORKER_DEADLINE example-org/demo#71' "$UL/alerts")" = 1 ] && grep -q '| calls: head-lag gh=1/' "$UL/alerts" && ok || bad "H5 one lane alert with the calls segment ($(cat "$UL/alerts"))"
grep -qx 'word=killed:deadline' "$UL/h5/out" && ok || bad "H5 the outcome is exactly killed:deadline ($(cat "$UL/h5/out"))"
[ "$(sed -n 1,3p "$UL/h5/sentry" 2>/dev/null | tr '\n' ' ')" = 'warning merge-conductor conductor-worker-deadline ' ] && ok || bad "H5 the Sentry fingerprint args are unchanged ($(sed -n 1,3p "$UL/h5/sentry" 2>/dev/null))"
[[ "$(sed -n 5p "$UL/h5/sentry" 2>/dev/null | jq -r '.calls' 2>/dev/null)" == "head-lag gh=1/"* ]] && ok || bad "H5 extra.calls starts head-lag gh=1/ ($(sed -n 5p "$UL/h5/sentry" 2>/dev/null))"
grep -qx 'calls-before=y' "$UL/h5/out" && grep -qx 'calls-after=n' "$UL/h5/out" && ok || bad "H5 a kill keeps <mark>.calls for the outcome, which removes it ($(cat "$UL/h5/out"))"
! grep -q '^left=' "$UL/h5/out" && ok || bad "H5 nothing left under worker-deadline/ ($(grep '^left=' "$UL/h5/out"))"
wb h5b 30 - 'mc_step head-lag; gh_rest GET repos/o/r/pulls/9 > /dev/null' 72
grep -qx 'rc=0' "$UL/h5b/out" && grep -qx 'calls-before=n' "$UL/h5b/out" && ! grep -q '^left=' "$UL/h5b/out" && ok || bad "H5 a normal return leaves no <mark>.calls ($(cat "$UL/h5b/out"))"
wb h5c 0 - 'mc_step head-lag; gh_rest GET repos/o/r/pulls/9 > /dev/null' 73
grep -qx 'calls-before=n' "$UL/h5c/out" && ! grep -q '^left=' "$UL/h5c/out" && ok || bad "H5 no deadline: a normal return leaves no <mark>.calls ($(cat "$UL/h5c/out"))"

# H7 — the sweep: a 2-day-old .calls goes, a 1-minute-old one stays.
mkdir -p "$UL/h7/state/worker-deadline"
: > "$UL/h7/state/worker-deadline/old.t1.calls"; touch -d "@$((NOW - 172800))" "$UL/h7/state/worker-deadline/old.t1.calls"
: > "$UL/h7/state/worker-deadline/new.t1.calls"; touch -d "@$((NOW - 60))" "$UL/h7/state/worker-deadline/new.t1.calls"
wb h7 0 - ':' 74
[ "$(grep '^left=' "$UL/h7/out" | tr '\n' ' ')" = 'left=new.t1.calls ' ] && ok || bad "H7 the old .calls swept, the fresh one kept ($(grep '^left=' "$UL/h7/out" | tr '\n' ' '))"

# ============================================================================
# H3, H6 — the refs pin, on the real merge-conductor-lib in fresh processes
# (the drv scaffold of tests/mc-branch-refs.bh-4656-test.sh).
# ============================================================================
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
L="$T/lib"; mkdir -p "$L"
( export HARNESS="$L/h"; fx_mc_harness "$DIR" "$L" ) || exit 1
scratch_install_closure bin/lib/merge-conductor-lib.sh "$L/h" >/dev/null || { echo "FAIL: closure install failed for bin/lib/merge-conductor-lib.sh"; exit 1; }
[ -f "$L/h/bin/lib/pr-snapshot-refs.sh" ] || { echo "FAIL: closure did not install $DIR/bin/lib/pr-snapshot-refs.sh"; exit 1; }
mkdir -p "$L/log" "$L/tmp" "$L/pin"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$L/h/fleet.conf"
printf '#!/bin/bash\nprintf '"'"'{"error":"not found"}\\n404\\n'"'"'\n' > "$L/fakebin/curl"; chmod +x "$L/fakebin/curl"
cat > "$L/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GHT/log/gh"
p=""; prev=""
for a in "$@"; do [ "$prev" = GET ] && p="$a"; prev="$a"; done
case "$*" in
  *"auth token"*) echo faketoken; exit 0 ;;
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
esac
case "$p" in
  repos/example-org/demo-os/git/matching-refs/heads/*)
    st=$(cat "$GHT/refs-status" 2>/dev/null || echo 200)
    if [ "$st" = 200 ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$GHT/refs.json"
    else printf 'HTTP/2 %s\r\n\r\n{"message":"nope"}\n' "$st"; fi ;;
  repos/example-org/demo-os/branches/*)
    br="${p#repos/example-org/demo-os/branches/}"
    if [ -f "$GHT/br/${br##*/}" ]; then
      printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg n "$br" --arg s "$(cat "$GHT/br/${br##*/}")" '{name:$n, commit:{sha:$s}}'
    else printf 'HTTP/2 404\r\n\r\n{"message":"Branch not found"}\n'; fi ;;
  *) printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n' ;;
esac
exit 0
EOF
chmod +x "$L/fakebin/gh"
D="$L/h/state/pr-snapshot/example-org_demo-os"
PIN="$L/pin/t0.refspin-"
sha() { printf "$1%.0s" {1..40}; }
# open <branch>... — the snapshot's open list, PR n on the n-th branch.
open() { mkdir -p "$D"; printf '%s\n' "$@" | jq -Rsc '[split("\n")[] | select(length > 0)] | to_entries
  | map({number: (.key + 1), head: {ref: .value, sha: (((.key + 1) | tostring) * 40)}, base: {ref: "main"}})' > "$D/open.json"; }
refs() { printf '%s\n' "$@" | jq -Rsc '[split("\n")[] | select(length > 0) | split("=")
    | {ref: ("refs/heads/" + .[0]), object: {sha: .[1], type: "commit"}}]' > "$L/refs.json"; }
pinf() { printf '%s\n' "$@" | jq -Rsc '[split("\n")[] | select(length > 0) | split("=") | {ref: .[0], sha: .[1]}]'; }
reset() { scratch_rm "$L/h/state"; scratch_rm "$L/br"; scratch_rm "$L/pin"; mkdir -p "$L/h/state" "$L/br" "$L/pin"
  rm -f "$L/refs-status" "$L/drv.out"; : > "$L/log/gh"; }
cat > "$L/drv.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/merge-conductor-lib.sh" || exit 99
mc_init
eval "$1"
EOF
TICKN=0
drv() { TICKN=$((TICKN + 1)); ( unset -f gh; unset PR_SNAPSHOT_TTL_S PR_SNAPSHOT_LIB PR_SNAPSHOT_REFS_LIB PRS_COUNT_FILE
  export HARNESS="$L/h" PATH="$L/fakebin:$PATH" GHT="$L" TMPDIR="$L/tmp" LANE_GATE_DISABLE=1 GH_ETAG=0 HARNESS_SECRET=x \
    PR_SNAPSHOT="${PR_SNAPSHOT:-1}" PR_SNAPSHOT_TTL_S=60 MC_HEAD_LAG_MINS=10 FLEET_CONF="$L/h/fleet.conf" MC_TICK_ID="t$TICKN" PIN
  bash "$L/drv.sh" "$1" ) > "$L/drv.out" 2>&1; }
n_refs() { grep -cE "GET repos/example-org/demo-os/git/matching-refs/heads/${1:-}" "$L/log/gh"; }
n_br() { grep -cE "GET repos/example-org/demo-os/branches/${1:-}" "$L/log/gh"; }
export PIN

# H3 — two PRs, one tick, after the pin: no fetch at all.
reset; open ticket/bh-1 ticket/bh-2; refs "ticket/bh-1=$(sha 1)" "ticket/bh-2=$(sha 2)"
drv 'prs_refs_pin example-org/demo-os "$PIN" ticket/bh-1 ticket/bh-2; echo "PIN_RC=$?"'
[ "$(n_refs ticket/)" = 1 ] && ok || bad "H3 the pin makes 1 matching-refs read ($(n_refs ticket/); $(cat "$L/drv.out"))"
touch -d "@$((NOW - 600))" "$D/refs-ticket.json" 2>/dev/null
: > "$L/log/gh"
for n in 1 2; do
  drv 'MC_REFS_PIN_PREFIX="$PIN" head_lag_tip example-org/demo-os ticket/bh-'"$n"' "$TMPDIR/tip" "$(printf "'"$n"'%.0s" {1..40})"; echo "RC=$? TIP=$(cat "$TMPDIR/tip")"'
  grep -qx "RC=0 TIP=$(sha "$n")" "$L/drv.out" && ok || bad "H3 PR $n's tip from the pin ($(cat "$L/drv.out"))"
done
[ "$(n_refs)" = 0 ] && [ "$(n_br)" = 0 ] && ok || bad "H3 0 matching-refs and 0 branches/ reads after the pin (refs=$(n_refs) br=$(n_br))"

# H6 — the pin decision table.
PF="$L/pin/t0.refspin-example-org_demo-os-ticket.json"
# (a) the var set, the pin has the branch, the cache past its TTL: the pin, 0 GETs.
reset; open ticket/bh-1; refs "ticket/bh-1=$(sha 1)"; pinf "ticket/bh-1=$(sha e)" > "$PF"
drv 'PRS_REFS_PIN_PREFIX="$PIN" prs_branch_tip example-org/demo-os ticket/bh-1; echo "RC=$?"'
[ "$(head -1 "$L/drv.out")" = "$(sha e)" ] && [ "$(n_refs)" = 0 ] && ok || bad "H6a the pinned sha, 0 GETs ($(cat "$L/drv.out"); refs=$(n_refs))"
# (a2) the same with an old pin file: the pin has no TTL.
touch -d "@$((NOW - 3600))" "$PF"
drv 'PRS_REFS_PIN_PREFIX="$PIN" prs_branch_tip example-org/demo-os ticket/bh-1; echo "RC=$?"'
[ "$(head -1 "$L/drv.out")" = "$(sha e)" ] && [ "$(n_refs)" = 0 ] && ok || bad "H6a2 an hour-old pin still answers ($(cat "$L/drv.out"); refs=$(n_refs))"
# (b) the pin is an array without the branch: today's path.
reset; open ticket/bh-1; refs "ticket/bh-1=$(sha 1)"; pinf "ticket/bh-9=$(sha e)" > "$PF"
drv 'PRS_REFS_PIN_PREFIX="$PIN" prs_branch_tip example-org/demo-os ticket/bh-1; echo "RC=$?"'
[ "$(head -1 "$L/drv.out")" = "$(sha 1)" ] && [ "$(n_refs)" = 1 ] && ok || bad "H6b a pin without the branch: 1 GET ($(cat "$L/drv.out"); refs=$(n_refs))"
# (c) the pin is not JSON: today's path.
reset; open ticket/bh-1; refs "ticket/bh-1=$(sha 1)"; echo 'not json' > "$PF"
drv 'PRS_REFS_PIN_PREFIX="$PIN" prs_branch_tip example-org/demo-os ticket/bh-1; echo "RC=$?"'
[ "$(head -1 "$L/drv.out")" = "$(sha 1)" ] && [ "$(n_refs)" = 1 ] && ok || bad "H6c a pin that is not JSON: 1 GET ($(cat "$L/drv.out"); refs=$(n_refs))"
# (c2) the pin is a JSON object, not an array: today's path.
reset; open ticket/bh-1; refs "ticket/bh-1=$(sha 1)"; echo '{"ref":"ticket/bh-1","sha":"'"$(sha e)"'"}' > "$PF"
drv 'PRS_REFS_PIN_PREFIX="$PIN" prs_branch_tip example-org/demo-os ticket/bh-1; echo "RC=$?"'
[ "$(head -1 "$L/drv.out")" = "$(sha 1)" ] && [ "$(n_refs)" = 1 ] && ok || bad "H6c2 a pin that is an object: 1 GET ($(cat "$L/drv.out"); refs=$(n_refs))"
# (d) the var unset, a pin file on disk: today's path.
reset; open ticket/bh-1; refs "ticket/bh-1=$(sha 1)"; pinf "ticket/bh-1=$(sha e)" > "$PF"
drv 'unset PRS_REFS_PIN_PREFIX MC_REFS_PIN_PREFIX; prs_branch_tip example-org/demo-os ticket/bh-1; echo "RC=$?"'
[ "$(head -1 "$L/drv.out")" = "$(sha 1)" ] && [ "$(n_refs)" = 1 ] && ok || bad "H6d the var unset: 1 GET, the live sha ($(cat "$L/drv.out"); refs=$(n_refs))"
# (d2) head_lag_tip without MC_REFS_PIN_PREFIX does not read a pin on disk.
reset; open ticket/bh-1; refs "ticket/bh-1=$(sha 1)"; pinf "ticket/bh-1=$(sha e)" > "$PF"
drv 'unset MC_REFS_PIN_PREFIX; head_lag_tip example-org/demo-os ticket/bh-1 "$TMPDIR/tip"; echo "TIP=$(cat "$TMPDIR/tip")"'
grep -qx "TIP=$(sha 1)" "$L/drv.out" && [ "$(n_refs)" = 1 ] && ok || bad "H6d2 head_lag_tip with no pin var: today's read ($(cat "$L/drv.out"))"
# (e) PR_SNAPSHOT=0: no pin file, 0 GETs.
reset; open ticket/bh-1; refs "ticket/bh-1=$(sha 1)"
PR_SNAPSHOT=0 drv 'prs_refs_pin example-org/demo-os "$PIN" ticket/bh-1; echo "RC=$?"'
grep -qx 'RC=0' "$L/drv.out" && [ "$(n_refs)" = 0 ] && [ -z "$(ls "$L/pin")" ] && ok || bad "H6e PR_SNAPSHOT=0: rc 0, 0 GETs, no pin ($(cat "$L/drv.out"); refs=$(n_refs); $(ls "$L/pin"))"
# (f) a refs read that answers 500: no pin file.
reset; open ticket/bh-1; refs "ticket/bh-1=$(sha 1)"; echo 500 > "$L/refs-status"
drv 'prs_refs_pin example-org/demo-os "$PIN" ticket/bh-1; echo "RC=$?"'
grep -qx 'RC=0' "$L/drv.out" && [ "$(n_refs)" = 1 ] && [ -z "$(ls "$L/pin")" ] && ok || bad "H6f a 500: rc 0, no pin ($(cat "$L/drv.out"); $(ls "$L/pin"))"
# (f2) the same 500 with a refs cache past its TTL on disk: that old cache is not pinned.
pinf "ticket/bh-1=$(sha e)" > "$D/refs-ticket.json"; touch -d "@$((NOW - 600))" "$D/refs-ticket.json"
drv 'prs_refs_pin example-org/demo-os "$PIN" ticket/bh-1; echo "RC=$?"'
grep -qx 'RC=0' "$L/drv.out" && [ -z "$(ls "$L/pin")" ] && ok || bad "H6f2 a 500 over a stale cache: no pin ($(cat "$L/drv.out"); $(ls "$L/pin"))"
# (g) 3 branches of 2 prefixes: 2 GETs, 2 pin files.
reset; open ticket/bh-1 ticket/bh-2 fix/x; refs "ticket/bh-1=$(sha 1)" "ticket/bh-2=$(sha 2)" "fix/x=$(sha 3)"
drv 'prs_refs_pin example-org/demo-os "$PIN" ticket/bh-1 fix/x ticket/bh-2; echo "RC=$?"'
[ "$(n_refs ticket/)" = 1 ] && [ "$(n_refs fix/)" = 1 ] && ok || bad "H6g one GET per prefix (ticket=$(n_refs ticket/) fix=$(n_refs fix/))"
[ "$(ls "$L/pin" | sort | tr '\n' ' ')" = 't0.refspin-example-org_demo-os-fix.json t0.refspin-example-org_demo-os-ticket.json ' ] && ok || bad "H6g two pin files ($(ls "$L/pin" | tr '\n' ' '))"
[ "$(jq -r '.[] | select(.ref == "ticket/bh-2") | .sha' "$PF" 2>/dev/null)" = "$(sha 2)" ] && ok || bad "H6g the pin is the refs cache's {ref, sha} array ($(cat "$PF" 2>/dev/null))"
# (h) a branch without `/`: skipped, 0 GETs.
reset; open ticket/bh-1; refs "ticket/bh-1=$(sha 1)"
drv 'prs_refs_pin example-org/demo-os "$PIN" main; echo "RC=$?"'
grep -qx 'RC=0' "$L/drv.out" && [ "$(n_refs)" = 0 ] && [ -z "$(ls "$L/pin")" ] && ok || bad "H6h a branch without /: 0 GETs, no pin ($(cat "$L/drv.out"))"

# ============================================================================
# H1 — one full tick of the real conductor: the head-lag call budget.
# ============================================================================
SLUG=example-org/demo
U="https://github.com/$SLUG/pull"
PRS="1 2 3 4"
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
F="$T/f"
mkdir -p "$F/h/logs" "$F/h/state/merge-conductor" "$F/h/flags" "$F/h/locks" "$F/h/builds" "$F/h/env" "$F/h/tmp" "$F/fakebin"
for s in bin/merge-conductor.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$F/h" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
[ -f "$F/h/bin/lib/call-trace.sh" ] || bad "H1 the conductor's closure installs $DIR/bin/lib/call-trace.sh"
scratch_rm "$F/h/bin/lib/gh-limit-logger.sh"
mkdir -p "$F/h/catalog" && cp "$DIR/catalog/lead-protected-paths.seed.tsv" "$F/h/catalog/" || exit 1
printf 'demo %s - - 2 box-m\n' "$SLUG" > "$F/h/fleet.conf"
: > "$F/h/env/global.env"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$F/h/bin/$s.sh"; chmod +x "$F/h/bin/$s.sh"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/c-alerts.txt"\nexit 0\n' "$F" > "$F/h/bin/lane-alert.sh"; chmod +x "$F/h/bin/lane-alert.sh"
for n in $PRS; do
  REC="$F/h/builds/pool-demo-BH-$n-202610130001"; mkdir -p "$REC"
  echo "PR_CREATED $U/$n" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  hd "$n" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
done
cp "$DIR/tests/lib/rest-emit.sh" "$F/fakebin/restpr"; chmod +x "$F/fakebin/restpr"
for n in $PRS; do jq -nc --arg s "$SLUG" --argjson n "$n" --arg h "$(hd "$n")" '{number:$n, html_url:("https://github.com/"+$s+"/pull/"+($n|tostring)),
  title:"t", body:"", draft:false, state:"open", merged_at:null, labels:[], user:{login:"operator",type:"User"},
  updated_at:"2026-10-13T00:00:00Z", head:{ref:("ticket/bh-"+($n|tostring)), sha:$h, repo:{full_name:$s}},
  base:{ref:"main", repo:{full_name:$s}}, mergeable_state:"clean", mergeable:true}'; done | jq -sc . > "$F/open.json"
for n in $PRS; do printf '{"ref":"refs/heads/ticket/bh-%s","object":{"sha":"%s","type":"commit"}}\n' "$n" "$(hd "$n")"; done | jq -sc . > "$F/refs.json"
# The gh stub. Every call is logged. A matching-refs or branches/ read takes
# 3 s, so workers that start together all reach a cold cache.
cat > "$F/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$F/c-calls.txt"
A="\$*"
N=\$(grep -oE '(pulls|issues)/[0-9]+' <<<"\$A" | head -1 | grep -oE '[0-9]+\$')
HEADN=\$(printf '%02d%038d' "\${N:-0}" 0)
case "\$A" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"git/matching-refs/heads/"*) sleep 3; restpr --raw 200 "\$(cat "$F/refs.json")" ;;   # determinism: ok the slow GitHub read the pin saves
  *"api -i -X GET repos/$SLUG/branches/"*) sleep 3; restpr --raw 200 '{"name":"x","commit":{"sha":"'"\$HEADN"'"}}' ;;   # determinism: ok the slow GitHub read the pin saves
  *"api -i -X GET repos/$SLUG/pulls -f state=open"*) restpr --raw 200 "\$(cat "$F/open.json")" ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"-X POST"*|*"-X DELETE"*|*"-X PATCH"*|*"-X PUT"*|*"pr close"*|*"pr edit"*|*"issue close"*|*"pr merge"*) printf '%s\n' "\$A" >> "$F/c-writes.txt" ;;
  *"api -i -X GET repos/$SLUG/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"v3.diff"*) restpr --diff ;;
  *"api --paginate repos/"*"/comments"*) echo '[]' ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"api repos/$SLUG/issues/"*) printf '{"number":%s,"state":"open","labels":[],"body":""}\n' "\$N" ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*) restpr OPEN "\$HEADN" "ticket/bh-\$N" main "" MERGEABLE CLEAN operator "" "" ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
esac
exit 0
EOF
chmod +x "$F/fakebin/gh"
cat > "$F/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$URL" in *"/api/lead-protected-paths"*) "$(dirname "$0")/lpp-answer" "$M" "$URL"; exit 0 ;; esac
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$F/fakebin/curl"
# BH-4148: the lead reads protected paths from the jobs route. demo-os has no
# rows, so it is not governed, as it was under the old catalog file.
. "$DIR/tests/lib/lpp-stub.sh" || exit 1
lpp_set "$F/lpp.json" example-org/demo-os
lpp_install "$F/fakebin" "$F/lpp.json" "$F/lpp-down"
touch "$F/h/flags/merge-conductor-actions" "$F/h/flags/merge-conductor-merge" "$F/h/flags/conductor-owns-merges"
for n in $PRS; do printf '%s\t%s\t%s\t%s\t%s\t-\t-\t%s/%s\n' "$SLUG#$n" READY $((NOW-600)) "$(hd "$n")" "$(hd "$n")" "$U" "$n"; done > "$F/h/state/merge-conductor/pr-state.tsv"
: > "$F/c-calls.txt"
( unset -f gh; cd "$F" && env PATH="$F/fakebin:$PATH" HARNESS="$F/h" FLEET_CONF="$F/h/fleet.conf" HARNESS_SECRET=x JOBS_URL=http://worker.test \
  GH_TOKEN=pat-fixture-default HARNESS_PR_AUTHORS=operator \
  PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=60 MC_HEAD_LAG_MINS=10 MC_WORKER_DEADLINE_S=120 \
  MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_PREQUEUE_GATE=0 \
  bash "$F/h/bin/merge-conductor.sh" > "$F/mc.out" 2>&1 )
CLOG="$F/h/logs/merge-conductor.log"
NR=$(grep -c "GET repos/$SLUG/git/matching-refs/heads/ticket/" "$F/c-calls.txt")
NB=$(grep -c "GET repos/$SLUG/branches/" "$F/c-calls.txt")
echo "H1: matching-refs reads in the tick: $NR, branches/ reads: $NB"
grep -qE "FANIN merge-conductor $SLUG: enumerated 4 accounted 4" "$CLOG" 2>/dev/null && ok || bad "H1 setup: the tick worked 4 PRs ($(grep FANIN "$CLOG" 2>/dev/null; tail -3 "$F/mc.out"))"
[ "$NR" = 1 ] && ok || bad "H1 exactly 1 matching-refs read in the tick (got $NR)"
[ "$NB" = 0 ] && ok || bad "H1 0 branches/ reads (got $NB)"
! grep -q 'WORKER_DEADLINE' "$CLOG" 2>/dev/null && ok || bad "H1 no WORKER_DEADLINE ($(grep WORKER_DEADLINE "$CLOG"))"
[ -z "$(find "$F/h/state/merge-conductor/worker-deadline" -name '*.calls' 2>/dev/null)" ] && ok || bad "H1 no .calls file left after a clean tick"

[ -n "${KEEP:-}" ] && cp -r "$T" "$KEEP"
echo "conductor-head-lag-cost.bh-6462: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
