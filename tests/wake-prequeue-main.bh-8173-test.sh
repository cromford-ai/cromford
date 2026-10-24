#!/bin/bash
# tests/wake-prequeue-main.bh-8173-test.sh — BH-8173: a finished pre-queue gate
# run wakes the READY PRs that wait on its main sha.
#
# WHY. prequeue-gate.yml is dispatched with --ref main, so the check_run of a
# gate run carries the MAIN sha. The wake consumers looked that sha up with
# wck_sha_prs (GET commits/<sha>/pulls), found no open PR and dropped the wake:
# every READY PR held prequeue-pending on that main waited for the hourly full
# tick. bin/lib/wake-prequeue-keys.sh maps the sha through the conductor's own
# pre-queue cache to the PRs pending on it whose run completed.
#
# LIB (L1-L9). Sources bin/lib/wake-prequeue-keys.sh with a gh_rest_var stub.
# WAKE-LOOP (W1-W7). The REAL bin/wake-loop.sh as the hub on
#   tests/lib/wake-claim-stub.sh, the conductor a recorder (the
#   conductor-events.bh-5521 shape). gh is a stub; an unknown path is logged to
#   calls/gh-unknown and fails.
# MERGE-CONDUCTOR-WAKE (C1-C5). The REAL bin/merge-conductor-wake.sh over the
#   REAL jobs worker fake (tests/lib/mc-wake-worker.bh-6975.mjs) and the REAL
#   kw_conductor (the mc-wake-consumer.bh-6975 shape).
# END TO END (E2E1). The wake-loop drain records the MC_ONLY_PR it launched;
#   then ONE keyed tick of the WHOLE bin/merge-conductor.sh runs with it, on the
#   conductor-queue-on-prequeue.bh-6924 fixture shape, and both PRs enqueue.
#
# Zero network calls: every GitHub read is a local stub.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/wake-prequeue-main.bh-8173-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq git flock setsid node curl; do
  command -v "$c" >/dev/null 2>&1 || { echo "SKIP: $c missing"; exit 0; }
done
LIB="$DIR/bin/lib/wake-prequeue-keys.sh"   # impact: bin/lib/wake-prequeue-keys.sh bin/wake-loop.sh bin/merge-conductor-wake.sh

hex40() { printf '%040d' 0 | tr 0 "$1"; }
X=$(hex40 a)       # main X
Y=$(hex40 b)       # main Y
H7=$(hex40 7); H7OLD=$(hex40 6); H9=$(hex40 9); H11=$(hex40 1); H13=$(hex40 3); H15=$(hex40 5)
H17=$(hex40 c); H19=$(hex40 d)
title() { printf 'prequeue pr=%s head=%s main=%s' "$1" "$2" "$3"; }
# pend <statedir> <slug> <num> <head> <main> [state] [fp] — one cache entry.
pend() {
  local f="$1/prequeue/${2//\//_}_$3_$4_$5${7:+_$7}"
  mkdir -p "$1/prequeue"; printf '%s 1792000000 - \n' "${6:-pending}" > "$f"
}
# runs_json <title|status> ... — a workflow_runs list body.
runs_json() {
  local a i=100 t st
  a=$(for e in "$@"; do i=$((i+1)); t="${e%|*}"; st="${e##*|}"
        jq -nc --argjson id "$i" --arg t "$t" --arg st "$st" \
          '{id:$id, display_title:$t, status:$st, conclusion:(if $st == "completed" then "success" else null end)}'; done)
  jq -sc '{workflow_runs: .}' <<<"$a"
}

# ════════════════════════════════════════════════════════════════════════════
# LIB
# ════════════════════════════════════════════════════════════════════════════
LS="$T/lib/state"
LIBCALLS="$T/lib/calls"; LIBBODY="$T/lib/body"; LIBRC="$T/lib/rc"
lib_reset() { scratch_rm "$T/lib"; mkdir -p "$LS"; : > "$LIBCALLS"; echo '{"workflow_runs":[]}' > "$LIBBODY"; echo 0 > "$LIBRC"; }
# lib <fn> <args...> — the function in a subshell with the gh_rest_var stub;
# prints its output, then `rc=<n>` on the last line.
lib() {
  ( gh_rest_var() { local -n _v="$1"; printf '%s\n' "$3" >> "$LIBCALLS"
      local r; r=$(cat "$LIBRC"); [ "$r" = 0 ] || { GH_REST_STATUS=403; return "$r"; }
      _v=$(cat "$LIBBODY"); GH_REST_STATUS=200; return 0; }
    # shellcheck source=bin/lib/wake-prequeue-keys.sh
    . "$LIB" 2>/dev/null || { echo "rc=lib-missing"; exit 0; }
    "$@"; r=$?; echo; echo "rc=$r" )
}
libout() { grep -v -e '^rc=' -e '^$' <<<"$1" | sort; }
librc()  { sed -n 's/^rc=//p' <<<"$1" | tail -1; }
nreads() { grep -c . "$LIBCALLS"; }

[ -r "$LIB" ] && ok || bad "L0: bin/lib/wake-prequeue-keys.sh missing"

# L1. PR 7 and PR 9 pending on X, both runs completed: rc 0, exactly those two.
lib_reset
pend "$LS" example-org/demo 7 "$H7" "$X"; pend "$LS" example-org/demo 9 "$H9" "$X"
runs_json "$(title 7 "$H7" "$X")|completed" "$(title 9 "$H9" "$X")|completed" > "$LIBBODY"
o=$(lib wpk_done_prs "$LS" example-org/demo "$X" 100)
[ "$(librc "$o")" = 0 ] && ok || bad "L1: rc 0 expected (got $o)"
[ "$(libout "$o")" = "$(printf 'example-org/demo#7\nexample-org/demo#9')" ] && ok || bad "L1: exactly #7 and #9 (got $o)"
[ "$(nreads)" = 1 ] && grep -qx "repos/example-org/demo/actions/workflows/prequeue-gate.yml/runs?event=workflow_dispatch&head_sha=$X&status=completed&per_page=100" "$LIBCALLS" \
  && ok || bad "L1: one runs read on head_sha=X (got $(cat "$LIBCALLS"))"

# L2. Only PR 11 pending on X, its run in progress: rc 3, no output.
lib_reset
pend "$LS" example-org/demo 11 "$H11" "$X"
runs_json "$(title 11 "$H11" "$X")|in_progress" > "$LIBBODY"
o=$(lib wpk_done_prs "$LS" example-org/demo "$X" 100)
[ "$(librc "$o")" = 3 ] && [ -z "$(libout "$o")" ] && ok || bad "L2: rc 3, no output (got $o)"

# L3. PR 13 green on X, PR 15 pending on Y: for X rc 1 and no read.
lib_reset
pend "$LS" example-org/demo 13 "$H13" "$X" green; pend "$LS" example-org/demo 15 "$H15" "$Y"
o=$(lib wpk_done_prs "$LS" example-org/demo "$X" 100)
[ "$(librc "$o")" = 1 ] && [ "$(nreads)" = 0 ] && ok || bad "L3: rc 1, no read (got $o; reads $(nreads))"

# L4. Only a named-suites entry (_<fp>) pending on X: rc 1.
lib_reset
pend "$LS" example-org/demo 17 "$H17" "$X" pending 0123456789ab
o=$(lib wpk_done_prs "$LS" example-org/demo "$X" 100)
[ "$(librc "$o")" = 1 ] && [ "$(nreads)" = 0 ] && ok || bad "L4: a named-suites entry wakes nothing (got $o)"

# L5. PR 19 pending on X in other/repo, the wake is for example-org/demo: rc 1.
lib_reset
pend "$LS" other/repo 19 "$H19" "$X"
o=$(lib wpk_done_prs "$LS" example-org/demo "$X" 100)
[ "$(librc "$o")" = 1 ] && [ "$(nreads)" = 0 ] && ok || bad "L5: another repo wakes nothing (got $o)"
# ...and a repo whose name extends this one (demo_x) is another repo too.
pend "$LS" example-org/demo_x 19 "$H19" "$X"
o=$(lib wpk_pending "$LS" example-org/demo "$X")
[ "$(librc "$o")" = 1 ] && ok || bad "L5: example-org/demo_x is not example-org/demo (got $o)"

# L6. A 12-char prefix of X: rc 1, no read. A .tmp file is ignored.
lib_reset
pend "$LS" example-org/demo 7 "$H7" "$X"
o=$(lib wpk_done_prs "$LS" example-org/demo "${X:0:12}" 100)
[ "$(librc "$o")" = 1 ] && [ "$(nreads)" = 0 ] && ok || bad "L6: a short sha wakes nothing (got $o)"
lib_reset
mkdir -p "$LS/prequeue"; printf 'pending 1 - \n' > "$LS/prequeue/example-org_demo_7_${H7}_$X.tmp.123"
o=$(lib wpk_pending "$LS" example-org/demo "$X")
[ "$(librc "$o")" = 1 ] && ok || bad "L6: a .tmp file is not an entry (got $o)"

# L7. The runs read fails (rc 75), then a body that is not a run list: rc 2,
# every PR pending on X (7, 9, 11), and nothing pending elsewhere.
for mode in fail body; do
  lib_reset
  pend "$LS" example-org/demo 7 "$H7" "$X"; pend "$LS" example-org/demo 9 "$H9" "$X"; pend "$LS" example-org/demo 11 "$H11" "$X"
  pend "$LS" example-org/demo 15 "$H15" "$Y"
  if [ "$mode" = fail ]; then echo 75 > "$LIBRC"; else echo '{}' > "$LIBBODY"; fi
  o=$(lib wpk_done_prs "$LS" example-org/demo "$X" 100)
  [ "$(librc "$o")" = 2 ] && ok || bad "L7 $mode: rc 2 expected (got $o)"
  [ "$(libout "$o")" = "$(printf 'example-org/demo#11\nexample-org/demo#7\nexample-org/demo#9')" ] && ok || bad "L7 $mode: every PR pending on X (got $o)"
done

# L7b. A completed run for an OLDER head of PR 7 only: PR 7 is not woken. An
# UPPERCASE wake repo and a mixed-case file slug still match. Page 0 is 100.
lib_reset
pend "$LS" example-org/demo 7 "$H7" "$X"
runs_json "$(title 7 "$H7OLD" "$X")|completed" > "$LIBBODY"
o=$(lib wpk_done_prs "$LS" example-org/Demo "$X" 0)
[ "$(librc "$o")" = 3 ] && [ -z "$(libout "$o")" ] && ok || bad "L7b: an older head's run wakes nothing (got $o)"
grep -q 'per_page=100$' "$LIBCALLS" && ok || bad "L7b: page 0 reads as 100 (got $(cat "$LIBCALLS"))"

# L8 (round-trip). An entry the REAL pq_cache_put writes at the REAL pq_key is
# found by wpk_pending.
lib_reset
( MC_STATE_DIR="$LS"
  # shellcheck source=bin/lib/mc-prequeue.sh
  . "$DIR/bin/lib/mc-prequeue.sh" >/dev/null 2>&1 || exit 1
  pq_cache_put "$(pq_key example-org/demo 7 "$H7" "$X")" pending 1792000000 - "" ) || bad "L8: the real pq_cache_put failed"
o=$(lib wpk_pending "$LS" example-org/demo "$X")
[ "$(librc "$o")" = 0 ] && [ "$(libout "$o")" = "$(printf '7\t%s' "$H7")" ] && ok || bad "L8: the real writer's entry is found (got $o; files $(ls "$LS/prequeue" 2>/dev/null))"

# L9. wpk_title == the REAL pq_run_title.
want=$( . "$DIR/bin/lib/mc-prequeue.d/dispatch.sh" >/dev/null 2>&1 || exit 1; pq_run_title 7 "$H7" "$X" )
o=$(lib wpk_title 7 "$H7" "$X")
[ -n "$want" ] && [ "$(libout "$o")" = "$want" ] && ok || bad "L9: wpk_title must equal pq_run_title (want '$want', got '$o')"

# ════════════════════════════════════════════════════════════════════════════
# WAKE-LOOP
# ════════════════════════════════════════════════════════════════════════════
H="$T/h"
export HARNESS="$H"
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/locks" "$H/state" "$H/calls" "$H/fx"
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
( cd "$DIR" && scratch_install_closure bin/wake-loop.sh "$H" >/dev/null ) || { echo "FAIL: scratch_install_closure bin/wake-loop.sh"; exit 1; }
( cd "$DIR" && scratch_install_closure bin/jobs-client.sh "$H" >/dev/null ) || { echo "FAIL: scratch_install_closure bin/jobs-client.sh"; exit 1; }
# The lib is sourced, not named by a static source line the closure follows on
# a tree that lacks it; copy it when it exists.
[ -r "$LIB" ] && cp "$LIB" "$H/bin/lib/"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$H/bin/"
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/box-for.sh"
printf 'demo example-org/demo https://d.example /api/board 2 local\n' > "$H/fleet.conf"
printf '#!/bin/bash\nexec "$@"\n' > "$H/bin/setsid"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/flock"
for s in run-triage.sh deploy-train.sh postmerge-qa.sh; do printf '#!/bin/bash\nexit 0\n' > "$H/bin/$s"; done
printf '#!/bin/bash\nexit 1\n' > "$H/bin/unblocked-children.sh"
chmod +x "$H/bin/setsid" "$H/bin/flock" "$H/bin/run-triage.sh" "$H/bin/deploy-train.sh" \
         "$H/bin/postmerge-qa.sh" "$H/bin/unblocked-children.sh"
. "$DIR/tests/lib/wake-claim-stub.sh" || exit 1
wcs_install "$H/bin"
wcs_identity "$H/bin" || { echo "wcs_identity failed"; exit 1; }
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE \
      WAKE_CONDUCTOR_PER_TICK WAKE_CONDUCTOR_KEYED WAKE_CONDUCTOR_FULL WAKE_CONDUCTOR_SHA_LOOKUPS \
      WAKE_CONDUCTOR_PREQUEUE_MAIN WAKE_CONDUCTOR_PREQUEUE_PAGE WAKE_COOLDOWN_S WAKE_LOOP_CYCLES MC_ONLY_PR
cat > "$H/bin/gh" <<'SH'
#!/bin/bash
p=""; prev=""; for a in "$@"; do [ "$prev" = GET ] && p="$a"; prev="$a"; done
case "$*" in
  "auth token"*) echo faketoken-fixture; exit 0 ;;
  *"api rate_limit"*) printf '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}\n'; exit 0 ;;
  *"/commits/"*"/pulls"*)
    printf '%s\n' "$p" >> "$HARNESS/calls/gh-lookups"
    printf 'HTTP/2 200\r\n\r\n'; cat "$HARNESS/fx/pulls.json" 2>/dev/null || echo '[]'; exit 0 ;;
  *"/actions/workflows/prequeue-gate.yml/runs?"*)
    printf '%s\n' "$p" >> "$HARNESS/calls/gh-runs"
    if [ -e "$HARNESS/fx/runs.fail" ]; then
      printf 'HTTP/2 403\r\nx-ratelimit-remaining: 0\r\n\r\n{"message":"API rate limit exceeded"}\n'; exit 1
    fi
    printf 'HTTP/2 200\r\n\r\n'; cat "$HARNESS/fx/runs.json" 2>/dev/null || echo '{"workflow_runs":[]}'; exit 0 ;;
esac
printf '%s\n' "$*" >> "$HARNESS/calls/gh-unknown"
echo "gh stub: unknown call: $*" >&2; exit 1
SH
chmod +x "$H/bin/gh"

WS="$H/state/merge-conductor"
NOTLAUNCHED='not launched; the hourly sweep covers them'
W() { printf '{"id":%s,"repo":"%s","kind":"%s","key":"%s","event":"%s","at":"2026-10-23T12:00:00Z"}' "$1" "$2" "$3" "$4" "${5:-ev}"; }
wakes() { printf '{"wakes":[%s]}\n' "$(printf '%s,' "$@" | sed 's/,$//')" > "$H/wakes.json"; }
wreset() {
  for d in calls state flags fx; do scratch_rm "$H/$d"; done; rm -f "$H/wakes.json"
  mkdir -p "$H/calls" "$H/state/wcs" "$WS" "$H/fx"
  : > "$H/logs/wake-loop.log"
  printf 'example-org/demo#3\tready\t0\t%s\t-\t-\t-\thttps://x/3\n' "$(hex40 e)" > "$WS/pr-state.tsv"
  cat > "$H/bin/merge-conductor.sh" <<'SH'
#!/bin/bash
printf '%s\tMC_ONLY_PR=%s\t%s\n' "${1:-}" "${MC_ONLY_PR:-}" "$*" >> "$HARNESS/calls/merge-conductor"
SH
  chmod +x "$H/bin/merge-conductor.sh"
  wakes
}
wrun() {
  PATH="$H/bin:$PATH" HARNESS="$H" BOX_NAME=box-hub \
    WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0 WAKE_COOLDOWN_S=0 FLEET_CONF="$H/fleet.conf" \
    WAKE_CONDUCTOR_KEYED=1 \
    bash "$H/bin/wake-loop.sh" >/dev/null 2>&1 || true
  local prev="" cur i
  for i in 1 2 3 4 5 6; do
    sleep 0.25
    cur=$(cat "$H/calls/"* 2>/dev/null | wc -c | tr -d ' ')
    [ "$cur" = "$prev" ] && [ "$i" -ge 2 ] && return 0
    prev="$cur"
  done
}
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
launches() { cnt . "$H/calls/merge-conductor"; }
only() { awk -F'\t' 'NR==1 {sub(/^MC_ONLY_PR=/,"",$2); print $2; exit}' "$H/calls/merge-conductor" 2>/dev/null; }
onlyset() { only | tr ',' '\n' | sort | paste -sd, -; }
lookups() { cnt . "$H/calls/gh-lookups"; }
runreads() { cnt . "$H/calls/gh-runs"; }
unknown() { cnt . "$H/calls/gh-unknown"; }
wlog() { cat "$H/logs/wake-loop.log"; }
l1cache() { # PR 7 and PR 9 pending on X, both runs completed
  pend "$WS" example-org/demo 7 "$H7" "$X"; pend "$WS" example-org/demo 9 "$H9" "$X"
  runs_json "$(title 7 "$H7" "$X")|completed" "$(title 9 "$H9" "$X")|completed" > "$H/fx/runs.json"
}

# W1. One checks row on X: one launch keyed exactly {7, 9}, the prequeue line,
# no commits/<sha>/pulls read.
wreset; l1cache; wakes "$(W 1 example-org/demo checks "$X" check_run.completed)"
wrun
[ "$(launches)" = 1 ] && ok || bad "W1: one launch expected (got $(launches); log $(wlog))"
[ "$(onlyset)" = "example-org/demo#7,example-org/demo#9" ] && ok || bad "W1: MC_ONLY_PR must be exactly #7 and #9 (got '$(only)')"
grep -q "pr/checks: prequeue main ${X:0:12} finished — woke " "$H/logs/wake-loop.log" && ok || bad "W1: the prequeue main line: $(wlog)"
[ "$(lookups)" = 0 ] && ok || bad "W1: no commits/<sha>/pulls read (got $(lookups))"
[ "$(runreads)" = 1 ] && ok || bad "W1: one runs read (got $(runreads))"
[ "$(unknown)" = 0 ] && ok || bad "W1: no unknown gh call (got $(cat "$H/calls/gh-unknown" 2>/dev/null))"

# W2. A workflow_run.completed pr row for #7 and a checks row on X in one
# drain: one launch, keys {7, 9}, deduped.
wreset; l1cache
wakes "$(W 1 example-org/demo pr 7 workflow_run.completed)" "$(W 2 example-org/demo checks "$X" check_run.completed)"
wrun
[ "$(launches)" = 1 ] && [ "$(onlyset)" = "example-org/demo#7,example-org/demo#9" ] && ok \
  || bad "W2: one launch keyed {7, 9} (got $(launches): '$(only)')"

# W3. WAKE_CONDUCTOR_SHA_LOOKUPS=0: no runs read, no launch, today's line.
wreset; l1cache; wakes "$(W 1 example-org/demo checks "$X" check_run.completed)"
WAKE_CONDUCTOR_SHA_LOOKUPS=0 wrun
[ "$(runreads)" = 0 ] && [ "$(launches)" = 0 ] && ok || bad "W3: budget 0 reads and launches nothing (runs $(runreads), launches $(launches))"
grep -q 'lookups=0 miss=0 unread=0 skipped=1' <<<"$(grep "$NOTLAUNCHED" "$H/logs/wake-loop.log")" && ok || bad "W3: today's line with skipped=1: $(wlog)"

# W4. Only an in-progress run pending on X: no launch, running=1, nothing owed.
wreset
pend "$WS" example-org/demo 11 "$H11" "$X"
runs_json "$(title 11 "$H11" "$X")|in_progress" > "$H/fx/runs.json"
wakes "$(W 1 example-org/demo checks "$X" check_run.completed)"
wrun
[ "$(launches)" = 0 ] && ok || bad "W4: an in-progress run launches nothing (got $(launches))"
grep -q 'running=1' <<<"$(grep "$NOTLAUNCHED" "$H/logs/wake-loop.log")" && ok || bad "W4: running=1 in the summary: $(wlog)"
[ "$(lookups)" = 0 ] && ok || bad "W4: no pulls read for a placed main (got $(lookups))"
[ ! -e "$H/state/wake-conductor-owed" ] && ok || bad "W4: nothing owed (got $(cat "$H/state/wake-conductor-owed" 2>/dev/null))"

# W5. PR 15 pending on Y only, the wake is on X: today's E6 path.
wreset
pend "$WS" example-org/demo 15 "$H15" "$Y"
printf '[{"number":40,"state":"closed","head":{"sha":"%s"}}]\n' "$X" > "$H/fx/pulls.json"
wakes "$(W 1 example-org/demo checks "$X" check_run.completed)"
wrun
[ "$(launches)" = 0 ] && [ "$(lookups)" = 1 ] && [ "$(runreads)" = 0 ] && ok \
  || bad "W5: no launch, one pulls read, no runs read (launches $(launches), lookups $(lookups), runs $(runreads))"
grep -q 'lookups=1 miss=1' <<<"$(grep "$NOTLAUNCHED" "$H/logs/wake-loop.log")" && ok || bad "W5: miss=1: $(wlog)"

# W6. WAKE_CONDUCTOR_PREQUEUE_MAIN=0 with the L1 cache: today's behaviour.
wreset; l1cache; wakes "$(W 1 example-org/demo checks "$X" check_run.completed)"
WAKE_CONDUCTOR_PREQUEUE_MAIN=0 wrun
[ "$(runreads)" = 0 ] && [ "$(lookups)" = 1 ] && [ "$(launches)" = 0 ] && ok \
  || bad "W6: knob 0 = no runs read, one pulls read, no launch (runs $(runreads), lookups $(lookups), launches $(launches))"
grep -q 'lookups=1 miss=1 unread=0 skipped=0' <<<"$(grep "$NOTLAUNCHED" "$H/logs/wake-loop.log")" && ok || bad "W6: today's miss line: $(wlog)"

# W7. WAKE_CONDUCTOR_PREQUEUE_MAIN=x: read as 1, with one line.
wreset; l1cache; wakes "$(W 1 example-org/demo checks "$X" check_run.completed)"
WAKE_CONDUCTOR_PREQUEUE_MAIN=x wrun
[ "$(cnt "WAKE_CONDUCTOR_PREQUEUE_MAIN='x' is not 0 or 1 — using 1" "$H/logs/wake-loop.log")" = 1 ] && ok || bad "W7: one knob line: $(wlog)"
[ "$(onlyset)" = "example-org/demo#7,example-org/demo#9" ] && ok || bad "W7: x behaves as 1 (got '$(only)')"

# W8. The runs read is rate limited: fail-open, every PR pending on X.
wreset; l1cache; pend "$WS" example-org/demo 11 "$H11" "$X"; touch "$H/fx/runs.fail"
wakes "$(W 1 example-org/demo checks "$X" check_run.completed)"
wrun
[ "$(onlyset)" = "example-org/demo#11,example-org/demo#7,example-org/demo#9" ] && ok || bad "W8: fail-open wakes every pending PR on X (got '$(only)'; log $(wlog))"

# ════════════════════════════════════════════════════════════════════════════
# MERGE-CONDUCTOR-WAKE
# ════════════════════════════════════════════════════════════════════════════
SRV="$DIR/tests/lib/mc-wake-worker.bh-6975.mjs"
MSLUG=Example-Org/example-repo
MLSLUG=example-org/example-repo
T0=1792000000
LANE_REGISTRY=$(cd "$DIR" && . bin/lib/lanes-registry.sh && lanes_json_path "$DIR") \
  || { echo "setup: the lane registry did not compose"; exit 1; }
export LANE_REGISTRY
PIDS=()
trap 'for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; __scratch_exit_trap' EXIT
mkdir -p "$T/ghbin"
cat > "$T/ghbin/gh" <<'STUB'
#!/bin/bash
[ "${1:-}" = api ] || exit 0
shift; P=""
while [ $# -gt 0 ]; do
  case "$1" in -i) ;; -X|-H|--jq) shift ;; *) P="$1" ;; esac; shift
done
echo "$P" >> "$GHFIX/calls"
F="$GHFIX/$(printf '%s' "$P" | tr '/' '_').json"
if [ -e "$F" ]; then printf 'HTTP/2 200\r\ncontent-type: application/json\r\n\r\n'; cat "$F"; exit 0; fi
printf 'HTTP/2 404\r\ncontent-type: application/json\r\n\r\n{"message":"Not Found"}'; exit 1
STUB
chmod +x "$T/ghbin/gh"
M=0
mfresh() {
  M=$((M+1))
  MH="$T/m$M"
  mkdir -p "$MH/bin/lib" "$MH/logs" "$MH/locks" "$MH/state/merge-conductor" "$MH/env" "$MH/flags" "$T/mgh$M"
  cat > "$MH/bin/merge-conductor.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "${MC_ONLY_PR:-ALL}" >> "$STUB_CALLS"
STUB
  ( cd "$DIR" && scratch_install_closure bin/merge-conductor-wake.sh "$MH" && scratch_install_closure bin/jobs-client.sh "$MH" \
    && scratch_install_closure bin/fleet-conf.sh "$MH" ) >/dev/null 2>&1 || bad "setup: closure install"
  [ -r "$LIB" ] && cp "$LIB" "$MH/bin/lib/"
  chmod +x "$MH/bin/"*.sh 2>/dev/null
  printf 'proj %s https://proj.example /api/board 0 local -\n' "$MSLUG" > "$MH/fleet.conf"
  : > "$T/mcalls$M"; : > "$T/mw$M.log"; : > "$T/mw$M.port"; : > "$T/mgh$M/calls"
  export HARNESS="$MH" FLEET_CONF="$MH/fleet.conf" STUB_CALLS="$T/mcalls$M" GHFIX="$T/mgh$M"
  export HARNESS_SECRET=fixture-harness-secret JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
  export LANE_GATE_CACHE_S=0 BOX_NAME=hub GH_ETAG=0 MC_WAKE_NOW="$T0"
  unset MC_WAKE_BUDGET MC_WAKE_WAKES MC_WAKE_MIN_S MC_WAKE_MAX_AGE_S MC_WAKE_SHA_LOOKUPS MC_WAKE_PREQUEUE_MAIN MC_WAKE_PREQUEUE_PAGE \
        MC_KEYED_WAKE MC_KEYED_WAKE_MIN_S MC_H
  node "$SRV" "$T/mw$M.log" > "$T/mw$M.port" 2> "$T/mw$M.err" &
  local wpid=$!; PIDS+=("$wpid")
  for _ in $(seq 1 200); do [ -s "$T/mw$M.port" ] && break; kill -0 "$wpid" 2>/dev/null || break; sleep 0.05; done
  local port; port=$(head -1 "$T/mw$M.port")
  if [ -z "$port" ]; then wait "$wpid"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable"; exit 0; }
    echo "setup: worker did not start: $(cat "$T/mw$M.err")"; exit 1; fi
  export JOBS_URL="http://127.0.0.1:$port"
}
MLOG() { printf '%s' "$MH/logs/merge-conductor-wake-cron.log"; }
mhas() { grep -qF -- "$1" "$(MLOG)" 2>/dev/null; }
mcnt() { local n; n=$(grep -cF -- "$1" "$(MLOG)" 2>/dev/null); echo "${n:-0}"; }
mcalls() { grep -c . "$STUB_CALLS"; }
mrun() {
  PATH="$T/ghbin:$PATH" "$MH/bin/merge-conductor-wake.sh" > "$T/mrun.out" 2>&1
  local want; want=$(mcnt "action=tick")
  for _ in $(seq 1 50); do [ "$(mcalls)" -ge "${want:-0}" ] && break; sleep 0.1; done
  sleep 0.2
}
mcursor() { curl -sS "$JOBS_URL/__cursor" | jq -r '.cursor // "null"'; }
mmax() { curl -sS "$JOBS_URL/__cursor" | jq -r '.max_id'; }
mago() { date -u -d "@$(( MC_WAKE_NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
mwake() { # mwake <kind> <key> [event] — one row; prints its id
  curl -sS -X PUT "$JOBS_URL/__wake" -d "$(jq -nc --arg r "$MSLUG" --arg k "$1" --arg key "$2" \
    --arg e "${3:-check_run.completed}" --arg at "$(mago 5)" '{repo:$r, kind:$k, key:$key, event:$e, at:$at}')" | jq -r .id
}
msetting() { curl -sS -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k, value:$v}')" >/dev/null; }
mplant() { mrun; [ "$(mcursor)" != null ] || bad "setup: the first tick planted no cursor"; : > "$(MLOG)"; }
RUNSP="repos/$MLSLUG/actions/workflows/prequeue-gate.yml/runs?event=workflow_dispatch&head_sha=$X&status=completed&per_page=100"
mfx() { printf '%s' "$2" > "$GHFIX/$(printf '%s' "$1" | tr '/' '_').json"; }
mruns() { cnt "/actions/workflows/prequeue-gate.yml/runs" "$GHFIX/calls"; }
mpulls() { cnt "/commits/" "$GHFIX/calls"; }
ml1() {
  pend "$MH/state/merge-conductor" "$MSLUG" 7 "$H7" "$X"; pend "$MH/state/merge-conductor" "$MSLUG" 9 "$H9" "$X"
  mfx "$RUNSP" "$(runs_json "$(title 7 "$H7" "$X")|completed" "$(title 9 "$H9" "$X")|completed")"
}

# C1. One checks wake on X with the L1 cache: two keyed ticks (#7, #9), two
# reason=prequeue-main lines, the cursor moves past the wake.
mfresh; mplant; ml1
wid=$(mwake checks "$X")
mrun
[ "$(sort "$STUB_CALLS" | paste -sd, -)" = "$MSLUG#7,$MSLUG#9" ] && ok || bad "C1: keyed ticks for #7 and #9 (got $(paste -sd, "$STUB_CALLS"); log $(cat "$(MLOG)"))"
[ "$(mcnt "action=tick reason=prequeue-main")" = 2 ] && mhas "WAKE pr=7 " && mhas "WAKE pr=9 " && ok || bad "C1: two prequeue-main tick lines (log $(cat "$(MLOG)"))"
[ "$(mcursor)" -ge "$wid" ] 2>/dev/null && ok || bad "C1: the cursor moves past wake $wid (got $(mcursor))"
[ "$(mpulls)" = 0 ] && [ "$(mruns)" = 1 ] && ok || bad "C1: one runs read, no pulls read (calls $(cat "$GHFIX/calls"))"

# C2. Only an in-progress run: one skip prequeue-running line, no launch.
mfresh; mplant
pend "$MH/state/merge-conductor" "$MSLUG" 11 "$H11" "$X"
mfx "$RUNSP" "$(runs_json "$(title 11 "$H11" "$X")|in_progress")"
wid=$(mwake checks "$X")
mrun
[ "$(mcalls)" = 0 ] && ok || bad "C2: no keyed tick (got $(mcalls))"
[ "$(mcnt "action=skip reason=prequeue-running")" = 1 ] && ok || bad "C2: one skip prequeue-running line (log $(cat "$(MLOG)"))"
[ "$(mcursor)" -ge "$wid" ] 2>/dev/null && ok || bad "C2: the cursor moves past wake $wid (got $(mcursor))"

# C3. MC_WAKE_BUDGET=1: one launch, the other PR carried reason=budget.
mfresh; mplant; ml1; msetting lane.merge-conductor-wake.mc_wake_budget 1
mwake checks "$X" >/dev/null
mrun
[ "$(mcalls)" = 1 ] && ok || bad "C3: one keyed tick under budget 1 (got $(mcalls))"
[ "$(mcnt "action=carry reason=budget")" = 1 ] && ok || bad "C3: one carry budget line (log $(cat "$(MLOG)"))"
[ "$(wc -l < "$MH/state/merge-conductor-wake/carry.tsv" 2>/dev/null)" = 1 ] && ok || bad "C3: one carried key (got $(cat "$MH/state/merge-conductor-wake/carry.tsv" 2>/dev/null))"

# C4. MC_WAKE_SHA_LOOKUPS=0: skip sha-unplaced, no runs read.
mfresh; mplant; ml1; msetting lane.merge-conductor-wake.mc_wake_sha_lookups 0
mwake checks "$X" >/dev/null
mrun
[ "$(mcalls)" = 0 ] && [ "$(mruns)" = 0 ] && [ "$(mcnt "action=skip reason=sha-unplaced")" = 1 ] && ok \
  || bad "C4: lookups 0 = skip sha-unplaced, no read (calls $(mcalls), runs $(mruns); log $(cat "$(MLOG)"))"

# C5. MC_WAKE_PREQUEUE_MAIN=0: today's skip no-open-pr after one pulls read.
mfresh; mplant; ml1; msetting lane.merge-conductor-wake.mc_wake_prequeue_main 0
mfx "repos/$MLSLUG/commits/$X/pulls" '[]'
mwake checks "$X" >/dev/null
mrun
[ "$(mcalls)" = 0 ] && [ "$(mruns)" = 0 ] && [ "$(mpulls)" = 1 ] && [ "$(mcnt "action=skip reason=no-open-pr")" = 1 ] && ok \
  || bad "C5: knob 0 = today's no-open-pr (calls $(mcalls), runs $(mruns), pulls $(mpulls); log $(cat "$(MLOG)"))"
for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; PIDS=()

# ════════════════════════════════════════════════════════════════════════════
# END TO END: the wake's MC_ONLY_PR, then ONE keyed tick of the whole conductor
# ════════════════════════════════════════════════════════════════════════════
E="$T/e2e"; mkdir -p "$E"
SLUG=example-org/demo
U="https://github.com/$SLUG/pull"
NOW=$(date +%s)
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
export GIT_CONFIG_GLOBAL="$E/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global "url.$E/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$E/origin.git.insteadOf" "https://github.com/$SLUG.git" --add
S="$E/seed"; git init -q --bare "$E/origin.git"; git init -q "$S"
printf 'one\ntwo\n' > "$S/x.txt"; git -C "$S" add -A; git -C "$S" commit -qm A; MA=$(git -C "$S" rev-parse HEAD)
echo y > "$S/y.txt"; git -C "$S" add -A; git -C "$S" commit -qm p41; HA=$(git -C "$S" rev-parse HEAD)
git -C "$S" checkout -q "$MA"; echo z > "$S/z.txt"; git -C "$S" add -A; git -C "$S" commit -qm p43; HB=$(git -C "$S" rev-parse HEAD)
git -C "$S" push -q "$E/origin.git" "$MA:refs/heads/main" "$HA:refs/pull/41/head" "$HB:refs/pull/43/head" || exit 1

export HARNESS="$E/h"
mkdir -p "$E/h/bin/lib" "$E/h/logs" "$E/h/state" "$E/h/flags" "$E/h/locks" "$E/h/builds" "$E/h/env" "$E/h/tmp" "$E/fakebin" "$E/repos"
cat > "$E/h/bin/lib/ticket-ownership.sh" <<'EOF'
to_lane_hold() { return 1; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
to_lead_merge_hold() { return 1; }
EOF
cat > "$E/h/bin/lib/block-gate.sh" <<'EOF'
bg_enforce() { return 0; }
bg_scan_read() { return 0; }
bg_scan() { return 0; }
bg_why() { echo "BLOCK by operator"; }
bg_reason() { echo "BLOCK by operator"; }
bg_refuse() { return 0; }
EOF
: > "$E/h/bin/lib/pr-snapshot.sh"
( cd "$DIR" && scratch_install_closure bin/merge-conductor.sh "$E/h" >/dev/null ) || { echo "FAIL: closure bin/merge-conductor.sh"; exit 1; }
( cd "$DIR" && scratch_install_closure bin/jobs-client.sh "$E/h" >/dev/null ) || exit 1
( cd "$DIR" && scratch_install_closure bin/prequeue-learned.sh "$E/h" >/dev/null ) || exit 1
scratch_rm "$E/h/bin/lib/gh-limit-logger.sh"
cp "$DIR/bin/fleet-conf.sh" "$E/h/bin/" || exit 1
cp "$DIR/tests/lib/rest-emit.sh" "$E/fakebin/restpr" && chmod +x "$E/fakebin/restpr" || exit 1
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$E/h/bin/$s.sh"; chmod +x "$E/h/bin/$s.sh"; done
printf '#!/bin/bash\necho "[lane-alert] $*" >> "%s/h/logs/ALERTS.log"\n' "$E" > "$E/h/bin/lane-alert.sh"; chmod +x "$E/h/bin/lane-alert.sh"
printf 'demo %s - - 2 box-demo\n' "$SLUG" > "$E/h/fleet.conf"
: > "$E/h/env/global.env"
for n in 41 43; do
  t=$((n - 21)); hd=$HA; [ "$n" = 43 ] && hd=$HB
  R="$E/h/builds/pool-demo-BH-$t-202610230001"; mkdir -p "$R"
  echo "PR_CREATED $U/$n" > "$R/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$R/review.md"
  echo "$hd" > "$R/reviewed-sha"; : > "$R/pipeline.log"
done
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
EMCD="$E/h/state/merge-conductor"
cat > "$E/fakebin/gh" <<EOF
#!/bin/bash
MN=$MA
hd() { case "\$1" in 41) echo $HA ;; 43) echo $HB ;; esac; }
case "\$*" in
  *"auth token"*) echo faketoken-fixture ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  "workflow run prequeue-gate.yml"*) printf '%s\n' "\$*" >> "$E/dispatch.txt"; exit 0 ;;
  *"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml/runs?"*) restpr --raw 200 "\$(cat "$E/runs.json")" ;;
  *"api -i -X GET repos/$SLUG/actions/runs/"*"/jobs"*)
    id=\$(printf '%s' "\$*" | sed -n 's|.*actions/runs/\([0-9]*\)/jobs.*|\1|p'); restpr --raw 200 "{\"jobs\":[{\"id\":\${id}0}]}" ;;
  *"api -i -X GET repos/$SLUG/check-runs/"*"/annotations"*)
    j=\$(printf '%s' "\$*" | sed -n 's|.*check-runs/\([0-9]*\)0/annotations.*|\1|p'); restpr --raw 200 "\$(cat "$E/ann.\$j.json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml"|*"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml "*)
    restpr --raw 200 '{"id":5,"path":".github/workflows/prequeue-gate.yml"}' ;;
  *"api -i -X GET repos/$SLUG/commits/main"|*"api -i -X GET repos/$SLUG/commits/main "*) restpr --raw 200 "{\"sha\":\"\$MN\"}" ;;
  *"api -i -X GET repos/$SLUG/compare/"*) restpr --raw 200 '{"status":"ahead","ahead_by":1}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"actions/runs?head_sha="*) restpr --raw 200 '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"success","run_started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X POST repos/$SLUG/issues/"*"/comments -f body=@mergifyio"*) printf '%s\n' "\$*" >> "$E/c-enq.txt"; restpr --raw 201 '{"id":901}' ;;
  *"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$E/c-enq.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) case "\$*" in *mergifyio*) printf '%s\n' "\$*" >> "$E/c-enq.txt" ;; esac ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$E/c-enq.txt"; exit 0 ;;
  *"/pulls/"*"/merge"|*"/pulls/"*"/merge "*) printf '%s\n' "\$*" >> "$E/c-enq.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*)
    n=\$(printf '%s' "\$*" | sed -n 's|.*repos/$SLUG/pulls/\([0-9]*\).*|\1|p'); b=\$((n - 21))
    restpr OPEN "\$(hd "\$n")" "ticket/bh-\$b" main "" MERGEABLE CLEAN operator "" "Closes #\$b" ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*)
    printf '[{"number":41,"url":"$U/41","headRefOid":"$HA","headRefName":"ticket/bh-20","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]},{"number":43,"url":"$U/43","headRefOid":"$HB","headRefName":"ticket/bh-22","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]\n' ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$E/fakebin/gh"
cat > "$E/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$E/fakebin/curl"
# The two titles, completed success, one green prequeue-verdict annotation each.
jq -nc --arg t1 "$(title 41 "$HA" "$MA")" --arg t2 "$(title 43 "$HB" "$MA")" --arg at "$(iso $((NOW - 600)))" \
  '{workflow_runs:[{id:9141, display_title:$t1, status:"completed", conclusion:"success", created_at:$at},
                   {id:9143, display_title:$t2, status:"completed", conclusion:"success", created_at:$at}]}' > "$E/runs.json"
jq -nc --arg m "green main=$MA head=$HA suites=tests/a.sh" '[{title:"prequeue-verdict", message:$m}]' > "$E/ann.9141.json"
jq -nc --arg m "green main=$MA head=$HB suites=tests/a.sh" '[{title:"prequeue-verdict", message:$m}]' > "$E/ann.9143.json"
: > "$E/c-enq.txt"; : > "$E/dispatch.txt"
mkdir -p "$EMCD"; : > "$EMCD/pr-state.tsv"
touch "$E/h/flags/merge-conductor-actions" "$E/h/flags/merge-conductor-merge"

# E2E1 step 1: the wake. The wake-loop tree (slug example-org/demo, the same as
# the conductor's) gets both PRs pending on MA and both runs completed; one
# checks row on MA. Record the MC_ONLY_PR it launched.
export HARNESS="$H"
wreset
pend "$WS" "$SLUG" 41 "$HA" "$MA"; pend "$WS" "$SLUG" 43 "$HB" "$MA"
cp "$E/runs.json" "$H/fx/runs.json"
wakes "$(W 1 "$SLUG" checks "$MA" check_run.completed)"
wrun
WOKE=$(only)
[ "$(onlyset)" = "example-org/demo#41,example-org/demo#43" ] && ok || bad "E2E1: the wake launched #41 and #43 (got '$WOKE'; log $(wlog))"

# E2E1 step 2: ONE keyed tick of the whole conductor with that MC_ONLY_PR. The
# conductor's own cache holds both PRs pending on MA (as its dispatch left it).
export HARNESS="$E/h"
for n in 41 43; do
  hd=$HA; [ "$n" = 43 ] && hd=$HB
  ( MC_STATE_DIR="$EMCD"
    . "$E/h/bin/lib/mc-prequeue.sh" >/dev/null 2>&1 || exit 1
    pq_cache_put "$(pq_key "$SLUG" "$n" "$hd" "$MA")" pending "$((NOW - 600))" - "" ) || bad "E2E1: seed pending #$n"
done
if [ -n "$WOKE" ]; then
  # The open-PR list is REST now; the bridge answers it from the stub's
  # `gh pr list` (tests/lib/gh-list-bridge.sh). Sourced in this subshell only.
  ( # shellcheck source=tests/lib/gh-list-bridge.sh
    . "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
    # shellcheck source=tests/lib/verdict-fixture.sh
    . "$DIR/tests/lib/verdict-fixture.sh" || exit 1
    vpf_export || exit 1
    cd "$E" && env PATH="$E/fakebin:$PATH" HARNESS="$E/h" FLEET_CONF="$E/h/fleet.conf" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default \
    MC_REPOS="$E/repos" MC_MERGE_BUDGET=5 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
    MC_MAIN_RED_DETECT=0 MC_DETACHED_REBASE=0 PR_DEP_GATE_TICKET=0 MC_ONLY_PR="$WOKE" \
    bash "$E/h/bin/merge-conductor.sh" >/dev/null 2>"$E/tick.err" ) || { echo "E2E1 tick rc=$? stderr:"; tail -5 "$E/tick.err"; }
fi
enq_of() { grep -c "issues/$1/comments\|issues/$1/labels\|pulls/$1/merge\|pr merge $U/$1" "$E/c-enq.txt" 2>/dev/null || true; }
[ "$(enq_of 41)" -ge 1 ] && [ "$(enq_of 43)" -ge 1 ] && ok \
  || bad "E2E1: both PRs enqueued on the one keyed tick (41: $(enq_of 41), 43: $(enq_of 43); log $(grep -E 'PREQUEUE|#4[13]' "$E/h/logs/merge-conductor.log" 2>/dev/null | tail -8); err $(tail -3 "$E/tick.err" 2>/dev/null))"
[ "$(grep -c '^workflow run prequeue-gate.yml' "$E/dispatch.txt")" = 0 ] && ok || bad "E2E1: no dispatch (got $(cat "$E/dispatch.txt"))"
for n in 41 43; do
  hd=$HA; [ "$n" = 43 ] && hd=$HB
  case "$(cat "$EMCD/prequeue/example-org_demo_${n}_${hd}_$MA" 2>/dev/null)" in green*) ok ;; *) bad "E2E1: #$n's entry settled green (got '$(cat "$EMCD/prequeue/example-org_demo_${n}_${hd}_$MA" 2>/dev/null)')" ;; esac
done

echo "wake-prequeue-main.bh-8173: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
