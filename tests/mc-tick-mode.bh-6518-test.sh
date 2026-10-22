#!/bin/bash
# tests/mc-tick-mode.bh-6518-test.sh — BH-6518 slice C2: the conductor's
# flags/MODE block (BH-1201, BH-1672) lives in bin/lib/mc/tick-scope.sh as
# mc_tick_mode. flag_on stays in the driver (BH-685); the driver calls
# mc_tick_mode right after defining it and refuses the tick when tick-scope.sh
# does not define it.
#
#   M1-M10 the mode, sourced alone with stub flag_on/pause_active/mc_log:
#          KILL ACTIONS MERGES MODE MC_MODE, the export attributes and the
#          exact log lines.
#   D1     the real driver (production entry point) with only the merge flag
#          logs exactly one "merge flag set without the actions flag" line;
#          with the call line deleted it logs none.
#   D2     the real driver with no flags logs neither mode line.
#   D3     tick-scope.sh with the parse and the window and no mc_tick_mode:
#          rc 1, one CONDUCTOR MODULE MISSING alert, no gh call; with the new
#          guard clause dropped the driver does not refuse.
#   L1     the shim (bin/lib/merge-conductor-lib.sh) never defines mc_tick_mode.
# Run from anywhere: tests/mc-tick-mode.bh-6518-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
TS="$DIR/bin/lib/mc/tick-scope.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

REFUSE="merge flag set without the actions flag — merges refused this tick"
PAUSED="PAUSED(merges) fleet — no PR merges or enters a merge queue this tick; rebases and actions continue"

# ── M1-M10. the mode, sourced alone ─────────────────────────────────────────
# mode_case <PAUSE 0|1> <flag>... — prints three lines:
#   vals=<KILL ACTIONS MERGES MODE MC_MODE>
#   x=<MC_MODE export>/<KILL ACTIONS MERGES MODE exports, x or ->
#   log=[<every mc_log line, | joined>]
mode_case() {
  ( F="$T/flags-m"; LOGF="$T/m.log"; scratch_rm "$F"; mkdir -p "$F"; : > "$LOGF"
    PAUSE="$1"; shift
    for f in "$@"; do : > "$F/$f"; done
    mc_log() { printf '%s\n' "$*" >> "$LOGF"; }
    flag_on() { [ -f "$F/$1" ]; }
    pause_active() { [ "$PAUSE" = 1 ] && [ "$1 $2" = "fleet merges" ]; }
    unset MC_MODE KILL ACTIONS MERGES MODE
    # shellcheck source=bin/lib/mc/tick-scope.sh
    . "$TS" || exit 8
    mc_tick_mode || exit 7
    printf 'vals=%s %s %s %s %s\n' "$KILL" "$ACTIONS" "$MERGES" "$MODE" "${MC_MODE-unset}"
    xs=""
    for v in MC_MODE KILL ACTIONS MERGES MODE; do
      dp=$(declare -p "$v" 2>/dev/null)
      case "$dp" in "declare -x"*) xs="${xs}x" ;; *) xs="${xs}-" ;; esac
      [ "$v" = MC_MODE ] && xs="$xs/"
    done
    printf 'x=%s\n' "$xs"
    printf 'log=[%s]\n' "$(paste -sd'|' "$LOGF")" )
}
want_mode() { # want_mode <id> <pause> <vals> <log> <flag>...
  local id="$1" pause="$2" vals="$3" log="$4" got want; shift 4
  got=$(mode_case "$pause" "$@" 2>&1)
  want=$(printf 'vals=%s\nx=x/----\nlog=[%s]' "$vals" "$log")
  [ "$got" = "$want" ] && ok || bad "$id: flags=[$*] pause=$pause
--- want
$want
--- got
$got"
}
A=merge-conductor-actions; M=merge-conductor-merge; O=merge-conductor-observe; K=automerge-disabled
want_mode M1  0 '0 0 0 observe observe'         ''
want_mode M2  0 '0 1 0 actions actions'         ''          "$A"
want_mode M3  0 '0 1 1 merge merge'             ''          "$A" "$M"
want_mode M4  0 '0 0 0 observe observe'         "$REFUSE"   "$M"
want_mode M5  0 '0 0 0 observe observe'         ''          "$A" "$M" "$O"
want_mode M6  0 '0 0 0 observe observe'         ''          "$O"
want_mode M7  0 '1 0 0 kill-switch kill-switch' ''          "$K" "$A" "$M"
want_mode M8  1 '0 1 0 actions actions'         "$PAUSED"   "$A" "$M"
want_mode M9  1 '1 0 0 kill-switch kill-switch' "$PAUSED"   "$K"
want_mode M10 0 '0 0 0 observe observe'         ''          "$K-acme"

# ── D1-D3. the real driver ──────────────────────────────────────────────────
HD="$T/hd"
mkdir -p "$HD/logs" "$HD/state" "$HD/flags" "$HD/locks" "$HD/builds" "$HD/env" "$HD/fakebin"
scratch_install_closure bin/merge-conductor.sh "$HD" >/dev/null || exit 1
scratch_install_closure bin/alert-line.sh "$HD" >/dev/null || exit 1
[ -r "$HD/bin/merge-conductor.sh" ] || { echo "FAIL: the closure did not install bin/merge-conductor.sh"; exit 1; }
cp "$HD/bin/merge-conductor.sh" "$T/driver.pristine" || exit 1
# An empty fleet: the tick computes its mode, logs, and has no project to touch.
: > "$HD/fleet.conf"
cat > "$HD/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
exit 0
SH
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$HD/fakebin/curl"
chmod +x "$HD/fakebin/gh" "$HD/fakebin/curl"
resetd() { : > "$HD/logs/merge-conductor.log"; : > "$HD/logs/ALERTS.log"; : > "$T/gh.txt"
           rm -f "$HD/flags/"*; cp "$T/driver.pristine" "$HD/bin/merge-conductor.sh"; }
# tick — one unkeyed conductor tick; prints its rc.
tick() {
  ( cd "$T" || exit 9
    export PATH="$HD/fakebin:$HD/bin:$PATH" HARNESS="$HD" HARNESS_ENV_DIR="$HD/env" HARNESS_SECRET=s-fixture \
           JOBS_URL=https://jobs.invalid JOBS_BOX=b GH_SINK="$T/gh.txt" FLEET_CONF="$HD/fleet.conf" \
           MC_REHYDRATE=0 LAND_FIRE=0 MC_ONLY_PR='' MC_FULL_TICK_BUDGET_S=1500
    unset GH_TOKEN MC_WORKERS_DONE_BY MC_MODE
    bash "$HD/bin/merge-conductor.sh" >/dev/null 2>"$T/err.txt"; echo $? )
}
mclog() { cat "$HD/logs/merge-conductor.log" 2>/dev/null; }
nlog() { grep -c -- "$1" "$HD/logs/merge-conductor.log" 2>/dev/null || true; }
alerts() { grep -c 'CONDUCTOR MODULE MISSING: bin/lib/mc/tick-scope.sh' "$HD/logs/ALERTS.log" 2>/dev/null || true; }

# D1: the merge flag alone is refused, through the driver's own flag_on.
resetd; touch "$HD/flags/merge-conductor-merge"
rc=$(tick)
[ "$rc" = 0 ] && ok || bad "D1: a tick with only the merge flag exited $rc (stderr: $(tail -3 "$T/err.txt"))"
[ "$(nlog "$REFUSE")" = 1 ] && ok || bad "D1: want exactly one '$REFUSE' line: $(mclog)"
[ "$(alerts)" = 0 ] && ok || bad "D1: a tick that loaded tick-scope.sh raised CONDUCTOR MODULE MISSING"

# D1 mutation: the driver no longer calls the mode, so the line is gone. This
# also pins the order: a call before flag_on is defined reads every flag off.
resetd; touch "$HD/flags/merge-conductor-merge"
sed -i '/^mc_tick_mode$/d' "$HD/bin/merge-conductor.sh"
if cmp -s "$HD/bin/merge-conductor.sh" "$T/driver.pristine"; then
  bad "D1-mutation: the driver has no 'mc_tick_mode' call line to delete"
else
  rc=$(tick)
  [ "$(nlog 'merge flag set')" = 0 ] && ok \
    || bad "D1-mutation: with the call line deleted the refusal line still appears (rc $rc) — the test does not pin the call"
fi

# D2: no flags, no pause: neither mode line.
resetd
rc=$(tick)
[ "$rc" = 0 ] && ok || bad "D2: a tick with no flags exited $rc (stderr: $(tail -3 "$T/err.txt"))"
[ "$(nlog 'merge flag set')" = 0 ] && ok || bad "D2: a tick with no flags logged a refusal: $(mclog)"
[ "$(nlog 'PAUSED(merges) fleet')" = 0 ] && ok || bad "D2: a tick with no pause logged a fleet pause: $(mclog)"

# D3: tick-scope.sh defines the parse, the window and the prelude, and not
# the mode. The prelude and fan-out stubs keep the C3 and BH-7879 guard
# clauses satisfied. D3 and its
# mutation are the last driver cases: they replace the installed file and
# nothing after them needs the real one back.
c1_ts() { cat > "$HD/bin/lib/mc/tick-scope.sh" <<'SH'
#!/bin/bash
# shellcheck shell=bash
mc_keyed_tick_parse() { MC_ONLY_KEYS=""; }
mc_full_tick_window() { :; }
mc_tick_prelude() { REBASE_BUDGET=2 REREVIEW_BUDGET=2 MERGE_BUDGET=5 REREVIEW_CAP=0 CAPFILE=/dev/null; MC_TICK_ID=stub; export MC_TICK_ID; }
mc_tick_fanout() { :; }
SH
}
resetd; c1_ts
rc=$(tick)
[ "$rc" = 1 ] && ok || bad "D3: a tick with no mc_tick_mode exited $rc, want 1"
[ "$(alerts)" = 1 ] && ok || bad "D3: want exactly one CONDUCTOR MODULE MISSING line, got $(alerts): $(cat "$HD/logs/ALERTS.log")"
[ ! -s "$T/gh.txt" ] && ok || bad "D3: a refused tick called gh: $(head -3 "$T/gh.txt")"
[ "$(nlog 'bin/lib/mc/tick-scope.sh is missing or unusable — refusing the tick')" = 1 ] && ok \
  || bad "D3: want one refusal line in logs/merge-conductor.log: $(mclog)"

# D3 mutation: drop the new guard clause, and the driver no longer refuses.
resetd; c1_ts
sed -i 's/ || ! declare -F mc_tick_mode >\/dev\/null//' "$HD/bin/merge-conductor.sh"
if cmp -s "$HD/bin/merge-conductor.sh" "$T/driver.pristine"; then
  bad "D3-mutation: the driver has no 'declare -F mc_tick_mode' guard clause to drop"
else
  rc=$(tick)
  [ "$(alerts)" = 0 ] && ok \
    || bad "D3-mutation: with the guard clause dropped the driver still alerted (rc $rc) — the test does not pin the clause"
fi

# ── L1. the shim ────────────────────────────────────────────────────────────
HL="$T/hl"; mkdir -p "$HL"
scratch_install_closure bin/merge-conductor.sh "$HL" >/dev/null || exit 1
shim=$(env -i PATH="$PATH" HARNESS="$HL" bash -c '. "$1" >/dev/null 2>&1; declare -F mc_tick_mode >/dev/null && echo defined || echo absent' _ "$HL/bin/lib/merge-conductor-lib.sh")
[ "$shim" = absent ] && [ -r "$HL/bin/lib/mc/tick-scope.sh" ] && ok \
  || bad "L1: after sourcing the shim, mc_tick_mode is '$shim' (file beside it: $([ -r "$HL/bin/lib/mc/tick-scope.sh" ] && echo y || echo n))"

echo "mc-tick-mode: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
