#!/bin/bash
# tests/mc-tick-sweeps.bh-7879-test.sh — BH-7879 (BH-6518 C5): the conductor's
# main-red detector call (BH-636, with the BH-6890 fleet-sweeps decision) and
# its post-fan-out fleet sweeps (the 14 housekeeping calls from mc_rereview_gc
# to mc_dv_reap) live in bin/lib/mc/tick-scope.sh as mc_tick_main_red and
# mc_tick_sweeps. The driver calls them at the old places and refuses the tick
# when tick-scope.sh does not define them.
#
#   U1     mc_tick_main_red sets MC_FLEET_SWEEPS over the six decision cases:
#          (keys "", project unset) 1, (keys "", project "") 1, keyed 0,
#          one project 0, both 0, keys " " (one space) 0.
#   U2     the detector: one call by default and with MC_MAIN_RED_DETECT=1; no
#          call for =0, a mode-644 detector or a keyed tick; with the tick lock
#          held, no call and one skip line; a detector that exits 1 does not
#          stop the caller.
#   U3     mc_tick_sweeps calls the 14 sweeps in order (mc_lane_gc gets
#          MC_RB_DIR); without mc_pr_files_gc and prs_gc the other 12 run and
#          nothing goes to stderr.
#   S1     the driver has no inline MC_FLEET_SWEEPS=1, mc_rereview_gc or
#          mc_dv_reap line and exactly one call line for each new function.
#   D1     the real driver over a one-project fleet: rc 0, one detector call
#          logged before the first project line, and a stale per-tick counter
#          file (mc_tick_gc's observable) is gone. Mutation: with either call
#          line deleted, its observable goes.
#   K1     a keyed tick and a one-project tick: rc 0, no detector call, the
#          stale file survives.
#   D2     tick-scope.sh without mc_tick_sweeps, without mc_tick_main_red, and
#          with mc_tick_sweeps only a variable: rc 1, one CONDUCTOR MODULE
#          MISSING alert, no gh call. Mutation: with each new guard clause
#          dropped the driver does not refuse. D2 runs last.
#   L1     the shim (bin/lib/merge-conductor-lib.sh) defines neither function.
# Run from anywhere: tests/mc-tick-sweeps.bh-7879-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
TS="$DIR/bin/lib/mc/tick-scope.sh"
DRV="$DIR/bin/merge-conductor.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -r "$TS" ] || { echo "FAIL: bin/lib/mc/tick-scope.sh is missing"; exit 1; }
# nl_ <file> <regex> — count of matching lines; 0 for a missing file.
nl_() { [ -e "$1" ] || { echo 0; return; }; grep -c -- "$2" "$1" 2>/dev/null || true; }

# ── U1-U3. the two functions, sourced alone ─────────────────────────────────
# Each case gets its own dir C (set by nc, in this shell) used as H.
NCASE=0
nc() {
  NCASE=$((NCASE+1)); C="$T/case$NCASE"
  mkdir -p "$C/bin" "$C/locks" "$C/logs"
}
# mr <setup-shell-text> [VAR=value...] — runs mc_tick_main_red in a clean
# subshell in case dir $C, then one line after the call. In $C: sweeps
# (MC_FLEET_SWEEPS after the call), log.txt (mc_log lines), after (the line
# after the call ran).
mr() {
  local setup="$1"; shift
  ( H="$C"; MC_LOCK_DIR="$C/locks"; MC_ONLY_KEYS=""
    unset MC_ONLY_PROJECT MC_MAIN_RED_DETECT MC_FLEET_SWEEPS
    for kv in "$@"; do printf -v "${kv%%=*}" '%s' "${kv#*=}"; done
    mc_log() { printf '%s\n' "$*" >> "$C/log.txt"; }
    eval "$setup"
    # shellcheck source=bin/lib/mc/tick-scope.sh
    . "$TS" || exit 8
    mc_tick_main_red
    printf '%s\n' "${MC_FLEET_SWEEPS-unset}" > "$C/sweeps"
    : > "$C/after" )
}
sweeps() { cat "$C/sweeps" 2>/dev/null; }
# A stub detector that records each call; it exits with $DET_RC.
det() {
  printf '#!/bin/bash\necho call >> "%s/det.txt"\nexit %s\n' "$C" "${1:-0}" > "$C/bin/main-red-detector.sh"
  chmod "${2:-755}" "$C/bin/main-red-detector.sh"
}
calls() { nl_ "$C/det.txt" '^call$'; }

# U1: the decision rule. The detector is absent, so only the flag is under test.
u1() { local want="$1"; shift; nc; mr '' "$@"
  [ "$(sweeps)" = "$want" ] && ok || bad "U1 ($*): want MC_FLEET_SWEEPS=$want, got '$(sweeps)'"; }
u1 1
u1 1 MC_ONLY_PROJECT=
u1 0 'MC_ONLY_KEYS= example-org/a#7 '
u1 0 MC_ONLY_PROJECT=demo-os
u1 0 'MC_ONLY_KEYS= example-org/a#7 ' MC_ONLY_PROJECT=demo-os
u1 0 'MC_ONLY_KEYS= '

# U2: the detector call.
nc; det; mr ''
[ "$(calls)" = 1 ] && ok || bad "U2: default: want one detector call, got $(calls)"
[ "$(nl_ "$C/log.txt" "^main-red detector: reading every repo's main before the project ticks$")" = 1 ] \
  && ok || bad "U2: default: want one 'main-red detector: reading' line: $(cat "$C/log.txt" 2>/dev/null)"
nc; det; mr '' MC_MAIN_RED_DETECT=1
[ "$(calls)" = 1 ] && ok || bad "U2: MC_MAIN_RED_DETECT=1: want one detector call, got $(calls)"
nc; det; mr '' MC_MAIN_RED_DETECT=0
[ "$(calls)" = 0 ] && ok || bad "U2: MC_MAIN_RED_DETECT=0: want no detector call, got $(calls)"
nc; det 0 644; mr ''
[ "$(calls)" = 0 ] && ok || bad "U2: mode-644 detector: want no call, got $(calls)"
nc; det; mr '' 'MC_ONLY_KEYS= example-org/a#7 ' MC_MAIN_RED_DETECT=1
[ "$(calls)" = 0 ] && ok || bad "U2: keyed tick: want no detector call, got $(calls)"
nc; det
flock -x "$C/locks/main-red-detect-tick.lock" sleep 60 & HP=$!
for _i in $(seq 1 50); do flock -n "$C/locks/main-red-detect-tick.lock" true 2>/dev/null || break; sleep 0.1; done
mr ''
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
[ "$(calls)" = 0 ] && ok || bad "U2: lock held: want no detector call, got $(calls)"
[ "$(nl_ "$C/log.txt" '^main-red detector: another tick holds the lock')" = 1 ] \
  && ok || bad "U2: lock held: want one skip line: $(cat "$C/log.txt" 2>/dev/null)"
[ -e "$C/after" ] && ok || bad "U2: lock held: the caller stopped after the call"
nc; det 1; mr ''
[ "$(calls)" = 1 ] && [ -e "$C/after" ] && ok \
  || bad "U2: a detector that exits 1: want one call and the caller still running (calls $(calls), after $([ -e "$C/after" ] && echo y || echo n))"

# U3: the 14 sweeps, in order.
SW14="mc_rereview_gc mc_lane_gc mc_handoff_gc mc_stuck_gc mc_resolver_claim_gc mc_batch_gc mc_tick_gc mc_pr_lock_gc mc_pr_files_gc read_memo_gc prs_gc head_lag_gc unverif_gc mc_dv_reap"
# sw <unset-names...> — runs mc_tick_sweeps with every sweep stubbed, then the
# named ones unset. In $C: seq.txt (one name a call), err.txt (stderr).
sw() {
  ( MC_RB_DIR="$C/rb"
    for f in $SW14; do eval "$f() { printf '%s\n' \"$f\${1:+ \$1}\" >> \"\$C/seq.txt\"; }"; done
    for f in "$@"; do unset -f "$f"; done
    # shellcheck source=bin/lib/mc/tick-scope.sh
    . "$TS" || exit 8
    mc_tick_sweeps ) 2>"$C/err.txt"
}
# want_seq — the expected seq.txt for case dir $C.
want_seq() { local f; for f in $SW14; do [ "$f" = mc_lane_gc ] && echo "mc_lane_gc $C/rb" || echo "$f"; done; }
nc; sw
want=$(want_seq)
[ "$(cat "$C/seq.txt" 2>/dev/null)" = "$want" ] && ok \
  || bad "U3: want the 14 sweeps in order, got: $(tr '\n' ' ' < "$C/seq.txt" 2>/dev/null)"
nc; sw mc_pr_files_gc prs_gc
want12=$(want_seq | grep -vx -e mc_pr_files_gc -e prs_gc)
[ "$(cat "$C/seq.txt" 2>/dev/null)" = "$want12" ] && ok \
  || bad "U3: without mc_pr_files_gc and prs_gc: want the other 12, got: $(tr '\n' ' ' < "$C/seq.txt" 2>/dev/null)"
[ ! -s "$C/err.txt" ] && ok || bad "U3: without mc_pr_files_gc and prs_gc: stderr: $(head -3 "$C/err.txt")"

# ── S1. the driver source ───────────────────────────────────────────────────
[ "$(grep -cxE 'MC_FLEET_SWEEPS=1|mc_rereview_gc|mc_dv_reap' "$DRV")" = 0 ] && ok \
  || bad "S1: the driver still has inline sweep lines: $(grep -nxE 'MC_FLEET_SWEEPS=1|mc_rereview_gc|mc_dv_reap' "$DRV" | tr '\n' ' ')"
[ "$(grep -cx 'mc_tick_main_red' "$DRV")" = 1 ] && [ "$(grep -cx 'mc_tick_sweeps' "$DRV")" = 1 ] && ok \
  || bad "S1: want one 'mc_tick_main_red' and one 'mc_tick_sweeps' call line in the driver"

# ── D1, K1, D2. the real driver ─────────────────────────────────────────────
HD="$T/hd"
mkdir -p "$HD/logs" "$HD/state" "$HD/flags" "$HD/locks" "$HD/builds" "$HD/env" "$HD/fakebin" "$T/repos/fx/.git"
scratch_install_closure bin/merge-conductor.sh "$HD" >/dev/null || exit 1
scratch_install_closure bin/alert-line.sh "$HD" >/dev/null || exit 1
scratch_install_closure bin/fleet-conf.sh "$HD" >/dev/null || exit 1
[ -r "$HD/bin/merge-conductor.sh" ] || { echo "FAIL: the closure did not install bin/merge-conductor.sh"; exit 1; }
cp "$HD/bin/merge-conductor.sh" "$T/driver.pristine" || exit 1
printf 'fx example-org/fx https://fx.example /api/board 2 local\n' > "$HD/fleet.conf"
cat > "$HD/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
exit 0
SH
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$HD/fakebin/curl"
printf '#!/bin/bash\nexit 0\n' > "$HD/fakebin/git"
# The stub detector logs through the conductor log, so its call is ordered
# against the project lines.
printf '#!/bin/bash\necho "STUB-DETECTOR call" >> "%s/logs/merge-conductor.log"\nexit 0\n' "$HD" > "$HD/bin/main-red-detector.sh"
chmod +x "$HD/fakebin/gh" "$HD/fakebin/curl" "$HD/fakebin/git" "$HD/bin/main-red-detector.sh"
STALE="$HD/state/merge-conductor/tick/stale.bh7879"
resetd() { : > "$HD/logs/merge-conductor.log"; : > "$HD/logs/ALERTS.log"; : > "$T/gh.txt"
           cp "$T/driver.pristine" "$HD/bin/merge-conductor.sh"
           mkdir -p "${STALE%/*}"; : > "$STALE"; touch -d '2 days ago' "$STALE"; }
# tick [VAR=value...] — one conductor tick; prints its rc.
tick() {
  ( cd "$T" || exit 9
    export PATH="$HD/fakebin:$HD/bin:$PATH" HARNESS="$HD" HARNESS_ENV_DIR="$HD/env" HARNESS_SECRET=s-fixture \
           JOBS_URL=https://jobs.invalid JOBS_BOX=b GH_SINK="$T/gh.txt" FLEET_CONF="$HD/fleet.conf" \
           MC_REPOS="$T/repos" MC_REHYDRATE=0 LAND_FIRE=0 MC_ONLY_PR='' MC_FULL_TICK_BUDGET_S=1500 \
           MC_MAIN_RED_DETECT=1 MC_TICK_SECS=0 PR_SNAPSHOT=0
    unset GH_TOKEN MC_WORKERS_DONE_BY MC_MODE MC_TICK_ID MC_ONLY_PROJECT
    for kv in "$@"; do export "${kv?}"; done
    timeout 120 bash "$HD/bin/merge-conductor.sh" >/dev/null 2>"$T/err.txt"; echo $? )
}
mclog() { cat "$HD/logs/merge-conductor.log" 2>/dev/null; }
dcalls() { nl_ "$HD/logs/merge-conductor.log" '^STUB-DETECTOR call$'; }
alerts() { grep -c 'CONDUCTOR MODULE MISSING: bin/lib/mc/tick-scope.sh' "$HD/logs/ALERTS.log" 2>/dev/null || true; }

# D1: a full tick runs the detector before the project and the sweeps after.
resetd
rc=$(tick)
[ "$rc" = 0 ] && ok || bad "D1: a one-project tick exited $rc (stderr: $(tail -3 "$T/err.txt"))"
[ "$(dcalls)" = 1 ] && ok || bad "D1: want one detector call, got $(dcalls): $(mclog | tail -5)"
first_det=$(grep -n '^STUB-DETECTOR call$' "$HD/logs/merge-conductor.log" | head -1 | cut -d: -f1)
first_fx=$(grep -n 'fx' "$HD/logs/merge-conductor.log" | grep -v 'STUB-DETECTOR' | head -1 | cut -d: -f1)
[ -n "$first_det" ] && [ -n "$first_fx" ] && [ "$first_det" -lt "$first_fx" ] && ok \
  || bad "D1: want the detector call (line ${first_det:-none}) before the first project line (line ${first_fx:-none}): $(mclog | head -8)"
[ ! -e "$STALE" ] && ok || bad "D1: the stale per-tick counter file survived a full tick (mc_tick_gc did not run)"
[ "$(alerts)" = 0 ] && ok || bad "D1: a full tick raised CONDUCTOR MODULE MISSING"

# D1 mutation: delete each call line; its observable goes.
for m in mc_tick_sweeps mc_tick_main_red; do
  resetd
  sed -i "/^$m\$/d" "$HD/bin/merge-conductor.sh"
  if cmp -s "$HD/bin/merge-conductor.sh" "$T/driver.pristine"; then
    bad "D1-mutation: the driver has no '$m' call line to delete"; continue
  fi
  rc=$(tick)
  if [ "$m" = mc_tick_sweeps ]; then
    [ -e "$STALE" ] && ok || bad "D1-mutation: with mc_tick_sweeps deleted the stale file still went (rc $rc) — D1 does not pin the call"
  else
    [ "$(dcalls)" = 0 ] && ok || bad "D1-mutation: with mc_tick_main_red deleted the detector still ran (rc $rc) — D1 does not pin the call"
  fi
done

# K1: a keyed tick and a one-project tick run no detector and no sweep.
for kv in 'MC_ONLY_PR=example-org/fx#1' 'MC_ONLY_PROJECT=fx'; do
  resetd
  rc=$(tick "$kv")
  [ "$rc" = 0 ] && ok || bad "K1 ($kv): exited $rc (stderr: $(tail -3 "$T/err.txt"))"
  [ "$(dcalls)" = 0 ] && ok || bad "K1 ($kv): want no detector call, got $(dcalls)"
  [ -e "$STALE" ] && ok || bad "K1 ($kv): the stale per-tick counter file went (a fleet sweep ran)"
done

# D2: tick-scope.sh lacks one of the two new functions. D2 and its mutation
# are the last driver cases: they replace the installed file and nothing after
# them needs the real one back.
c5_ts() { cat > "$HD/bin/lib/mc/tick-scope.sh" <<SH
#!/bin/bash
# shellcheck shell=bash
mc_keyed_tick_parse() { MC_ONLY_KEYS=""; }
mc_full_tick_window() { :; }
mc_tick_mode() { KILL=0 ACTIONS=0 MERGES=0 MODE=observe; MC_MODE=observe; export MC_MODE; }
mc_tick_prelude() { REBASE_BUDGET=2 REREVIEW_BUDGET=2 MERGE_BUDGET=5 REREVIEW_CAP=0 CAPFILE=/dev/null; MC_TICK_ID=stub; export MC_TICK_ID; }
mc_tick_fanout() { :; }
$1
SH
}
MR_DEF='mc_tick_main_red() { MC_FLEET_SWEEPS=1; }'
SW_DEF='mc_tick_sweeps() { :; }'
for variant in no-sweeps no-main-red sweeps-variable; do
  resetd
  case "$variant" in
    no-sweeps)       c5_ts "$MR_DEF" ;;
    no-main-red)     c5_ts "$SW_DEF" ;;
    sweeps-variable) c5_ts "$MR_DEF
mc_tick_sweeps=1" ;;
  esac
  rc=$(tick)
  [ "$rc" = 1 ] && ok || bad "D2 ($variant): exited $rc, want 1"
  [ "$(alerts)" = 1 ] && ok || bad "D2 ($variant): want exactly one CONDUCTOR MODULE MISSING line, got $(alerts): $(cat "$HD/logs/ALERTS.log")"
  [ ! -s "$T/gh.txt" ] && ok || bad "D2 ($variant): a refused tick called gh: $(head -3 "$T/gh.txt")"
done

# D2 mutation: drop each new guard clause, and the driver no longer refuses.
for m in "mc_tick_sweeps:$MR_DEF" "mc_tick_main_red:$SW_DEF"; do
  fn="${m%%:*}"
  resetd; c5_ts "${m#*:}"
  sed -i "s/ || ! declare -F $fn >\/dev\/null//" "$HD/bin/merge-conductor.sh"
  if cmp -s "$HD/bin/merge-conductor.sh" "$T/driver.pristine"; then
    bad "D2-mutation: the driver has no 'declare -F $fn' guard clause to drop"; continue
  fi
  rc=$(tick)
  [ "$(alerts)" = 0 ] && ok \
    || bad "D2-mutation ($fn): with the guard clause dropped the driver still alerted (rc $rc) — D2 does not pin the clause"
done

# ── L1. the shim ────────────────────────────────────────────────────────────
HL="$T/hl"; mkdir -p "$HL"
scratch_install_closure bin/merge-conductor.sh "$HL" >/dev/null || exit 1
shim=$(env -i PATH="$PATH" HARNESS="$HL" bash -c '. "$1" >/dev/null 2>&1; for f in mc_tick_main_red mc_tick_sweeps; do declare -F "$f" >/dev/null && echo "$f"; done' _ "$HL/bin/lib/merge-conductor-lib.sh")
[ -z "$shim" ] && [ -r "$HL/bin/lib/mc/tick-scope.sh" ] && ok \
  || bad "L1: after sourcing the shim these are defined: '$shim' (file beside it: $([ -r "$HL/bin/lib/mc/tick-scope.sh" ] && echo y || echo n))"

echo "mc-tick-sweeps: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
