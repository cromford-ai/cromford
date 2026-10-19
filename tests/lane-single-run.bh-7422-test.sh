#!/bin/bash
# tests/lane-single-run.bh-7422-test.sh — BH-7422: one scheduled run per
# (lane, project).
#
# WHY. Hub cron lanes stacked: cron started a lane again before the last run of
# the same lane and project ended, and every extra copy made every copy slower
# (load 160-185 on 4 cores, 2026-10-19). lane_gate_or_exit, which every lane
# calls, now claims (lane, project) for the life of a SCHEDULED run. A helper
# call of a gated script never claims (review of #7438: harden-state --release
# under its caller's lock became a no-op). What is proved:
#   1. a second tick of a held (lane, project) exits 0 in under 2 s, does no
#      work, logs `skipped (running)` in logs/lane-runs-cron.log, and writes no
#      ALERTS line;
#   2. a different project of the same lane runs;
#   3. a lane whose manifest says `"single_run": false` runs twice;
#   4. the settings rows lane.<id>.single_run / lane.<id>.<project>.single_run
#      off (any case) run twice; a row for another project does not;
#   5. the claim ends with the run; a background child does not keep it;
#   6. a nested gate of the same lane runs inside its parent's run;
#   7. a project-lane-run child (PL_LANE/PL_PROJECT) is keyed by PL_PROJECT;
#   8. measure lines: `ran pid=<n> live=<n>`, and none for a paused run;
#   9. LANE_GATE_DISABLE=1 bypasses the claim;
#  10. the held case works under /bin/bash (3.2 on a Mac, BH-3565);
#  11. HELPER CALLS NEVER SKIP: a run under another gated run (LANE_GATE_RUN),
#      a run with LANE_SINGLE_RUN=0, and a run with no cron ancestor (an
#      operator shell) all run while the tick holds the claim;
#  12. C1: bin/harden-state.sh --status/--release while the arm-all tick holds
#      the claim is not skipped, even when told it is a tick;
#  13. stale claims: a live unrelated pid with a wrong stamp, and a file name
#      that is not a pid, are deleted and the run goes on;
#  14. the count lock held from outside past its wait: the run goes on and
#      logs `counted unlocked` (needs flock);
#  16. two modes of one lane (LANE_RUN_KEY, a script on two cron lines with no
#      project) run at the same time; two ticks of one mode still skip; the
#      mode does not reach the off-switches; a project key still separates.
#  15. Linux only: the stamp is /proc/<pid>/stat field 22, and a cron ancestor
#      (LANE_TICK_PARENTS) makes a run a tick with no LANE_SINGLE_RUN.
# Run from anywhere: tests/lane-single-run.bh-7422-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset LANE_GATE_RUN LANE_SINGLE_RUN

H="$T/h"
mkdir -p "$H/bin/lib" "$H/flags" "$H/state" "$H/logs" "$H/locks" "$H/catalog"
# bin/harden-state.sh's closure holds bin/lib/lane-gate.sh and its own libs.
scratch_install_closure bin/harden-state.sh "$H" >/dev/null || { echo "FAIL: closure install"; exit 1; }
cat > "$H/catalog/lanes.json" <<'JSON'
{"lanes":[
 {"id":"fake-a","scope":"hub"},
 {"id":"fake-b","scope":"hub"},
 {"id":"harden-state","scope":"box"},
 {"id":"fake-optout","scope":"hub","single_run":false}
]}
JSON
export LANE_REGISTRY="$H/catalog/lanes.json"

# The lane: gate, say WORKED, then hold until $REL exists (at most 20 s).
# SPAWN_CHILD=1 leaves a background sleeper and exits. NESTED=1 runs the lane
# script again as lane $NEST_ID (default: its own) and prints its output.
cat > "$H/bin/fake-lane.sh" <<'SH'
#!/bin/bash
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "$HARNESS/bin/lib/lane-gate.sh"
lane_gate_or_exit "${LANE_ID:-fake-a}" "${LANE_PROJECT:-}"
echo WORKED
[ -n "${READY:-}" ] && : > "$READY"
if [ "${SPAWN_CHILD:-0}" = 1 ]; then
  ( sleep 20 ) </dev/null >/dev/null 2>&1 &
  echo $! > "$HARNESS/child.pid"
  exit 0
fi
if [ "${NESTED:-0}" = 1 ]; then
  NESTED=0 READY='' REL='' LANE_ID="${NEST_ID:-${LANE_ID:-fake-a}}" "$0"
  exit 0
fi
i=0
while [ -n "${REL:-}" ] && [ ! -e "$REL" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i+1)); done
exit 0
SH
chmod +x "$H/bin/fake-lane.sh"

LOG="$H/logs/lane-runs-cron.log"
# runl — one run, by default a scheduled tick (LANE_SINGLE_RUN=1); a later
# LANE_SINGLE_RUN= or =0 in the args overrides it.
runl() { env LANE_SINGLE_RUN=1 "$@" HARNESS="$H" "${BASH_BIN:-bash}" "$H/bin/fake-lane.sh"; }
# hold <tag> <env...> — a holding tick in the background, waited until it worked.
hold() {
  local tag=$1 i=0; shift
  rm -f "$T/rel-$tag" "$T/ready-$tag"
  ( env LANE_SINGLE_RUN=1 "$@" READY="$T/ready-$tag" REL="$T/rel-$tag" HARNESS="$H" "${BASH_BIN:-bash}" "$H/bin/fake-lane.sh" >"$T/out-$tag" 2>&1 ) &
  HOLD_PID=$!
  while [ ! -e "$T/ready-$tag" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  [ -e "$T/ready-$tag" ] || bad "$tag: the holding run never worked: $(cat "$T/out-$tag")"
}
release() { : > "$T/rel-$1"; wait "$HOLD_PID" 2>/dev/null; }
worked() { case "$1" in *WORKED*) return 0 ;; *) return 1 ;; esac; }

# --- 1. held -> second tick exits 0 at once, no work, one skipped line --------
: > "$LOG"
hold A LANE_ID=fake-a LANE_PROJECT=p1
SECONDS=0
out=$(runl LANE_ID=fake-a LANE_PROJECT=p1 2>&1); rc=$?; el=$SECONDS
[ "$rc" = 0 ] && ok || bad "1: a held run must exit 0, got rc=$rc"
worked "$out" && bad "1: a second tick of a held (lane, project) did work: $out" || ok
[ "$el" -le 2 ] && ok || bad "1: the skipped run took ${el}s (must be < 2 s)"
n=$(grep -c 'fake-a/p1 skipped (running)' "$LOG" 2>/dev/null)
[ "$n" = 1 ] && ok || bad "1: expected one 'fake-a/p1 skipped (running)' line, got ${n:-0}: $(cat "$LOG")"
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "1: a skipped run wrote an ALERTS line: $(cat "$H/logs/ALERTS.log")"

# --- 2. a different project runs -----------------------------------------------
out=$(runl LANE_ID=fake-a LANE_PROJECT=p2 2>&1)
worked "$out" && ok || bad "2: project p2 must run while p1 is held: $out"

# --- 8. the measure line --------------------------------------------------------
grep -qE 'fake-a/p1 ran pid=[0-9]+ live=1' "$LOG" && ok \
  || bad "8: no 'fake-a/p1 ran pid=<n> live=1' measure line: $(cat "$LOG")"

# --- 11. helper calls never skip ------------------------------------------------
skips0=$(grep -c 'fake-a/p1 skipped' "$LOG")
out=$(runl LANE_GATE_RUN=other-lane/- LANE_SINGLE_RUN= LANE_ID=fake-a LANE_PROJECT=p1 2>&1)
worked "$out" && ok || bad "11: a run under another gated run (LANE_GATE_RUN) must run: $out"
out=$(runl LANE_SINGLE_RUN=0 LANE_ID=fake-a LANE_PROJECT=p1 2>&1)
worked "$out" && ok || bad "11: LANE_SINGLE_RUN=0 must run: $out"
out=$(runl LANE_SINGLE_RUN= LANE_TICK_PARENTS=no-such-parent LANE_ID=fake-a LANE_PROJECT=p1 2>&1)
worked "$out" && ok || bad "11: a run with no cron ancestor (operator shell) must run: $out"
out=$(runl NESTED=1 NEST_ID=fake-a LANE_ID=fake-b LANE_PROJECT=p1 2>&1)
[ "$(printf '%s\n' "$out" | grep -c WORKED)" = 2 ] && ok \
  || bad "11: lane fake-b calling fake-a/p1 as a helper must run it: $out"
[ "$(grep -c 'fake-a/p1 skipped' "$LOG")" = "$skips0" ] && ok || bad "11: a helper call logged a skip: $(tail -n 5 "$LOG")"
release A

# --- 5a. the claim ends with the run ----------------------------------------------
out=$(runl LANE_ID=fake-a LANE_PROJECT=p1 2>&1)
worked "$out" && ok || bad "5a: a run after the holder exited must run: $out"

# --- 3. an opted-out lane runs twice -----------------------------------------------
hold B LANE_ID=fake-optout LANE_PROJECT=p1
out=$(runl LANE_ID=fake-optout LANE_PROJECT=p1 2>&1)
worked "$out" && ok || bad "3: single_run:false lane must run twice: $out"
grep -qE 'fake-optout/p1 ran pid=[0-9]+ live=2' "$LOG" && ok \
  || bad "3/8: the second opted-out run must log live=2: $(grep fake-optout "$LOG")"
release B

# --- 4. the knob off runs twice ------------------------------------------------------
printf '{"fetched_at":%s,"values":{"lane.fake-a.single_run":"OFF"},"seeded":{}}\n' "$(date -u +%s)" > "$H/state/settings-cache.json"
hold C LANE_ID=fake-a LANE_PROJECT=p1
out=$(runl LANE_ID=fake-a LANE_PROJECT=p1 2>&1)
worked "$out" && ok || bad "4: lane.fake-a.single_run=OFF must run twice: $out"
release C
printf '{"fetched_at":%s,"values":{"lane.fake-a.p3.single_run":"0"},"seeded":{}}\n' "$(date -u +%s)" > "$H/state/settings-cache.json"
hold C2 LANE_ID=fake-a LANE_PROJECT=p3
out=$(runl LANE_ID=fake-a LANE_PROJECT=p3 2>&1)
worked "$out" && ok || bad "4: lane.fake-a.p3.single_run=0 must run twice: $out"
release C2
hold C3 LANE_ID=fake-a LANE_PROJECT=p1
out=$(runl LANE_ID=fake-a LANE_PROJECT=p1 2>&1)
worked "$out" && bad "4: a row for p3 must not turn the guard off for p1: $out" || ok
release C3
rm -f "$H/state/settings-cache.json"

# --- 5b. a background child does not keep the claim ----------------------------------
out=$(runl SPAWN_CHILD=1 LANE_ID=fake-a LANE_PROJECT=p4 2>&1)
cp=$(cat "$H/child.pid" 2>/dev/null)
[ -n "$cp" ] && kill -0 "$cp" 2>/dev/null && ok || bad "5b: fixture: the background child is not alive"
out=$(runl LANE_ID=fake-a LANE_PROJECT=p4 2>&1)
worked "$out" && ok || bad "5b: a background child of an exited run must not hold the claim: $out"
[ -n "$cp" ] && kill "$cp" 2>/dev/null

# --- 6. a nested gate of the same lane runs ------------------------------------------
out=$(runl NESTED=1 LANE_ID=fake-a LANE_PROJECT=p5 2>&1)
[ "$(printf '%s\n' "$out" | grep -c WORKED)" = 2 ] && ok \
  || bad "6: the nested same-lane child must run inside its parent's run: $out"

# --- 7. project-lane-run children are keyed by PL_PROJECT ----------------------------
hold D LANE_ID=fake-a LANE_PROJECT= PL_LANE=fake-a PL_PROJECT=pa
out=$(runl LANE_ID=fake-a LANE_PROJECT= PL_LANE=fake-a PL_PROJECT=pb 2>&1)
worked "$out" && ok || bad "7: PL_PROJECT=pb must run while pa is held: $out"
out=$(runl LANE_ID=fake-a LANE_PROJECT= PL_LANE=fake-a PL_PROJECT=pa 2>&1)
worked "$out" && bad "7: a second PL_PROJECT=pa tick must be skipped: $out" || ok
release D

# --- 16. modes of one lane: LANE_RUN_KEY --------------------------------------------
hold M LANE_ID=fake-a LANE_PROJECT= LANE_RUN_KEY=w1h
out=$(runl LANE_ID=fake-a LANE_PROJECT= LANE_RUN_KEY=w24h 2>&1)
worked "$out" && ok || bad "16: mode w24h must run while mode w1h is held: $out"
out=$(runl LANE_ID=fake-a LANE_PROJECT= LANE_RUN_KEY=w1h 2>&1)
worked "$out" && bad "16: a second tick of mode w1h must be skipped: $out" || ok
grep -q 'fake-a/-+w1h skipped (running)' "$LOG" && ok || bad "16: no 'fake-a/-+w1h skipped' line: $(tail -n 3 "$LOG")"
touch "$H/flags/lane-off-fake-a-w24h"
out=$(runl LANE_ID=fake-a LANE_PROJECT= LANE_RUN_KEY=w24h 2>&1)
worked "$out" && ok || bad "16: the mode must not be read as a project by the off-switches: $out"
rm -f "$H/flags/lane-off-fake-a-w24h"
out=$(runl LANE_ID=fake-a LANE_PROJECT= LANE_RUN_KEY='bad/mode' 2>&1)
worked "$out" && ok || bad "16: a mode outside the charset must not claim (fail open): $out"
out=$(runl LANE_ID=fake-a LANE_PROJECT=p12 LANE_RUN_KEY=w1h 2>&1)
worked "$out" && ok || bad "16: (lane, project p12, mode w1h) must run while (lane, -, w1h) is held: $out"
release M

# --- 8b. a paused run writes no `ran` line ---------------------------------------------
touch "$H/flags/lane-off-fake-a-p8"
out=$(runl LANE_ID=fake-a LANE_PROJECT=p8 2>&1)
worked "$out" && bad "8b: fixture: the paused run did work: $out" || ok
grep -q 'fake-a/p8 ran' "$LOG" && bad "8b: a paused run must not log a ran line" || ok
rm -f "$H/flags/lane-off-fake-a-p8"

# --- 9. LANE_GATE_DISABLE bypasses the claim -------------------------------------------
hold E LANE_ID=fake-a LANE_PROJECT=p1
out=$(runl LANE_GATE_DISABLE=1 LANE_ID=fake-a LANE_PROJECT=p1 2>&1)
worked "$out" && ok || bad "9: LANE_GATE_DISABLE=1 must bypass the claim: $out"
release E

# --- 12. C1: harden-state helper modes under the arm-all tick ---------------------------
hold G LANE_ID=harden-state
for mode in --status "--release $H/logs/ALERTS.log"; do
  # shellcheck disable=SC2086 # the mode is two words on purpose
  out=$(env LANE_SINGLE_RUN=1 HARNESS="$H" HARDEN_SSH_DIR="$T/ssh" bash "$H/bin/harden-state.sh" $mode 2>&1)
  grep -q "harden-state/- skipped (running)" "$LOG" \
    && bad "12: harden-state $mode was skipped by the arm-all tick's claim: $(grep harden-state "$LOG")" || ok
  [ -n "$out" ] && ok || bad "12: harden-state $mode did nothing (no output)"
done
out=$(env LANE_SINGLE_RUN=1 HARNESS="$H" HARDEN_SSH_DIR="$T/ssh" bash "$H/bin/harden-state.sh" 2>&1)
grep -q "harden-state/- skipped (running)" "$LOG" && ok \
  || bad "12: a second arm-all tick must still be skipped: $(grep harden-state "$LOG")"
release G

# --- 13. stale claims are deleted ---------------------------------------------------------
d="$H/state/lane-runs/fake-a/p9"; mkdir -p "$d"
( sleep 30 ) & SP=$!
printf 'not-its-stamp\n' > "$d/$SP"
printf 'x\n' > "$d/garbage"
out=$(runl LANE_ID=fake-a LANE_PROJECT=p9 2>&1)
worked "$out" && ok || bad "13: a live unrelated pid with a wrong stamp must not hold the claim: $out"
[ ! -e "$d/$SP" ] && ok || bad "13: the wrong-stamp claim file must be deleted"
[ ! -e "$d/garbage" ] && ok || bad "13: a claim file whose name is not a pid must be deleted"
kill "$SP" 2>/dev/null

# --- 14. the count lock held from outside --------------------------------------------------
if command -v flock >/dev/null 2>&1; then
  mkdir -p "$H/locks/lane-run"
  ( flock "$H/locks/lane-run/fake-a.p10.lock" sleep 4 ) & LP=$!
  sleep 0.5
  out=$(runl LANE_RUN_LOCK_WAIT_S=1 LANE_ID=fake-a LANE_PROJECT=p10 2>&1)
  worked "$out" && ok || bad "14: a busy count lock must not stop the run: $out"
  grep -q 'fake-a/p10 ran .*counted unlocked' "$LOG" && ok || bad "14: no 'counted unlocked' line: $(grep p10 "$LOG")"
  wait "$LP" 2>/dev/null
else
  echo "note: flock missing — case 14 skipped (the claim itself works without it)"
fi

# --- 15. Linux only: the stamp and the cron ancestor ------------------------------------------
if [ -d /proc/self ]; then
  got=$(HARNESS="$H" bash -c '. "$HARNESS/bin/lib/lane-gate.sh"; _lg_pid_start $$; printf "%s %s" "$_LG_PS" "$(awk "{print \$22}" /proc/$$/stat)"')
  set -- $got
  [ -n "${1:-}" ] && [ "${1:-}" = "${2:-}" ] && ok || bad "15: stamp '${1:-}' != /proc field 22 '${2:-}'"
  me=$(awk '{print $2}' /proc/$$/stat | tr -d '()')
  hold H LANE_ID=fake-a LANE_PROJECT=p11
  out=$(runl LANE_SINGLE_RUN= LANE_TICK_PARENTS="$me" LANE_ID=fake-a LANE_PROJECT=p11 2>&1)
  worked "$out" && bad "15: an ancestor named in LANE_TICK_PARENTS ($me) must make the run a tick: $out" || ok
  release H
else
  echo "note: no /proc — case 15 skipped"
fi

# --- 10. the held case under /bin/bash (3.2 on a Mac) -------------------------------------------
if [ -x /bin/bash ]; then
  BASH_BIN=/bin/bash
  hold F LANE_ID=fake-a LANE_PROJECT=p6
  out=$(runl LANE_ID=fake-a LANE_PROJECT=p6 2>&1); rc=$?
  { [ "$rc" = 0 ] && ! worked "$out"; } && ok \
    || bad "10: /bin/bash ($(/bin/bash -c 'echo $BASH_VERSION')): held run rc=$rc out=$out"
  out=$(runl LANE_SINGLE_RUN=0 LANE_ID=fake-a LANE_PROJECT=p6 2>&1)
  worked "$out" && ok || bad "10: /bin/bash helper call must run: $out"
  release F
  BASH_BIN=bash
fi

echo "lane-single-run.bh-7422: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
