#!/bin/bash
# tests/mc-backstop-stale-row.bh-8310-test.sh — a keyed conductor run on a PR
# that GitHub reports merged or closed moves its READY/WAIT_CI row to MERGED or
# CLOSED, so one stale row no longer holds the backstop's only slot (BH-8310).
#
# THE INCIDENT (2026-10-25, bh-hub-2). example-org/cromford#912 merged on
# 2026-09-18 outside the conductor. Its row stayed READY with the oldest
# `since`. The closed probe read it MERGED and wrote only a closed-watch memo
# `merged`, and that memo took the PR out of every later probe. The backstop
# sorts READY rows first, oldest first, so with MC_BACKSTOP_MAX_RUNNING=1 it
# spent every */5 fire on #912 and no open PR got a backstop run.
#
# WHAT IS DRIVEN. The REAL bin/merge-conductor-backstop.sh starts the REAL
# bin/merge-conductor.sh (keyed, MC_ONLY_PR), with gh and curl stubbed. Each
# case builds its own scratch harness under $T/<case>.
#   S1  #912 (merged, oldest READY) and #20 (open, READY), MAXR=1: fire 1 runs
#       #912 and its row ends MERGED; fire 2 runs #20 and not #912
#   S2  #913, closed without merging on a hand branch: the keyed run moves its
#       row to CLOSED
#   S3  mutation: the same tree with the tick_project call to
#       mc_offlist_settle_tick (bin/merge-conductor.d/bh-8310-stale-row-settle.sh)
#       deleted leaves #912 READY (the call is the fix)
#   S4  #914 answers 403: the row is unchanged and no memo is written (D9)
#   S5  every GitHub read went to the suite's stub; no gh write verb was used
#   S6  #915, a harness PR (ticket/ branch) closed without merging, with its PR
#       lock held: the keyed probe answers CLOSED and moves no row; the memo
#       goes back to `open 0` (closed_watch_reoffer), so the closed-unmerged
#       settle, which runs the ticket_open check and pages, still owns it
# Run from anywhere: tests/mc-backstop-stale-row.bh-8310-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null && command -v setsid >/dev/null || { echo "FAIL: flock/setsid missing"; exit 1; }

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
[ -f "$DIR/bin/merge-conductor.sh" ] && [ -f "$DIR/bin/merge-conductor-backstop.sh" ] || exit 1   # impact: this suite drives both
HD=$(printf 'd%.0s' $(seq 40))   # every row's head = reviewed sha

# build <case>: one scratch harness at $T/<case>/h with its own stub gh and curl.
build() {
  local C="$T/$1"
  mkdir -p "$C" || return 1
  fx_mc_harness "$DIR" "$C" || return 1
  fx_conductor_tick "$DIR" "$C" || return 1
  ( cd "$DIR" && scratch_install_closure bin/merge-conductor-backstop.sh "$C/h" ) >/dev/null || return 1
  chmod +x "$C/h/bin/"*.sh || return 1
  # The settle call lives in its fragment (BH-7453); fx_conductor_tick copies no fragment.
  mkdir -p "$C/h/bin/merge-conductor.d" || return 1
  cp "$DIR/bin/merge-conductor.d/bh-8310-stale-row-settle.sh" "$C/h/bin/merge-conductor.d/" || return 1
  mkdir -p "$C/pr" "$C/h/state/merge-conductor" || return 1
  printf 'demo example-org/demo https://demo.example /api/board 2 box-demo\n' > "$C/h/fleet.conf"
  : > "$C/h/env/global.env"
  printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$C/h/bin/agent-call.sh"; chmod +x "$C/h/bin/agent-call.sh"
  # The open list: #20 only. Per-PR answers come from $C/pr/<n>: "STATE BRANCH" or "403".
  cat > "$C/open.json" <<J
[{"number":20,"url":"https://github.com/example-org/demo/pull/20","headRefOid":"$HD","headRefName":"ticket/demo-20","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"}]
J
  echo "OPEN ticket/demo-20" > "$C/pr/20"
  cat > "$C/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$C/gh-calls.txt"
ARGS="\$*"
case "\$ARGS" in
  *"auth token"*) echo faketoken ;;
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*|*"-X PATCH"*|*"-X POST"*|*"-X PUT"*)
    echo "WRITE VERB: \$ARGS" >> "$C/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/demo --state open"*) cat "$C/open.json" ;;
  *"api -i -X GET repos/example-org/demo/pulls/"*"/"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/demo/pulls/"*)
    n=\${ARGS#*demo/pulls/}; n=\${n%% *}
    printf '%s\n' "\$n" >> "$C/probes.txt"
    spec=\$(cat "$C/pr/\$n" 2>/dev/null) || { restpr --raw 404 '{"message":"Not Found"}'; exit 0; }
    set -- \$spec
    [ "\$1" = 403 ] && { restpr --raw 403 '{"message":"Resource not accessible by integration"}'; exit 0; }
    restpr "\$1" "$HD" "\$2" main ;;
  *"pr list"*) echo "[]" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
  chmod +x "$C/fakebin/gh"
  cat > "$C/fakebin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$C/curl-calls.txt"
printf '{"error":"not found"}\n404\n'
EOF
  chmod +x "$C/fakebin/curl"
  : > "$C/gh-calls.txt"; : > "$C/gh-writes.txt"; : > "$C/probes.txt"; : > "$C/curl-calls.txt"; : > "$C/bs.out"
}
# The stub repo's REST open list is answered from the stub's `pr list` arm.
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1

seed() { # seed <case> <num> <state> <since>
  printf 'example-org/demo#%s\t%s\t%s\t%s\t%s\t-\tclean\thttps://github.com/example-org/demo/pull/%s\n' \
    "$2" "$3" "$4" "$HD" "$HD" "$2" >> "$T/$1/h/state/merge-conductor/pr-state.tsv"
}
state_of() { awk -F'\t' -v k="example-org/demo#$2" '$1==k {print $2}' "$T/$1/h/state/merge-conductor/pr-state.tsv"; }
memo_of()  { cut -f1 "$T/$1/h/state/merge-conductor/closed-watch/example-org_demo/$2" 2>/dev/null; }
lockfile() { printf '%s/h/locks/mc-backstop-example-org_demo_%s.lock' "$T/$1" "$2"; }

# fire <case> [VAR=val...]: one backstop fire, MAXR=1; its output is appended to $T/<case>/bs.out.
fire() {
  local C="$T/$1"; shift
  ( cd "$C" && env PATH="$C/fakebin:$PATH" HARNESS="$C/h" HARNESS_SECRET=x MC_PR_PARALLEL=1 \
      MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_REHYDRATE=0 LAND_FIRE=0 \
      MC_BACKSTOP_MAX_RUNNING=1 "$@" bash "$C/h/bin/merge-conductor-backstop.sh" >> "$C/bs.out" 2>&1 )
}
# wait_run <case> <num> <n>: wait until #<num> logged <n> run ends and its lock is free.
wait_run() {
  local i=0 lk; lk=$(lockfile "$1" "$2")
  while [ "$(grep -c "example-org/demo#$2: keyed conductor run" "$T/$1/bs.out" 2>/dev/null || true)" -lt "$3" ] && [ "$i" -lt 480 ]; do
    sleep 0.25; i=$((i + 1))   # determinism: ok polls for the detached run's end line, bounded at 120 s
  done
  i=0
  while [ -e "$lk" ] && ! ( exec 7>>"$lk" && flock -n 7 ) 2>/dev/null && [ "$i" -lt 40 ]; do
    sleep 0.25; i=$((i + 1))   # determinism: ok polls for the run's lock to drop, bounded at 10 s
  done
}
runs_of() { grep -c "example-org/demo#$2: keyed conductor run" "$T/$1/bs.out" 2>/dev/null || true; }

# ============================================================================
# S1. THE TICKET'S ACCEPTANCE: the merged row settles; the open PR gets a run.
# ============================================================================
build s1 || { echo "FAIL: cannot build s1"; exit 1; }
seed s1 912 READY 1; seed s1 20 READY 100
echo "MERGED ticket/bh-912" > "$T/s1/pr/912"
fire s1
wait_run s1 912 1
[ "$(runs_of s1 912)" = 1 ] && ok || bad "S1 fire 1 must run #912, the oldest READY row (bs.out: $(tail -3 "$T/s1/bs.out"))"
[ "$(state_of s1 912)" = MERGED ] && ok || bad "S1 the keyed run of a merged PR must move its row to MERGED (row: $(state_of s1 912), memo: $(memo_of s1 912))"
grep -q 'example-org/demo#912 READY -> MERGED .*reason=merged outside the conductor (closed-watch)' "$T/s1/h/logs/merge-conductor.log" \
  && ok || bad "S1 the transition is logged with its reason: $(grep '#912' "$T/s1/h/logs/merge-conductor.log" | tail -3)"
fire s1
wait_run s1 20 1
[ "$(runs_of s1 20)" = 1 ] && ok || bad "S1 fire 2 must start a keyed run for the open PR #20 (bs.out: $(tail -3 "$T/s1/bs.out"))"
[ "$(runs_of s1 912)" = 1 ] && ok || bad "S1 fire 2 must not run #912 again (runs: $(runs_of s1 912))"
grep -q 'keyed tick: 1 key(s) — example-org/demo#20' "$T/s1/h/logs/merge-conductor.log" && ok \
  || bad "S1 the conductor must log the keyed tick for #20: $(grep 'keyed tick' "$T/s1/h/logs/merge-conductor.log")"

# ============================================================================
# S2. A PR CLOSED WITHOUT MERGING, on a hand branch (no harness record).
# ============================================================================
build s2 || { echo "FAIL: cannot build s2"; exit 1; }
seed s2 913 READY 1
echo "CLOSED fix/by-hand" > "$T/s2/pr/913"
fire s2
wait_run s2 913 1
[ "$(state_of s2 913)" = CLOSED ] && ok || bad "S2 the keyed run of a closed PR must move its row to CLOSED (row: $(state_of s2 913), memo: $(memo_of s2 913))"
grep -q 'example-org/demo#913 READY -> CLOSED .*reason=closed without merging (closed-watch)' "$T/s2/h/logs/merge-conductor.log" \
  && ok || bad "S2 the transition is logged with its reason: $(grep '#913' "$T/s2/h/logs/merge-conductor.log" | tail -3)"

# ============================================================================
# S3. MUTATION (D2): delete the call site, and the row stays READY.
# ============================================================================
build s3 || { echo "FAIL: cannot build s3"; exit 1; }
seed s3 912 READY 1
echo "MERGED ticket/bh-912" > "$T/s3/pr/912"
# The call is the one fragment-gated line in tick_project; the fragment holds the
# settle call. Both must be present, and deleting the driver line removes the fix.
[ -f "$T/s3/h/bin/merge-conductor.d/bh-8310-stale-row-settle.sh" ] && ok \
  || bad "S3 the scratch harness must carry bin/merge-conductor.d/bh-8310-stale-row-settle.sh"
F=$(grep -c 'mc_settle_offlist_rows "\$1" "\$2" apply' "$DIR/bin/merge-conductor.d/bh-8310-stale-row-settle.sh" || true)
[ "$F" = 1 ] && ok || bad "S3 the fragment must call mc_settle_offlist_rows in apply mode exactly once (found $F)"
B=$(grep -c 'mc_offlist_settle_tick "\$SLUG"' "$T/s3/h/bin/merge-conductor.sh" || true)
sed -i '/mc_offlist_settle_tick "\$SLUG"/d' "$T/s3/h/bin/merge-conductor.sh"
[ "$B" = 1 ] && [ "$(grep -c 'mc_offlist_settle_tick "\$SLUG"' "$T/s3/h/bin/merge-conductor.sh" || true)" = 0 ] && ok \
  || bad "S3 tick_project must call mc_offlist_settle_tick exactly once (found $B call lines)"
fire s3
wait_run s3 912 1
[ "$(state_of s3 912)" = READY ] && ok || bad "S3 without the call the row must stay READY, or the call is not what fixes it (row: $(state_of s3 912))"
[ "$(memo_of s3 912)" = merged ] && ok || bad "S3 the probe still memos merged without the call (memo: $(memo_of s3 912))"

# ============================================================================
# S4. A 403 ON THE PROBE: no row change, no memo.
# ============================================================================
build s4 || { echo "FAIL: cannot build s4"; exit 1; }
seed s4 914 READY 1
echo "403" > "$T/s4/pr/914"
cp "$T/s4/h/state/merge-conductor/pr-state.tsv" "$T/s4/rows.before"
fire s4
wait_run s4 914 1
[ "$(runs_of s4 914)" = 1 ] && ok || bad "S4 the fire must run #914 (bs.out: $(tail -3 "$T/s4/bs.out"))"
grep -q '^914$' "$T/s4/probes.txt" && ok || bad "S4 the keyed run must probe #914 (fixture drift; probes: $(tr '\n' ' ' < "$T/s4/probes.txt"))"
cmp -s "$T/s4/rows.before" "$T/s4/h/state/merge-conductor/pr-state.tsv" && ok || bad "S4 a 403 must change no row (row: $(state_of s4 914))"
[ -e "$T/s4/h/state/merge-conductor/closed-watch/example-org_demo/914" ] && bad "S4 a 403 must write no memo (memo: $(memo_of s4 914))" || ok

# ============================================================================
# S6. A HARNESS PR CLOSED UNMERGED, ITS LOCK HELD: no inline settle, memo reoffered.
# ============================================================================
build s6 || { echo "FAIL: cannot build s6"; exit 1; }
seed s6 915 READY 1
echo "CLOSED ticket/demo-915" > "$T/s6/pr/915"
mkdir -p "$T/s6/h/locks" || exit 1
LK6="$T/s6/h/locks/merge-conductor-demo-915.lock"
flock "$LK6" sleep 60 &   # determinism: ok another worker's PR lock, held for the fire, killed below
HOLD6=$!
i=0; while ! [ -e "$LK6" ] || ( exec 7>>"$LK6" && flock -n 7 ) 2>/dev/null; do
  [ "$i" -lt 40 ] || break; sleep 0.25; i=$((i + 1))   # determinism: ok waits for the holder to take the lock, bounded at 10 s
done
fire s6
wait_run s6 915 1
kill "$HOLD6" 2>/dev/null; wait "$HOLD6" 2>/dev/null
grep -q '^915$' "$T/s6/probes.txt" && ok || bad "S6 the keyed run must probe #915 (probes: $(tr '\n' ' ' < "$T/s6/probes.txt"))"
[ "$(state_of s6 915)" = READY ] && ok || bad "S6 a keyed CLOSED answer must not settle a harness PR inline (row: $(state_of s6 915))"
grep -q 'example-org/demo#915 READY -> CLOSED .*reason=closed without merging (closed-watch)' "$T/s6/h/logs/merge-conductor.log" \
  && bad "S6 the row must not get the closed-watch reason: $(grep '#915' "$T/s6/h/logs/merge-conductor.log" | tail -3)" || ok
grep -q 'example-org/demo#915: off-list probe answered CLOSED' "$T/s6/h/logs/merge-conductor.log" \
  && ok || bad "S6 the keyed probe must log the CLOSED answer (log: $(grep '#915' "$T/s6/h/logs/merge-conductor.log" | tail -3))"
[ "$(cut -f1,2 "$T/s6/h/state/merge-conductor/closed-watch/example-org_demo/915" 2>/dev/null)" = "$(printf 'open\t0')" ] && ok \
  || bad "S6 the memo must be reoffered as open 0, not left closed (memo: $(cat "$T/s6/h/state/merge-conductor/closed-watch/example-org_demo/915" 2>/dev/null))"

# ============================================================================
# S5. ONLY THE STUBS: every read went to this suite's gh, none was a write.
# ============================================================================
for c in s1 s2 s3 s4 s6; do
  [ -s "$T/$c/gh-calls.txt" ] && ok || bad "S5 $c: the stub gh recorded no call (the runs read GitHub some other way)"
  [ -s "$T/$c/gh-writes.txt" ] && bad "S5 $c: a gh write verb was used: $(head -2 "$T/$c/gh-writes.txt")" || ok
  grep -qE 'https?://(api\.)?github\.com' "$T/$c/curl-calls.txt" && bad "S5 $c: curl reached GitHub: $(grep github "$T/$c/curl-calls.txt" | head -1)" || ok
done

echo "mc-backstop-stale-row.bh-8310-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
